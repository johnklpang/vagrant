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

## Disk resize failures

### Symptoms

- Vagrant errors while configuring primary disks
- Guest root filesystem still ~10 GB after boot

### Fixes

- Use **Vagrant >= 2.3** and a recent VirtualBox
- Ensure `VAGRANT_EXPERIMENTAL=disks` is set on older Vagrant (the Vagrantfile sets this)
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

## Connectivity test failures

`cilium connectivity test` is strict and can fail if:

- Not all nodes are Ready
- Hubble relay is still starting
- Host is heavily CPU-constrained (timeouts)

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
