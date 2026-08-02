#!/usr/bin/env bash
# =============================================================================
# common.sh
# Baseline Linux configuration for every Kubernetes node.
# Idempotent: safe to re-run via `vagrant provision`.
# =============================================================================
set -euxo pipefail

LOG_TAG="[common]"
log() { echo "${LOG_TAG} $(date -u +'%Y-%m-%dT%H:%M:%SZ') $*"; }
err() { echo "${LOG_TAG} ERROR: $*" >&2; }

export DEBIAN_FRONTEND=noninteractive

NODE_HOSTNAME="${NODE_HOSTNAME:-$(hostname)}"
MASTER_IP="${MASTER_IP:-192.168.56.10}"
WORKER1_IP="${WORKER1_IP:-192.168.56.11}"
WORKER2_IP="${WORKER2_IP:-192.168.56.12}"
WORKER3_IP="${WORKER3_IP:-192.168.56.13}"

DEVOPS_USER="devops"
DEVOPS_PASS='P@ssw0rd1234'

log "Starting common provisioning on ${NODE_HOSTNAME}"

# -----------------------------------------------------------------------------
# Hostname
# -----------------------------------------------------------------------------
log "Configuring hostname"
hostnamectl set-hostname "${NODE_HOSTNAME}"
if ! grep -qE "^127\.0\.1\.1\s+${NODE_HOSTNAME}" /etc/hosts; then
  sed -i "/^127\.0\.1\.1/d" /etc/hosts
  echo "127.0.1.1 ${NODE_HOSTNAME}" >> /etc/hosts
fi

# -----------------------------------------------------------------------------
# Cluster /etc/hosts entries
# -----------------------------------------------------------------------------
log "Updating /etc/hosts with cluster nodes"
HOSTS_BLOCK=$(cat <<EOF
# --- kubernetes-lab begin ---
${MASTER_IP} k8s-master
${WORKER1_IP} k8s-worker1
${WORKER2_IP} k8s-worker2
${WORKER3_IP} k8s-worker3
# --- kubernetes-lab end ---
EOF
)

if grep -q "# --- kubernetes-lab begin ---" /etc/hosts; then
  # Replace existing managed block
  sed -i "/# --- kubernetes-lab begin ---/,/# --- kubernetes-lab end ---/d" /etc/hosts
fi
echo "${HOSTS_BLOCK}" >> /etc/hosts

# -----------------------------------------------------------------------------
# Timezone & locale
# -----------------------------------------------------------------------------
log "Setting timezone UTC and locale en_US.UTF-8"
timedatectl set-timezone UTC

apt-get update -y
apt-get install -y locales
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# -----------------------------------------------------------------------------
# Administrator account (devops)
# -----------------------------------------------------------------------------
log "Ensuring devops administrator account"
if ! id -u "${DEVOPS_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "${DEVOPS_USER}"
fi

# Always ensure group, shell, and password match requirements
usermod -aG sudo "${DEVOPS_USER}"
usermod -s /bin/bash "${DEVOPS_USER}"
echo "${DEVOPS_USER}:${DEVOPS_PASS}" | chpasswd

# Passwordless sudo
SUDOERS_FILE="/etc/sudoers.d/99-${DEVOPS_USER}"
echo "${DEVOPS_USER} ALL=(ALL) NOPASSWD:ALL" > "${SUDOERS_FILE}"
chmod 0440 "${SUDOERS_FILE}"
visudo -cf "${SUDOERS_FILE}"

# SSH authorized_keys: copy from vagrant user if present (idempotent)
DEVOPS_HOME="$(getent passwd "${DEVOPS_USER}" | cut -d: -f6)"
install -d -m 700 -o "${DEVOPS_USER}" -g "${DEVOPS_USER}" "${DEVOPS_HOME}/.ssh"
if [[ -f /home/vagrant/.ssh/authorized_keys ]]; then
  install -m 600 -o "${DEVOPS_USER}" -g "${DEVOPS_USER}" \
    /home/vagrant/.ssh/authorized_keys "${DEVOPS_HOME}/.ssh/authorized_keys"
fi

# -----------------------------------------------------------------------------
# SSH hardening / requirements
# -----------------------------------------------------------------------------
log "Configuring SSH daemon"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
mkdir -p "${SSHD_DROPIN_DIR}"
cat > "${SSHD_DROPIN_DIR}/99-kubernetes-lab.conf" <<'EOF'
PasswordAuthentication yes
PubkeyAuthentication yes
PermitRootLogin no
ChallengeResponseAuthentication no
UsePAM yes
EOF

systemctl enable ssh
systemctl restart ssh || systemctl restart sshd

# -----------------------------------------------------------------------------
# Utility packages
# -----------------------------------------------------------------------------
log "Installing utility packages"
apt-get install -y \
  vim \
  nano \
  curl \
  wget \
  git \
  jq \
  unzip \
  zip \
  tree \
  htop \
  net-tools \
  dnsutils \
  tcpdump \
  lsof \
  bash-completion \
  software-properties-common \
  apt-transport-https \
  ca-certificates \
  gnupg \
  openssl \
  apparmor \
  apparmor-utils \
  cloud-guest-utils \
  e2fsprogs \
  xfsprogs

# -----------------------------------------------------------------------------
# Grow root filesystem if the virtual disk was expanded by Vagrant
# -----------------------------------------------------------------------------
log "Ensuring root filesystem uses available disk capacity"
ROOT_SRC="$(findmnt -n -o SOURCE / || true)"
if [[ -n "${ROOT_SRC}" ]]; then
  # Plain partitions: /dev/sda1, /dev/vda1, /dev/nvme0n1p1, etc.
  if [[ "${ROOT_SRC}" =~ ^/dev/((sd[a-z]|vd[a-z]|xvd[a-z]|nvme[0-9]+n[0-9]+))p?([0-9]+)$ ]]; then
    DISK="/dev/${BASH_REMATCH[1]}"
    PART="${BASH_REMATCH[3]}"
    growpart "${DISK}" "${PART}" || true
  fi

  FSTYPE="$(findmnt -n -o FSTYPE / || true)"
  case "${FSTYPE}" in
    ext2|ext3|ext4) resize2fs "${ROOT_SRC}" || true ;;
    xfs) xfs_growfs / || true ;;
  esac

  # LVM root volumes (common on some Ubuntu images)
  if [[ "${ROOT_SRC}" == /dev/mapper/* ]] || [[ "${ROOT_SRC}" == /dev/*/* ]]; then
    pvresize "$(lsblk -no PKNAME "${ROOT_SRC}" 2>/dev/null | head -n1 | sed 's#^#/dev/#')" 2>/dev/null || true
    lvextend -l +100%FREE "${ROOT_SRC}" 2>/dev/null || true
    case "${FSTYPE}" in
      ext2|ext3|ext4) resize2fs "${ROOT_SRC}" || true ;;
      xfs) xfs_growfs / || true ;;
    esac
  fi
fi

# -----------------------------------------------------------------------------
# Disable swap (required by kubelet)
# -----------------------------------------------------------------------------
log "Disabling swap"
swapoff -a || true
# Comment out any swap entries in fstab
if grep -qE '^\s*[^#].*\s+swap\s+' /etc/fstab; then
  sed -i.bak -E 's/^(\s*[^#].*\s+swap\s+)/# \1/' /etc/fstab
fi
# Ensure swap stays off across boots via systemd unit mask
systemctl mask swap.target >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# Disable UFW firewall
# -----------------------------------------------------------------------------
log "Disabling ufw"
if command -v ufw >/dev/null 2>&1; then
  ufw disable || true
  systemctl disable --now ufw >/dev/null 2>&1 || true
fi

# -----------------------------------------------------------------------------
# Kernel modules (overlay, br_netfilter)
# -----------------------------------------------------------------------------
log "Loading and persisting kernel modules"
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# -----------------------------------------------------------------------------
# Sysctl (bridge + ip_forward) — persist after reboot
# -----------------------------------------------------------------------------
log "Applying sysctl networking settings"
install -m 0644 /vagrant/configs/sysctl.conf /etc/sysctl.d/99-kubernetes.conf
sysctl --system

# Verify required settings
sysctl net.bridge.bridge-nf-call-iptables | grep -q '= 1'
sysctl net.bridge.bridge-nf-call-ip6tables | grep -q '= 1'
sysctl net.ipv4.ip_forward | grep -q '= 1'

log "Common provisioning completed successfully on ${NODE_HOSTNAME}"
