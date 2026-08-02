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
# Hubble UI is optional for the lab requirements and often OOMs / times out on a 4GB
# control plane. Enable with ENABLE_HUBBLE_UI=true if the host has spare capacity.
ENABLE_HUBBLE_UI="${ENABLE_HUBBLE_UI:-false}"

[[ -f "${KUBECONFIG}" ]] || err "KUBECONFIG not found at ${KUBECONFIG}"
mkdir -p "${CLUSTER_DIR}"

dump_diagnostics() {
  local out="${CLUSTER_DIR}/cilium-diagnostics.txt"
  {
    echo "===== Cilium / Hubble diagnostics $(date -u +'%Y-%m-%dT%H:%M:%SZ') ====="
    kubectl get nodes -o wide || true
    kubectl -n kube-system get pods -o wide || true
    kubectl -n kube-system get deploy,ds,svc || true
    kubectl -n kube-system describe deploy hubble-relay 2>/dev/null || true
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
# A Deployment stuck in ProgressDeadlineExceeded blocks subsequent --wait installs.
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

# -----------------------------------------------------------------------------
# Phase 1: Cilium dataplane + Hubble on agents (no relay/UI wait yet)
# k8sServiceHost/Port are required when kube-proxy is skipped.
# -----------------------------------------------------------------------------
CILIUM_BASE_ARGS=(
  --set kubeProxyReplacement=true
  --set k8sServiceHost="${MASTER_IP}"
  --set k8sServicePort=6443
  --set hubble.enabled=true
  --set hubble.relay.enabled=false
  --set hubble.ui.enabled=false
  --set operator.replicas=1
  --set ipam.operator.clusterPoolIPv4PodCIDRList=10.244.0.0/16
)

install_or_upgrade() {
  local -a args=("$@")
  if kubectl -n kube-system get daemonset cilium >/dev/null 2>&1; then
    log "Cilium DaemonSet present — upgrading: ${args[*]}"
    if ! cilium upgrade "${args[@]}" --wait --wait-duration 20m; then
      log "cilium upgrade failed — falling back to cilium install"
      cilium install "${args[@]}" --wait --wait-duration 20m
    fi
  else
    log "Installing Cilium: ${args[*]}"
    cilium install "${args[@]}" --wait --wait-duration 20m
  fi
}

log "Phase 1: installing Cilium dataplane with Hubble enabled on agents"
if ! install_or_upgrade "${CILIUM_BASE_ARGS[@]}"; then
  dump_diagnostics
  err "Cilium dataplane installation failed"
fi

log "Waiting for Cilium agents to become healthy"
if ! cilium status --wait --wait-duration 15m; then
  dump_diagnostics
  err "Cilium status unhealthy after dataplane install"
fi

# -----------------------------------------------------------------------------
# Phase 2: Hubble Relay (required). Tuned for small VirtualBox labs.
# -----------------------------------------------------------------------------
CILIUM_RELAY_ARGS=(
  --set kubeProxyReplacement=true
  --set k8sServiceHost="${MASTER_IP}"
  --set k8sServicePort=6443
  --set hubble.enabled=true
  --set hubble.relay.enabled=true
  --set hubble.ui.enabled=false
  --set operator.replicas=1
  --set ipam.operator.clusterPoolIPv4PodCIDRList=10.244.0.0/16
  # Constrained lab / slow NAT image pulls: give relay more time to connect
  --set hubble.relay.dialTimeout=30s
  --set hubble.relay.retryTimeout=30s
  --set hubble.relay.rollOutPods=true
  --set hubble.relay.resources.requests.cpu=50m
  --set hubble.relay.resources.requests.memory=64Mi
  --set hubble.relay.resources.limits.memory=256Mi
  --set hubble.relay.livenessProbe.failureThreshold=20
  --set hubble.relay.readinessProbe.failureThreshold=20
)

log "Phase 2: enabling Hubble Relay"
RELAY_OK=0
for attempt in 1 2 3; do
  log "Hubble Relay enable attempt ${attempt}/3"
  if install_or_upgrade "${CILIUM_RELAY_ARGS[@]}"; then
    # Explicit wait for the relay deployment
    if kubectl -n kube-system rollout status deploy/hubble-relay --timeout=600s; then
      RELAY_OK=1
      break
    fi
  fi
  log "Hubble Relay not ready yet — collecting diagnostics and retrying"
  dump_diagnostics
  kubectl -n kube-system delete deploy hubble-relay --ignore-not-found=true --wait=true --timeout=120s || true
  sleep 15
done

if [[ "${RELAY_OK}" -ne 1 ]]; then
  dump_diagnostics
  err "Hubble Relay failed to become ready after retries"
fi

# -----------------------------------------------------------------------------
# Phase 3 (optional): Hubble UI — best effort on 4GB control planes
# -----------------------------------------------------------------------------
if [[ "${ENABLE_HUBBLE_UI}" == "true" ]]; then
  log "Phase 3: enabling Hubble UI (ENABLE_HUBBLE_UI=true)"
  CILIUM_UI_ARGS=(
    "${CILIUM_RELAY_ARGS[@]}"
    --set hubble.ui.enabled=true
    --set hubble.ui.rollOutPods=true
    --set hubble.ui.frontend.resources.requests.cpu=50m
    --set hubble.ui.frontend.resources.requests.memory=64Mi
    --set hubble.ui.backend.resources.requests.cpu=50m
    --set hubble.ui.backend.resources.requests.memory=64Mi
  )
  if ! install_or_upgrade "${CILIUM_UI_ARGS[@]}"; then
    log "WARNING: Hubble UI enablement failed — continuing because Hubble + relay are healthy"
    dump_diagnostics
  elif ! kubectl -n kube-system rollout status deploy/hubble-ui --timeout=600s; then
    log "WARNING: Hubble UI rollout not ready — continuing because Hubble + relay are healthy"
    dump_diagnostics
  fi
else
  log "Phase 3: skipping Hubble UI (set ENABLE_HUBBLE_UI=true to enable)"
fi

log "Final Cilium status check"
if ! cilium status --wait --wait-duration 15m | tee "${CLUSTER_DIR}/cilium-status.txt"; then
  dump_diagnostics
  err "Cilium status unhealthy after Hubble enablement"
fi
cilium status --verbose | tee -a "${CLUSTER_DIR}/cilium-status.txt" || true

# Confirm Hubble is actually enabled
if ! kubectl -n kube-system get deploy hubble-relay >/dev/null 2>&1; then
  dump_diagnostics
  err "hubble-relay deployment missing after install"
fi

log "Cilium installation completed successfully on the control plane"
log "Workers will receive Cilium agents automatically after they join"
