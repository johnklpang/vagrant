#!/usr/bin/env bash
# =============================================================================
# validate.sh
# End-to-end cluster validation. Waits for all nodes to become Ready, then
# runs kubectl and Cilium checks including connectivity tests.
# Idempotent: safe to re-run at any time.
# =============================================================================
set -euxo pipefail

LOG_TAG="[validate]"
log() { echo "${LOG_TAG} $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*"; }
err() { echo "${LOG_TAG} ERROR: $*" >&2; exit 1; }

export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
if [[ ! -f "${KUBECONFIG}" && -f /vagrant/.cluster/admin.conf ]]; then
  export KUBECONFIG=/vagrant/.cluster/admin.conf
fi

EXPECTED_NODES="${EXPECTED_NODES:-4}"
CLUSTER_DIR="/vagrant/.cluster"
REPORT_FILE="${CLUSTER_DIR}/validation-report.txt"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-1200}"

[[ -f "${KUBECONFIG}" ]] || err "No kubeconfig found (looked for admin.conf)"
mkdir -p "${CLUSTER_DIR}"

# Prefer local cilium + kubectl; ensure PATH
export PATH="/usr/local/bin:${PATH}"

log "Starting cluster validation (expecting ${EXPECTED_NODES} Ready nodes)"
{
  echo "===== Kubernetes Lab Validation Report ====="
  echo "Timestamp (UTC): $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Host: $(hostname)"
  echo "KUBECONFIG: ${KUBECONFIG}"
  echo
} > "${REPORT_FILE}"

# -----------------------------------------------------------------------------
# Wait until all nodes are Ready
# -----------------------------------------------------------------------------
log "Waiting for ${EXPECTED_NODES} Ready nodes (timeout ${MAX_WAIT_SECONDS}s)"
elapsed=0
while true; do
  READY_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')"
  TOTAL_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  log "Nodes Ready=${READY_COUNT} Total=${TOTAL_COUNT}"

  if [[ "${READY_COUNT}" -ge "${EXPECTED_NODES}" ]]; then
    log "All expected nodes are Ready"
    break
  fi

  if [[ "${elapsed}" -ge "${MAX_WAIT_SECONDS}" ]]; then
    kubectl get nodes -o wide || true
    err "Timed out waiting for ${EXPECTED_NODES} Ready nodes"
  fi

  sleep 10
  elapsed=$((elapsed + 10))
done

# -----------------------------------------------------------------------------
# Ensure Cilium CLI exists on this node (workers may not have it)
# -----------------------------------------------------------------------------
if ! command -v cilium >/dev/null 2>&1; then
  log "Cilium CLI not found on this node — installing"
  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64)  CLI_ARCH="amd64" ;;
    aarch64) CLI_ARCH="arm64" ;;
    *) err "Unsupported architecture: ${ARCH}" ;;
  esac
  VERSION="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
  TMPDIR_CLI="$(mktemp -d)"
  curl -fsSL "https://github.com/cilium/cilium-cli/releases/download/${VERSION}/cilium-linux-${CLI_ARCH}.tar.gz" \
    -o "${TMPDIR_CLI}/cilium.tgz"
  tar -xzf "${TMPDIR_CLI}/cilium.tgz" -C "${TMPDIR_CLI}"
  install -m 0755 "${TMPDIR_CLI}/cilium" /usr/local/bin/cilium
  rm -rf "${TMPDIR_CLI}"
fi

log "Waiting for Cilium to become healthy across the cluster"
cilium status --wait --wait-duration 15m | tee -a "${REPORT_FILE}"

# -----------------------------------------------------------------------------
# Required validation commands
# -----------------------------------------------------------------------------
run_check() {
  local title="$1"
  shift
  log "Running: ${title}"
  {
    echo
    echo "----- ${title} -----"
    "$@"
  } | tee -a "${REPORT_FILE}"
}

run_check "kubectl get nodes -o wide" kubectl get nodes -o wide
run_check "kubectl get pods -A -o wide" kubectl get pods -A -o wide
run_check "kubectl get svc -A" kubectl get svc -A
run_check "kubectl cluster-info" kubectl cluster-info
run_check "kubectl version" kubectl version
run_check "cilium status" cilium status

# Assert every node is Ready
NOT_READY="$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1}' || true)"
if [[ -n "${NOT_READY}" ]]; then
  err "Nodes not Ready: ${NOT_READY}"
fi

NODE_COUNT="$(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
[[ "${NODE_COUNT}" -ge "${EXPECTED_NODES}" ]] || err "Expected ${EXPECTED_NODES} nodes, found ${NODE_COUNT}"

log "Running cilium connectivity test (this can take several minutes)"
set +e
cilium connectivity test | tee -a "${REPORT_FILE}"
CONN_RC=$?
set -e

if [[ "${CONN_RC}" -ne 0 ]]; then
  err "cilium connectivity test failed with exit code ${CONN_RC}"
fi

{
  echo
  echo "===== VALIDATION PASSED ====="
  echo "All ${EXPECTED_NODES} nodes are Ready"
  echo "Cilium status is healthy"
  echo "Cilium connectivity test passed"
} | tee -a "${REPORT_FILE}"

log "Cluster validation completed successfully"
log "Report saved to ${REPORT_FILE}"
