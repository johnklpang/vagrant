#!/usr/bin/env bash
# =============================================================================
# install-kubernetes.sh
# Install latest stable kubeadm, kubelet, and kubectl with pinned versions.
# Idempotent: safe to re-run via `vagrant provision`.
# =============================================================================
set -euxo pipefail

LOG_TAG="[kubernetes]"
log() { echo "${LOG_TAG} $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*"; }
err() { echo "${LOG_TAG} ERROR: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

log "Detecting latest stable Kubernetes release"
STABLE_TAG="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
# Example: v1.32.1 -> 1.32
KUBE_MINOR="$(echo "${STABLE_TAG}" | sed -E 's/^v([0-9]+\.[0-9]+).*/\1/')"
log "Latest stable: ${STABLE_TAG} (pkgs.k8s.io/core:/stable:/v${KUBE_MINOR})"

# -----------------------------------------------------------------------------
# Kubernetes apt repository
# -----------------------------------------------------------------------------
log "Configuring pkgs.k8s.io apt repository"
install -m 0755 -d /etc/apt/keyrings
# --batch --yes: non-interactive overwrite when re-provisioning (no /dev/tty)
TMP_KEYRING="$(mktemp)"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_MINOR}/deb/Release.key" \
  | gpg --batch --yes --dearmor -o "${TMP_KEYRING}"
install -m 0644 "${TMP_KEYRING}" /etc/apt/keyrings/kubernetes-apt-keyring.gpg
rm -f "${TMP_KEYRING}"

cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBE_MINOR}/deb/ /
EOF

apt-get update -y

# -----------------------------------------------------------------------------
# Resolve and pin exact package versions available in the repo
# -----------------------------------------------------------------------------
log "Resolving package versions to pin"
# Prefer the exact patch matching STABLE_TAG when available
CANDIDATE_VERSION="${STABLE_TAG#v}-*"
AVAILABLE_VERSION="$(apt-cache madison kubeadm | awk '{print $3}' | grep -E "^${STABLE_TAG#v}-" | head -n1 || true)"

if [[ -z "${AVAILABLE_VERSION}" ]]; then
  # Fall back to the newest version published for this minor
  AVAILABLE_VERSION="$(apt-cache madison kubeadm | awk 'NR==1{print $3}')"
fi

[[ -n "${AVAILABLE_VERSION}" ]] || err "Unable to determine kubeadm package version"
log "Pinning Kubernetes packages to version ${AVAILABLE_VERSION}"

# Unhold before install/upgrade so re-provisioning can move forward when needed
apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true

apt-get install -y \
  "kubelet=${AVAILABLE_VERSION}" \
  "kubeadm=${AVAILABLE_VERSION}" \
  "kubectl=${AVAILABLE_VERSION}"

apt-mark hold kubelet kubeadm kubectl

# -----------------------------------------------------------------------------
# Enable kubelet (kubeadm starts it after init/join)
# -----------------------------------------------------------------------------
log "Enabling kubelet"
systemctl daemon-reload
systemctl enable kubelet

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
log "Verifying Kubernetes packages"
kubeadm version -o short
kubelet --version
kubectl version --client=true

# After `apt-mark hold`, dpkg status is "hi" (hold+installed), not "ii".
# Accept both so verification does not fail under `set -o pipefail`.
INSTALLED_PKGS="$(dpkg -l kubelet kubeadm kubectl | awk '/^[ih]i / {print $2}' | sort | tr '\n' ' ')"
echo "Installed/held packages: ${INSTALLED_PKGS}"
echo "${INSTALLED_PKGS}" | grep -qw kubelet
echo "${INSTALLED_PKGS}" | grep -qw kubeadm
echo "${INSTALLED_PKGS}" | grep -qw kubectl

log "Kubernetes packages installed and pinned successfully (${AVAILABLE_VERSION})"
