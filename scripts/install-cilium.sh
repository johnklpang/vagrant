#!/usr/bin/env bash
# =============================================================================
# install-cilium.sh
# Install Cilium CLI and deploy latest stable Cilium with:
#   - kube-proxy replacement
#   - Hubble enabled (relay required; UI best-effort on small labs)
# Waits for Cilium to become healthy on currently registered nodes.
# Full multi-node validation (including connectivity tests) runs in validate.sh
# after workers have joined.
# Idempotent: upgrades/reuses an existing Cilium install when present.
# =============================================================================
set -euxo pipefail

LOG_TAG="[cilium]"
log() { echo "${LOG_TAG} $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*"; }
err() { echo "${LOG_TAG} ERROR: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
export PATH="/usr/local/bin:${PATH}"

MASTER_IP="${MASTER_IP:-192.168.56.10}"
CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION:-}"
CLUSTER_DIR="/vagrant/.cluster"
# Hubble UI is enabled by default. Set ENABLE_HUBBLE_UI=false to skip it on very
# memory-constrained hosts.
ENABLE_HUBBLE_UI="${ENABLE_HUBBLE_UI:-true}"

[[ -f "${KUBECONFIG}" ]] || err "KUBECONFIG not found at ${KUBECONFIG}"
mkdir -p "${CLUSTER_DIR}"

dump_diagnostics() {
  local out="${CLUSTER_DIR}/cilium-diagnostics.txt"
  {
    echo "===== Cilium / Hubble diagnostics $(date -u +'%Y-%m-%dT%H:%M:%SZ') ====="
    kubectl get nodes -o wide || true
    kubectl -n kube-system get pods -o wide || true
    kubectl -n kube-system get deploy,ds,svc,events --sort-by=.lastTimestamp || true
    kubectl -n kube-system describe deploy hubble-relay 2>/dev/null || true
    kubectl -n kube-system describe pods -l k8s-app=hubble-relay 2>/dev/null || true
    kubectl -n kube-system describe deploy hubble-ui 2>/dev/null || true
    kubectl -n kube-system logs -l k8s-app=hubble-relay --tail=100 2>/dev/null || true
    kubectl -n kube-system logs -l k8s-app=hubble-ui --tail=100 2>/dev/null || true
    cilium status --verbose 2>/dev/null || true
  } | tee "${out}" || true
  log "Diagnostics written to ${out}"
}

# -----------------------------------------------------------------------------
# Install / update Cilium CLI (latest stable)
# -----------------------------------------------------------------------------
install_cilium_cli() {
  local arch cli_arch version tarball url tmpdir

  arch="$(uname -m)"
  case "${arch}" in
    x86_64)  cli_arch="amd64" ;;
    aarch64) cli_arch="arm64" ;;
    *) err "Unsupported architecture: ${arch}" ;;
  esac

  if [[ -z "${CILIUM_CLI_VERSION}" ]]; then
    version="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
  else
    version="${CILIUM_CLI_VERSION}"
  fi

  log "Installing Cilium CLI ${version} (${cli_arch})"
  tarball="cilium-linux-${cli_arch}.tar.gz"
  url="https://github.com/cilium/cilium-cli/releases/download/${version}/${tarball}"

  tmpdir="$(mktemp -d)"
  curl -fsSL "${url}" -o "${tmpdir}/${tarball}"
  curl -fsSL "${url}.sha256sum" -o "${tmpdir}/${tarball}.sha256sum"

  (
    cd "${tmpdir}"
    sha256sum --check "${tarball}.sha256sum"
    tar -xzf "${tarball}"
    install -m 0755 cilium /usr/local/bin/cilium
  )
  rm -rf "${tmpdir}"

  cilium version --client
}

if ! command -v cilium >/dev/null 2>&1; then
  install_cilium_cli
else
  log "Cilium CLI already present — refreshing to latest stable"
  install_cilium_cli
fi

# -----------------------------------------------------------------------------
# Wait for API + control-plane node object
# -----------------------------------------------------------------------------
log "Waiting for Kubernetes API before Cilium install"
for i in $(seq 1 60); do
  if kubectl get nodes >/dev/null 2>&1; then
    break
  fi
  if [[ "${i}" -eq 60 ]]; then
    err "Kubernetes API not reachable"
  fi
  sleep 5
done

# Clear previously failed Hubble rollouts so re-provision can recreate them.
if kubectl -n kube-system get deploy hubble-relay >/dev/null 2>&1; then
  RELAY_STATUS="$(kubectl -n kube-system get deploy hubble-relay -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null || true)"
  if [[ "${RELAY_STATUS}" == "ProgressDeadlineExceeded" ]]; then
    log "Removing failed hubble-relay deployment (ProgressDeadlineExceeded)"
    kubectl -n kube-system delete deploy hubble-relay --wait=true --timeout=120s || true
  fi
fi
if kubectl -n kube-system get deploy hubble-ui >/dev/null 2>&1; then
  UI_STATUS="$(kubectl -n kube-system get deploy hubble-ui -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null || true)"
  if [[ "${UI_STATUS}" == "ProgressDeadlineExceeded" ]]; then
    log "Removing failed hubble-ui deployment (ProgressDeadlineExceeded)"
    kubectl -n kube-system delete deploy hubble-ui --wait=true --timeout=120s || true
  fi
fi

install_or_upgrade() {
  local -a args=("$@")
  if kubectl -n kube-system get daemonset cilium >/dev/null 2>&1; then
    log "Cilium DaemonSet present — upgrading"
    if ! cilium upgrade "${args[@]}" --wait --wait-duration 20m; then
      log "cilium upgrade failed — falling back to cilium install"
      cilium install "${args[@]}" --wait --wait-duration 20m
    fi
  else
    log "Installing Cilium"
    cilium install "${args[@]}" --wait --wait-duration 20m
  fi
}

# -----------------------------------------------------------------------------
# Shared Helm values
#
# Critical for single-node / control-plane-first labs:
#   kubeadm taints the control plane with
#   node-role.kubernetes.io/control-plane:NoSchedule
#   Hubble Relay/UI have EMPTY tolerations by default, so they stay Pending
#   forever on a master-only cluster and hit ProgressDeadlineExceeded.
#
# Do NOT set unknown keys (e.g. hubble.relay.dialTimeout) — Cilium's values
# schema rejects them and the entire Helm upgrade fails.
# -----------------------------------------------------------------------------
CONTROL_PLANE_TOLERATION_ARGS=(
  --set 'hubble.relay.tolerations[0].key=node-role.kubernetes.io/control-plane'
  --set 'hubble.relay.tolerations[0].operator=Exists'
  --set 'hubble.relay.tolerations[0].effect=NoSchedule'
  --set 'hubble.ui.tolerations[0].key=node-role.kubernetes.io/control-plane'
  --set 'hubble.ui.tolerations[0].operator=Exists'
  --set 'hubble.ui.tolerations[0].effect=NoSchedule'
)

CILIUM_BASE_ARGS=(
  --set kubeProxyReplacement=true
  --set k8sServiceHost="${MASTER_IP}"
  --set k8sServicePort=6443
  --set hubble.enabled=true
  --set hubble.relay.enabled=false
  --set hubble.ui.enabled=false
  --set operator.replicas=1
  --set ipam.operator.clusterPoolIPv4PodCIDRList=10.244.0.0/16
  "${CONTROL_PLANE_TOLERATION_ARGS[@]}"
)

CILIUM_RELAY_ARGS=(
  --set kubeProxyReplacement=true
  --set k8sServiceHost="${MASTER_IP}"
  --set k8sServicePort=6443
  --set hubble.enabled=true
  --set hubble.relay.enabled=true
  --set hubble.ui.enabled=false
  --set operator.replicas=1
  --set ipam.operator.clusterPoolIPv4PodCIDRList=10.244.0.0/16
  --set hubble.relay.retryTimeout=30s
  --set hubble.relay.rollOutPods=true
  --set hubble.relay.resources.requests.cpu=50m
  --set hubble.relay.resources.requests.memory=64Mi
  --set hubble.relay.resources.limits.memory=256Mi
  "${CONTROL_PLANE_TOLERATION_ARGS[@]}"
)

# -----------------------------------------------------------------------------
# Phase 1: Cilium dataplane (Hubble on agents, relay deferred)
# -----------------------------------------------------------------------------
log "Phase 1: installing Cilium dataplane with kube-proxy replacement"
if ! install_or_upgrade "${CILIUM_BASE_ARGS[@]}"; then
  dump_diagnostics
  err "Cilium dataplane installation failed"
fi

log "Waiting for Cilium agents to become healthy"
if ! cilium status --wait --wait-duration 15m; then
  dump_diagnostics
  err "Cilium status unhealthy after dataplane install"
fi

# Pre-pull Hubble Relay image to reduce VirtualBox/NAT pull timeouts during rollout.
RELAY_IMAGE="$(kubectl -n kube-system get ds cilium -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's#/cilium:#/hubble-relay:#' || true)"
if [[ -z "${RELAY_IMAGE}" || "${RELAY_IMAGE}" != *hubble-relay* ]]; then
  RELAY_IMAGE="quay.io/cilium/hubble-relay:v1.19.5"
fi
log "Pre-pulling Hubble Relay image: ${RELAY_IMAGE}"
ctr -n k8s.io images pull "${RELAY_IMAGE}" >/dev/null 2>&1 \
  || crictl pull "${RELAY_IMAGE}" >/dev/null 2>&1 \
  || log "WARNING: could not pre-pull ${RELAY_IMAGE}; continuing"

# -----------------------------------------------------------------------------
# Phase 2: enable Hubble Relay via official CLI + toleration-aware upgrade
# -----------------------------------------------------------------------------
log "Phase 2: enabling Hubble Relay"
RELAY_OK=0
for attempt in 1 2 3; do
  log "Hubble Relay enable attempt ${attempt}/3"

  # Official path (reuse-values + hubble.relay.enabled=true). Follow with an
  # upgrade that injects control-plane tolerations and lab-friendly resources.
  set +e
  cilium hubble enable --relay
  ENABLE_RC=$?
  set -e

  if [[ "${ENABLE_RC}" -ne 0 ]]; then
    log "cilium hubble enable returned ${ENABLE_RC}; trying explicit upgrade"
  fi

  if install_or_upgrade "${CILIUM_RELAY_ARGS[@]}"; then
    # Show scheduling state for easier debugging
    kubectl -n kube-system get pods -l k8s-app=hubble-relay -o wide || true
    if kubectl -n kube-system rollout status deploy/hubble-relay --timeout=600s; then
      RELAY_OK=1
      break
    fi
  fi

  log "Hubble Relay not ready yet — collecting diagnostics and retrying"
  dump_diagnostics
  # Pending pods often mean taints/affinity; force recreate after value fixes
  kubectl -n kube-system delete deploy hubble-relay --ignore-not-found=true --wait=true --timeout=120s || true
  sleep 15
done

if [[ "${RELAY_OK}" -ne 1 ]]; then
  dump_diagnostics
  err "Hubble Relay failed to become ready after retries"
fi

# -----------------------------------------------------------------------------
# Phase 3: Hubble UI (enabled by default)
# -----------------------------------------------------------------------------
if [[ "${ENABLE_HUBBLE_UI}" == "true" ]]; then
  log "Phase 3: enabling Hubble UI"

  # Pre-pull UI images (frontend/backend share the hubble-ui repository tags).
  UI_TAG="${RELAY_TAG:-v1.19.5}"
  for img in \
    "quay.io/cilium/hubble-ui:${UI_TAG}" \
    "quay.io/cilium/hubble-ui-backend:${UI_TAG}"
  do
    log "Pre-pulling ${img}"
    ctr -n k8s.io images pull "${img}" >/dev/null 2>&1 \
      || crictl pull "${img}" >/dev/null 2>&1 \
      || log "WARNING: could not pre-pull ${img}; continuing"
  done

  CILIUM_UI_ARGS=(
    "${CILIUM_RELAY_ARGS[@]}"
    --set hubble.ui.enabled=true
    --set hubble.ui.rollOutPods=true
    --set hubble.ui.frontend.resources.requests.cpu=50m
    --set hubble.ui.frontend.resources.requests.memory=64Mi
    --set hubble.ui.backend.resources.requests.cpu=50m
    --set hubble.ui.backend.resources.requests.memory=64Mi
  )

  UI_OK=0
  for attempt in 1 2 3; do
    log "Hubble UI enable attempt ${attempt}/3"
    set +e
    cilium hubble enable --relay --ui
    set -e
    if install_or_upgrade "${CILIUM_UI_ARGS[@]}"; then
      kubectl -n kube-system get pods -l k8s-app=hubble-ui -o wide || true
      if kubectl -n kube-system rollout status deploy/hubble-ui --timeout=600s; then
        UI_OK=1
        break
      fi
    fi
    log "Hubble UI not ready yet — collecting diagnostics and retrying"
    dump_diagnostics
    kubectl -n kube-system delete deploy hubble-ui --ignore-not-found=true --wait=true --timeout=120s || true
    sleep 15
  done

  if [[ "${UI_OK}" -ne 1 ]]; then
    dump_diagnostics
    err "Hubble UI failed to become ready after retries"
  fi

  log "Hubble UI is Ready"
  log "Access from the host with: vagrant ssh k8s-master -c 'cilium hubble ui'"
  log "Or: kubectl -n kube-system port-forward svc/hubble-ui 12000:80"
else
  log "Phase 3: skipping Hubble UI (ENABLE_HUBBLE_UI=${ENABLE_HUBBLE_UI})"
fi

log "Final Cilium status check"
if ! cilium status --wait --wait-duration 15m | tee "${CLUSTER_DIR}/cilium-status.txt"; then
  dump_diagnostics
  err "Cilium status unhealthy after Hubble enablement"
fi
cilium status --verbose | tee -a "${CLUSTER_DIR}/cilium-status.txt" || true

# Confirm Hubble Relay is enabled and Ready
if ! kubectl -n kube-system get deploy hubble-relay >/dev/null 2>&1; then
  dump_diagnostics
  err "hubble-relay deployment missing after install"
fi
READY_REPLICAS="$(kubectl -n kube-system get deploy hubble-relay -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
if [[ "${READY_REPLICAS}" -lt 1 ]]; then
  dump_diagnostics
  err "hubble-relay has no Ready replicas"
fi

# cilium status should report Hubble Relay as OK (not disabled)
if cilium status 2>/dev/null | grep -qi 'Hubble Relay:.*disabled'; then
  dump_diagnostics
  err "Cilium still reports Hubble Relay as disabled"
fi

log "Cilium installation completed successfully on the control plane"
log "Workers will receive Cilium agents automatically after they join"
