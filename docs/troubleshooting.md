# Troubleshooting

This guide covers common failures when bringing up the Kubernetes VirtualBox lab with Vagrant.

## Quick diagnostics

From the project root on the host:

```bash
vagrant status
vagrant ssh k8s-master -c "kubectl get nodes -o wide"
vagrant ssh k8s-master -c "kubectl get pods -A"
vagrant ssh k8s-master -c "cilium status"
```

Artifacts written during provisioning (shared folder):

| Path | Purpose |
|------|---------|
| `.cluster/admin.conf` | Cluster kubeconfig |
| `.cluster/join.sh` | Worker join script |
| `.cluster/join-command.txt` | Plain-text join command |
| `.cluster/kubeadm-init.log` | `kubeadm init` output |
| `.cluster/cilium-status.txt` | Cilium status snapshot |
| `.cluster/validation-report.txt` | Full validation report |

---

## Host resource problems

### Symptoms

- VMs fail to start
- VirtualBox errors about memory
- Nodes crash / get OOM-killed during provisioning

### Checks

- Host free RAM should be **at least 12 GB** (lab consumes ~10 GB guest RAM)
- Host disk should have **at least 200 GB** free for boxes + 4 virtual disks
- CPU virtualization (Intel VT-x / AMD-V) must be enabled in BIOS/UEFI

### Fixes

- Close other memory-heavy applications
- Lower unused host workloads before `vagrant up`
- Ensure Hyper-V does not conflict with VirtualBox on Windows (see below)

---

## Windows: Hyper-V / VirtualBox conflicts

### Symptoms

- `VBoxManage` errors
- 64-bit guests refuse to start
- Extremely slow networking

### Fixes

1. Disable Hyper-V features that capture the hypervisor, **or**
2. Use VirtualBox with Windows Hypervisor Platform carefully per Oracle docs, **or**
3. Prefer WSL2 + nested virt only if your VirtualBox build supports it

Also ensure the VirtualBox Host-Only Ethernet Adapter can use `192.168.56.0/24`.

---

## Private network / Host-Only adapter issues

### Symptoms

- Nodes cannot ping each other
- `kubeadm join` times out against `192.168.56.10:6443`

### Checks

```bash
vagrant ssh k8s-worker1 -c "ping -c 3 192.168.56.10"
vagrant ssh k8s-master  -c "ip -br a"
```

### Fixes

- Confirm VirtualBox Host-Only network exists for `192.168.56.0/24`
- Avoid DHCP conflicts on the same host-only network
- Re-create the host-only adapter in VirtualBox UI if it was deleted
- Re-run: `vagrant halt && vagrant up --provision`

---

## Box download / 404 errors

### Symptom

```text
The box 'ubuntu/noble64' could not be found ... Error: 404
```

### Cause

Canonical stopped publishing official Vagrant boxes for Ubuntu 24.04+.  
This project uses `bento/ubuntu-24.04` instead.

### Fix

Pull the latest Vagrantfile from this repo, then:

```bash
vagrant up
```

To pre-download the box manually:

```bash
vagrant box add bento/ubuntu-24.04 --provider virtualbox
```

---

## Disk resize failures

### Symptoms

- Vagrant errors while configuring primary disks
- Guest root filesystem unexpectedly small

### Fixes

- `bento/ubuntu-24.04` already ships ~64 GB disks (meets master 60 GB / worker 40 GB). The Vagrantfile only requests a grow when a size **larger than 64 GB** is configured.
- Use **Vagrant >= 2.3** and a recent VirtualBox
- Destroy and recreate if a previous partial disk resize left the VM inconsistent:

```bash
vagrant destroy -f
vagrant up
```

- Inside a guest, confirm capacity:

```bash
df -h /
lsblk
```

`scripts/common.sh` attempts `growpart` + `resize2fs` automatically.

---

## Provisioning fails with `gpg: cannot open '/dev/tty'`

### Symptom

```text
+ curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key
+ gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
gpg: cannot open '/dev/tty': No such device or address
```

### Cause

Re-running provisioning tries to overwrite an existing apt keyring.  
`gpg --dearmor` prompts for confirmation via `/dev/tty`, which is unavailable over Vagrant SSH.

### Fix

Use scripts that write the keyring via `gpg --batch --yes` (or to a temp file + `install`), then continue:

```bash
vagrant provision k8s-master
```

---

## Provisioning fails at Kubernetes package verification

### Symptom

```text
+ dpkg -l kubelet kubeadm kubectl
+ grep -E '^ii'
The SSH command responded with a non-zero exit status.
```

### Cause

After `apt-mark hold`, `dpkg -l` reports status `hi` (held + installed), not `ii`.  
A check that only matches `^ii` exits non-zero under `set -o pipefail`.

### Fix

Use a current `scripts/install-kubernetes.sh` that accepts held packages, then continue:

```bash
vagrant provision k8s-master
```

Or destroy and recreate:

```bash
vagrant destroy -f
vagrant up
```

---

## `kubeadm init` failures

### Symptoms

- Provisioning stops in `scripts/master.sh`
- API server never becomes ready

### Checks

```bash
vagrant ssh k8s-master -c "sudo journalctl -u kubelet -n 100 --no-pager"
vagrant ssh k8s-master -c "sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps -a"
vagrant ssh k8s-master -c "sudo cat /vagrant/.cluster/kubeadm-init.log"
```

### Common causes

| Cause | Fix |
|------|-----|
| Swap still enabled | Re-run `scripts/common.sh` / `vagrant provision k8s-master` |
| containerd not running | `sudo systemctl status containerd` |
| Wrong cgroup driver | Confirm `SystemdCgroup = true` in `/etc/containerd/config.toml` |
| Stale cluster state | `sudo kubeadm reset -f` then `vagrant provision k8s-master` |

---

## Workers cannot join

### Symptoms

- `Timed out waiting for join command`
- `connection refused` to API server

### Checks

```bash
ls -l .cluster/join.sh
vagrant ssh k8s-worker1 -c "cat /vagrant/.cluster/join.sh"
vagrant ssh k8s-master -c "kubectl get csr"
```

### Fixes

1. Ensure the control plane finished first (`vagrant up` sequential default)
2. Refresh the join token on the master:

```bash
vagrant ssh k8s-master -c "sudo bash -lc 'kubeadm token create --print-join-command'"
```

3. Re-provision the worker:

```bash
vagrant provision k8s-worker1
```

---

## Nodes stuck `NotReady`

### Checks

```bash
kubectl get nodes -o wide
kubectl describe node <name>
kubectl -n kube-system get pods -o wide
cilium status
```

### Common causes

- Cilium agent not scheduled/running on the node
- Kernel modules `overlay` / `br_netfilter` missing
- `net.ipv4.ip_forward` not enabled

Re-apply baseline networking:

```bash
vagrant provision k8s-master
```

---

## Cilium install / health problems

### Checks

```bash
vagrant ssh k8s-master -c "cilium status --verbose"
vagrant ssh k8s-master -c "kubectl -n kube-system get pods -l k8s-app=cilium -o wide"
```

### Fixes

- Confirm kube-proxy was skipped and Cilium kube-proxy replacement is enabled
- Confirm install used:

  - `kubeProxyReplacement=true`
  - `k8sServiceHost=192.168.56.10`
  - `k8sServicePort=6443`

- Re-run:

```bash
vagrant ssh k8s-master -c "sudo bash /vagrant/scripts/install-cilium.sh"
```

---

## Hubble Relay / UI `Progress deadline exceeded`

### Symptom

```text
Unable to install Cilium: resource Deployment/kube-system/hubble-relay not ready.
status: Failed, message: Progress deadline exceeded
resource Deployment/kube-system/hubble-ui not ready.
```

### Causes

- **Most common in this lab:** `kubeadm` taints the control plane (`node-role.kubernetes.io/control-plane:NoSchedule`). Hubble Relay/UI have **no tolerations by default**, so on a master-only cluster the pods stay `Pending` until `ProgressDeadlineExceeded`.
- Invalid Helm keys (for example `hubble.relay.dialTimeout`) are rejected by Cilium’s values schema and abort the upgrade, leaving Relay disabled.
- 4 GB control plane + slow VirtualBox/NAT image pulls can also delay rollouts.
- A previous failed rollout leaves Deployments stuck, so the next `--wait` install fails quickly.

### What the project does now

`scripts/install-cilium.sh` installs in phases:

1. Cilium dataplane + Hubble on agents
2. Hubble Relay (required), with **control-plane tolerations**, valid `retryTimeout`/resources, image pre-pull, and retries
3. Hubble UI (on by default; set `ENABLE_HUBBLE_UI=false` to skip)

### Recovery on an existing VM

Update the project files from git (so `/vagrant/scripts/install-cilium.sh` is current), then:

```bat
vagrant ssh k8s-master -c "sudo kubectl -n kube-system delete deploy hubble-relay hubble-ui --ignore-not-found"
vagrant ssh k8s-master -c "sudo bash /vagrant/scripts/install-cilium.sh"
```

After Cilium/Hubble are healthy, continue bringing up workers if needed:

```bat
vagrant up
```

Inspect diagnostics written during failures:

```bat
type .cluster\cilium-diagnostics.txt
```

### Enable Hubble UI on an existing cluster

UI is enabled by default on new installs. On a cluster that was built with UI off:

```bat
vagrant ssh k8s-master -c "sudo ENABLE_HUBBLE_UI=true bash /vagrant/scripts/install-cilium.sh"
```

Verify:

```bat
vagrant ssh k8s-master -c "kubectl -n kube-system get deploy,pods -l k8s-app=hubble-ui -o wide"
vagrant ssh k8s-master -c "cilium status"
```

Open the UI:

```bat
vagrant ssh k8s-master -- -L 12000:127.0.0.1:12000
```

Then inside that SSH session:

```bash
kubectl -n kube-system port-forward svc/hubble-ui 12000:80 --address 127.0.0.1
```

Browse to `http://127.0.0.1:12000` on the host.

To disable UI later:

```bat
vagrant ssh k8s-master -c "sudo ENABLE_HUBBLE_UI=false bash -lc 'cilium hubble enable --relay && cilium upgrade --reuse-values --set hubble.ui.enabled=false --wait'"
```

---

## Connectivity test failures

`cilium connectivity test` is strict and can fail if:

- Not all nodes are Ready
- Hubble relay is still starting
- Host is heavily CPU-constrained (timeouts)

### Known lab flake: `check-log-errors` / `probe=l7-proxy`

Symptom:

```text
❌ 1/80 tests failed ...
Test [check-log-errors]:
  ... msg="No response from probe" ... probe=l7-proxy (1 occurrences)
```

All other connectivity scenarios passed. This is a transient Cilium agent status warning common on 2–4 GB VirtualBox nodes under load; it does not mean datapath is broken.

`scripts/validate.sh` tolerates this specific single-test flake and still marks validation as passed. To re-run validation after updating the script:

```bat
vagrant ssh k8s-worker3 -c "sudo bash /vagrant/scripts/validate.sh"
```

### Other connectivity failures

Retry after Cilium is healthy:

```bash
vagrant ssh k8s-master -c "cilium status --wait"
vagrant ssh k8s-master -c "cilium connectivity test"
```

Or re-run the full validator:

```bash
vagrant ssh k8s-worker3 -c "sudo bash /vagrant/scripts/validate.sh"
```

---

## SSH / devops account issues

### Password login fails

Confirm sshd drop-in:

```bash
vagrant ssh k8s-master -c "sudo cat /etc/ssh/sshd_config.d/99-kubernetes-lab.conf"
```

Expected:

- `PasswordAuthentication yes`
- `PubkeyAuthentication yes`
- `PermitRootLogin no`

### Passwordless sudo fails

```bash
vagrant ssh k8s-master -c "sudo cat /etc/sudoers.d/99-devops"
```

---

## Clean rebuild

When in doubt, destroy and recreate the lab:

```bash
vagrant destroy -f
rm -rf .cluster
vagrant up
```

This recreates all VMs and re-runs the full automated bootstrap.
