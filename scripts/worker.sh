#!/usr/bin/env bash
# =============================================================================
# worker.sh
# Join a worker node to the cluster using the control-plane join script.
# Idempotent: skips join when the node is already part of a cluster.
# =============================================================================
set -euxo pipefail

LOG_TAG="[worker]"
log() { echo "${LOG_TAG} $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*"; }
err() { echo "${LOG_TAG} ERROR: $*" >&2; exit 1; }

JOIN_COMMAND_FILE="${JOIN_COMMAND_FILE:-/vagrant/.cluster/join.sh}"
NODE_HOSTNAME="${NODE_HOSTNAME:-$(hostname)}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-900}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"

log "Starting worker join for ${NODE_HOSTNAME}"

# -----------------------------------------------------------------------------
# Idempotency: already joined?
# -----------------------------------------------------------------------------
if [[ -f /etc/kubernetes/kubelet.conf ]]; then
  log "kubelet.conf present — node already joined; ensuring kubelet is running"
  systemctl enable --now kubelet || true
  systemctl is-active --quiet kubelet || err "kubelet is not active on already-joined node"
  log "Worker ${NODE_HOSTNAME} already joined; nothing to do"
  exit 0
fi

# -----------------------------------------------------------------------------
# Wait for control plane to publish the join command
# -----------------------------------------------------------------------------
log "Waiting for join command at ${JOIN_COMMAND_FILE} (timeout ${MAX_WAIT_SECONDS}s)"
elapsed=0
while [[ ! -x "${JOIN_COMMAND_FILE}" ]]; do
  if [[ "${elapsed}" -ge "${MAX_WAIT_SECONDS}" ]]; then
    err "Timed out waiting for join command from control plane"
  fi
  sleep "${POLL_INTERVAL}"
  elapsed=$((elapsed + POLL_INTERVAL))
  log "Still waiting for join command... (${elapsed}s)"
done

# Extra settle time for API server readiness after join script appears
sleep 5

log "Join command available; joining cluster"
# shellcheck disable=SC1090
bash "${JOIN_COMMAND_FILE}"

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
[[ -f /etc/kubernetes/kubelet.conf ]] || err "Join completed but kubelet.conf is missing"
systemctl enable kubelet
systemctl restart kubelet || true

for i in $(seq 1 30); do
  if systemctl is-active --quiet kubelet; then
    log "kubelet is active"
    break
  fi
  if [[ "${i}" -eq 30 ]]; then
    err "kubelet failed to become active after join"
  fi
  sleep 2
done

log "Worker ${NODE_HOSTNAME} joined the cluster successfully"
