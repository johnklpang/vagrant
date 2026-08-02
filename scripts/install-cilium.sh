#!/usr/bin/env bash
# =============================================================================
# install-cilium.sh
# Install Cilium CLI and deploy latest stable Cilium with:
#   - kube-proxy replacement
#   - Hubble enabled
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

MASTER_IP="${MASTER_IP:-192.168.56.10}"
CILIUM_CLI_VERSION="${CILIUM_CLI_VERSION:-}"
CLUSTER_DIR="/vagrant/.cluster"

[[ -f "${KUBECONFIG}" ]] || err "KUBECONFIG not found at ${KUBECONFIG}"
mkdir -p "${CLUSTER_DIR}"

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

# -----------------------------------------------------------------------------
# Install Cilium (kube-proxy replacement + Hubble)
# k8sServiceHost/Port are required when kube-proxy is skipped.
# -----------------------------------------------------------------------------
CILIUM_SET_ARGS=(
  --set kubeProxyReplacement=true
  --set k8sServiceHost="${MASTER_IP}"
  --set k8sServicePort=6443
  --set hubble.enabled=true
  --set hubble.relay.enabled=true
  --set hubble.ui.enabled=true
  --set operator.replicas=1
)

if kubectl -n kube-system get daemonset cilium >/dev/null 2>&1; then
  log "Cilium DaemonSet already present — upgrading in place"
  if ! cilium upgrade "${CILIUM_SET_ARGS[@]}" --wait --wait-duration 15m; then
    log "cilium upgrade failed — falling back to cilium install"
    cilium install "${CILIUM_SET_ARGS[@]}" --wait --wait-duration 15m
  fi
else
  log "Installing Cilium with kube-proxy replacement and Hubble enabled"
  cilium install "${CILIUM_SET_ARGS[@]}" --wait --wait-duration 15m
fi

log "Waiting for Cilium status to become healthy on current nodes"
cilium status --wait --wait-duration 15m | tee "${CLUSTER_DIR}/cilium-status.txt"
cilium status --verbose | tee -a "${CLUSTER_DIR}/cilium-status.txt" || true

# Convenience copies of the CLI for the devops user path is already /usr/local/bin
log "Cilium installation completed successfully on the control plane"
log "Workers will receive Cilium agents automatically after they join"
