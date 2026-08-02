#!/usr/bin/env bash
# =============================================================================
# install-containerd.sh
# Install and configure the latest stable containerd with systemd cgroup.
# Idempotent: safe to re-run via `vagrant provision`.
# =============================================================================
set -euxo pipefail

LOG_TAG="[containerd]"
log() { echo "${LOG_TAG} $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*"; }
err() { echo "${LOG_TAG} ERROR: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

log "Installing containerd prerequisites"
apt-get update -y
apt-get install -y ca-certificates curl gnupg apt-transport-https

# -----------------------------------------------------------------------------
# Docker / containerd apt repository (official packages)
# -----------------------------------------------------------------------------
log "Configuring Docker apt repository for containerd.io"
install -m 0755 -d /etc/apt/keyrings
# Always refresh the keyring idempotently; avoid gpg TTY overwrite prompts.
TMP_DOCKER_KEYRING="$(mktemp)"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --batch --yes --dearmor -o "${TMP_DOCKER_KEYRING}"
install -m 0644 "${TMP_DOCKER_KEYRING}" /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
rm -f "${TMP_DOCKER_KEYRING}"

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF

apt-get update -y

log "Installing latest stable containerd.io"
apt-get install -y containerd.io

# -----------------------------------------------------------------------------
# Configure containerd (systemd cgroup driver)
# Prefer a generated default config (tracks upstream), then enforce SystemdCgroup.
# Project template at configs/containerd-config.toml documents the required shape.
# -----------------------------------------------------------------------------
log "Writing containerd configuration with SystemdCgroup=true"
mkdir -p /etc/containerd

TMP_CONFIG="$(mktemp)"
if containerd config default > "${TMP_CONFIG}" 2>/dev/null; then
  install -m 0644 "${TMP_CONFIG}" /etc/containerd/config.toml
else
  log "containerd config default failed — falling back to project template"
  [[ -f /vagrant/configs/containerd-config.toml ]] \
    || err "No containerd config template available"
  install -m 0644 /vagrant/configs/containerd-config.toml /etc/containerd/config.toml
fi
rm -f "${TMP_CONFIG}"

# Enforce systemd cgroup driver (required for kubelet + systemd)
if grep -q 'SystemdCgroup = false' /etc/containerd/config.toml; then
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
elif ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
  # Older templates may omit the key; inject under runc options when possible
  if grep -q '\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runc\.options\]' /etc/containerd/config.toml; then
    sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runc\.options\]/a\            SystemdCgroup = true' \
      /etc/containerd/config.toml
  else
    err "Unable to enable SystemdCgroup in containerd config"
  fi
fi

grep -q 'SystemdCgroup = true' /etc/containerd/config.toml \
  || err "SystemdCgroup not enabled in /etc/containerd/config.toml"

# Keep a copy of the effective config in the shared project folder for operators
mkdir -p /vagrant/.cluster
cp /etc/containerd/config.toml /vagrant/.cluster/containerd-config.effective.toml || true

# -----------------------------------------------------------------------------
# Enable and start containerd
# -----------------------------------------------------------------------------
log "Enabling and starting containerd"
systemctl daemon-reload
systemctl enable containerd
systemctl restart containerd

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
log "Verifying containerd installation"
systemctl is-active --quiet containerd || err "containerd is not active"
systemctl is-enabled --quiet containerd || err "containerd is not enabled"
containerd --version
ctr version >/dev/null

[[ -S /run/containerd/containerd.sock ]] || err "containerd CRI socket missing"

log "containerd installed and verified successfully"
