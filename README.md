# Kubernetes Lab on Vagrant + VirtualBox

Fully automated Kubernetes lab. Running:

```bash
vagrant up
```

creates **1 control plane + 3 workers** on Ubuntu Server 24.04 LTS, installs containerd and Kubernetes, bootstraps the cluster with `kubeadm`, deploys **Cilium** (kube-proxy replacement + Hubble), joins all workers, and validates that every node is **Ready**.

No manual steps are required after `vagrant up`.

---

## Cluster architecture

```text
                        192.168.56.0/24 (VirtualBox host-only)
        +-------------------+-------------------+-------------------+
        |                   |                   |                   |
        v                   v                   v                   v
 +--------------+   +--------------+   +--------------+   +--------------+
 | k8s-master   |   | k8s-worker1  |   | k8s-worker2  |   | k8s-worker3  |
 | 192.168.56.10|   | 192.168.56.11|   | 192.168.56.12|   | 192.168.56.13|
 | 4GB / 2 vCPU |   | 2GB / 2 vCPU |   | 2GB / 2 vCPU |   | 2GB / 2 vCPU |
 | 60GB disk    |   | 40GB disk    |   | 40GB disk    |   | 40GB disk    |
 | control-plane|   | worker       |   | worker       |   | worker       |
 +--------------+   +--------------+   +--------------+   +--------------+
        |
        +--> kubeadm init (Pod CIDR 10.244.0.0/16)
        +--> Cilium CNI (kube-proxy replacement, Hubble)
        +--> shared artifacts in .cluster/ (kubeconfig + join command)
```

| Node | Role | IP | vCPU | RAM | Disk |
|------|------|----|------|-----|------|
| `k8s-master` | Control plane | `192.168.56.10` | 2 | 4 GB | 60 GB |
| `k8s-worker1` | Worker | `192.168.56.11` | 2 | 2 GB | 40 GB |
| `k8s-worker2` | Worker | `192.168.56.12` | 2 | 2 GB | 40 GB |
| `k8s-worker3` | Worker | `192.168.56.13` | 2 | 2 GB | 40 GB |

**CNI:** Cilium (latest stable) with kube-proxy replacement, Hubble Relay, and Hubble UI  
**Runtime:** containerd (systemd cgroup)  
**OS:** Ubuntu 24.04 LTS via `bento/ubuntu-24.04` (Canonical no longer publishes official 24.04+ Vagrant boxes; `ubuntu/noble64` returns 404)

### Access Hubble UI

After the cluster is up:

```bash
vagrant ssh k8s-master
cilium hubble ui
```

Or port-forward manually and open `http://127.0.0.1:12000` in a browser on the host (with an additional host-side forward if needed):

```bash
vagrant ssh k8s-master -- -L 12000:127.0.0.1:12000
# inside the VM:
kubectl -n kube-system port-forward svc/hubble-ui 12000:80 --address 127.0.0.1
```

To skip UI on very small hosts: set `ENABLE_HUBBLE_UI=false` before `vagrant up`.

---

## Resource requirements

| Resource | Minimum recommended |
|----------|---------------------|
| Host RAM | **16 GB** (lab uses ~10 GB for guests) |
| Host CPU | **4+ cores** with hardware virtualization |
| Host disk | **200 GB free** |
| Network | VirtualBox host-only / private networking support |

---

## Prerequisites

Install on the host:

1. **VirtualBox** (latest)
2. **Vagrant** (latest, >= 2.3.0)
3. Hardware virtualization enabled (VT-x / AMD-V)

Supported hosts: **Windows**, **Linux**, and **macOS**.

---

## Install VirtualBox

### Windows

1. Download from https://www.virtualbox.org/wiki/Downloads
2. Run the installer and accept the networking components prompt
3. Reboot if requested

### macOS

```bash
brew install --cask virtualbox
```

Or install the official DMG from the VirtualBox downloads page.

### Linux (Debian/Ubuntu)

```bash
sudo apt-get update
sudo apt-get install -y virtualbox
```

For the latest upstream packages, follow Oracle’s Linux repository instructions.

---

## Install Vagrant

### Windows

1. Download from https://developer.hashicorp.com/vagrant/install
2. Run the MSI installer
3. Open a new terminal and verify:

```powershell
vagrant version
```

### macOS

```bash
brew install vagrant
vagrant version
```

### Linux (Debian/Ubuntu)

```bash
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update
sudo apt-get install -y vagrant
vagrant version
```

---

## Start cluster

Clone or copy this project, then from the project root:

```bash
vagrant up
```

What happens automatically:

1. Downloads the Ubuntu 24.04 LTS box (`bento/ubuntu-24.04`) on first run
2. Creates 4 VirtualBox VMs with the specs above
3. Configures Linux users, packages, kernel modules, and sysctl
4. Installs containerd, kubeadm, kubelet, kubectl
5. Initializes the control plane (`kubeadm init`, kube-proxy skipped)
6. Installs Cilium + Hubble and the Cilium CLI
7. Joins all three workers
8. Runs validation (`kubectl` + `cilium status` + `cilium connectivity test`)

First boot commonly takes **45–90 minutes** depending on host CPU, disk, and network speed (image pulls + Cilium connectivity test).

---

## Verify cluster

SSH to the control plane:

```bash
vagrant ssh k8s-master
```

Then:

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get svc -A
kubectl cluster-info
kubectl version
cilium status
```

On the host, review the generated report:

```bash
cat .cluster/validation-report.txt
```

All four nodes should show `Ready`.

---

## SSH examples

### Using Vagrant

```bash
vagrant ssh k8s-master
vagrant ssh k8s-worker1
vagrant ssh k8s-worker2
vagrant ssh k8s-worker3
```

### Using the devops administrator account

Password: `P@ssw0rd1234` (passwordless sudo configured)

```bash
ssh devops@192.168.56.10
ssh devops@192.168.56.11
ssh devops@192.168.56.12
ssh devops@192.168.56.13
```

`kubectl` is preconfigured for both `root` and `devops` on the control plane.  
A copy of the kubeconfig is also written to `.cluster/admin.conf` on the host.

---

## Destroy cluster

```bash
vagrant destroy -f
rm -rf .cluster
```

---

## Project structure

```text
.
├── Vagrantfile
├── README.md
├── scripts/
│   ├── common.sh
│   ├── install-containerd.sh
│   ├── install-kubernetes.sh
│   ├── master.sh
│   ├── worker.sh
│   ├── install-cilium.sh
│   └── validate.sh
├── configs/
│   ├── containerd-config.toml
│   └── sysctl.conf
└── docs/
    └── troubleshooting.md
```

---

## Administrator account

| Setting | Value |
|---------|-------|
| Username | `devops` |
| Password | `P@ssw0rd1234` |
| Shell | `bash` |
| sudo | passwordless |
| SSH | password + public key auth |
| root SSH | disabled |

---

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for host networking, disk resize, join failures, Cilium health, and clean rebuild steps.

Common recovery:

```bash
vagrant destroy -f
rm -rf .cluster
vagrant up
```

---

## Notes

- **Box choice:** Starting with Ubuntu 24.04, Canonical no longer produces official Vagrant images. This lab uses [`bento/ubuntu-24.04`](https://app.vagrantup.com/bento/boxes/ubuntu-24.04) (Vanilla Ubuntu 24.04 Server with VirtualBox support). Disk capacity on the box is ~64 GB, which satisfies the 60 GB master / 40 GB worker targets.
- Kubernetes packages are pinned with `apt-mark hold` after install.
- Swap and UFW are disabled on every node.
- Cluster join credentials and kubeconfig are stored under `.cluster/` (ignored by git).
- Validation runs automatically on `k8s-worker3` after all workers join so `vagrant up` exits only when the cluster is operational.
