# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Production-ready Kubernetes lab on VirtualBox.
# Usage: vagrant up
#
# Creates:
#   - 1 control plane  (k8s-master)  @ 192.168.56.10
#   - 3 worker nodes   (k8s-workerN) @ 192.168.56.11-13
#
# Provisioning order (default sequential):
#   1) master: baseline -> containerd -> kube packages -> kubeadm init -> Cilium
#   2) workers: baseline -> containerd -> kube packages -> kubeadm join
#   3) final worker runs full cluster validation (nodes Ready + connectivity)

Vagrant.require_version ">= 2.3.0"

# -----------------------------------------------------------------------------
# Cluster topology
# -----------------------------------------------------------------------------
# Ubuntu 24.04 LTS (Noble Numbat).
# Canonical no longer publishes official Vagrant boxes for 24.04+
# (ubuntu/noble64 -> 404). Use the community-standard Bento box, which is
# Ubuntu Server 24.04 with VirtualBox Guest Additions and is downloaded
# automatically from Vagrant Cloud on first `vagrant up`.
BOX_IMAGE = "bento/ubuntu-24.04"

# Bento ships a ~64GB primary disk, which already meets the lab targets
# (master >= 60GB, workers >= 40GB). Vagrant cannot shrink disks, so we do
# not force a smaller size. Optionally grow the master further below.
MASTER_DISK_GB = 60
WORKER_DISK_GB = 40
# Bento default is typically 64; only request a grow when larger.
BENTO_DEFAULT_DISK_GB = 64

NETWORK_PREFIX = "192.168.56"
MASTER_IP      = "#{NETWORK_PREFIX}.10"

NODES = {
  "k8s-master" => {
    ip: MASTER_IP,
    cpus: 2,
    memory: 4096,
    disk_gb: MASTER_DISK_GB,
    role: "master"
  },
  "k8s-worker1" => {
    ip: "#{NETWORK_PREFIX}.11",
    cpus: 2,
    memory: 2048,
    disk_gb: WORKER_DISK_GB,
    role: "worker"
  },
  "k8s-worker2" => {
    ip: "#{NETWORK_PREFIX}.12",
    cpus: 2,
    memory: 2048,
    disk_gb: WORKER_DISK_GB,
    role: "worker"
  },
  "k8s-worker3" => {
    ip: "#{NETWORK_PREFIX}.13",
    cpus: 2,
    memory: 2048,
    disk_gb: WORKER_DISK_GB,
    role: "worker",
    final_validator: true
  }
}

# Shared artifacts written by the control plane and consumed by workers
JOIN_COMMAND_FILE = "/vagrant/.cluster/join.sh"
KUBECONFIG_FILE   = "/vagrant/.cluster/admin.conf"

Vagrant.configure("2") do |config|
  config.vm.box = BOX_IMAGE
  config.vm.box_check_update = true

  # Synced folder works on Windows, macOS, and Linux hosts via VirtualBox Guest Additions
  config.vm.synced_folder ".", "/vagrant", type: "virtualbox"

  # Disable default VB guest additions auto-update if the plugin is present
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
  end

  NODES.each do |name, node|
    config.vm.define name, primary: (node[:role] == "master") do |node_config|
      node_config.vm.hostname = name

      # Host-only / private network so all nodes can communicate
      node_config.vm.network "private_network", ip: node[:ip]

      # Grow primary disk only when the requested size exceeds the box default.
      # (Vagrant/VirtualBox cannot shrink an existing virtual disk.)
      if node[:disk_gb] > BENTO_DEFAULT_DISK_GB
        ENV["VAGRANT_EXPERIMENTAL"] ||= "disks"
        node_config.vm.disk :disk, size: "#{node[:disk_gb]}GB", primary: true
      end

      node_config.vm.provider "virtualbox" do |vb|
        vb.name   = name
        vb.cpus   = node[:cpus]
        vb.memory = node[:memory]

        # Improve networked lab reliability across host platforms
        vb.customize ["modifyvm", :id, "--nictype1", "virtio"]
        vb.customize ["modifyvm", :id, "--nictype2", "virtio"]
        vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
        vb.customize ["modifyvm", :id, "--ioapic", "on"]
        vb.customize ["modifyvm", :id, "--graphicscontroller", "vmsvga"]
        vb.customize ["modifyvm", :id, "--audio", "none"]
      end

      # ------------------------------------------------------------------
      # Common baseline on every node
      # ------------------------------------------------------------------
      node_config.vm.provision "shell",
        path: "scripts/common.sh",
        env: {
          "NODE_HOSTNAME" => name,
          "MASTER_IP"     => MASTER_IP,
          "WORKER1_IP"    => NODES["k8s-worker1"][:ip],
          "WORKER2_IP"    => NODES["k8s-worker2"][:ip],
          "WORKER3_IP"    => NODES["k8s-worker3"][:ip]
        }

      node_config.vm.provision "shell", path: "scripts/install-containerd.sh"
      node_config.vm.provision "shell", path: "scripts/install-kubernetes.sh"

      # ------------------------------------------------------------------
      # Role-specific bootstrap
      # ------------------------------------------------------------------
      if node[:role] == "master"
        node_config.vm.provision "shell",
          path: "scripts/master.sh",
          env: {
            "MASTER_IP"         => MASTER_IP,
            "JOIN_COMMAND_FILE" => JOIN_COMMAND_FILE,
            "KUBECONFIG_FILE"   => KUBECONFIG_FILE
          }

        node_config.vm.provision "shell",
          path: "scripts/install-cilium.sh",
          env: {
            "MASTER_IP" => MASTER_IP,
            # Hubble UI enabled by default; set ENABLE_HUBBLE_UI=false to skip.
            "ENABLE_HUBBLE_UI" => ENV.fetch("ENABLE_HUBBLE_UI", "true")
          }
      else
        node_config.vm.provision "shell",
          path: "scripts/worker.sh",
          env: {
            "JOIN_COMMAND_FILE" => JOIN_COMMAND_FILE,
            "NODE_HOSTNAME"     => name
          }

        # Run full validation only after the final worker joins so that
        # `vagrant up` finishes with a Ready, connectivity-tested cluster.
        if node[:final_validator]
          node_config.vm.provision "shell",
            path: "scripts/validate.sh",
            env: {
              "EXPECTED_NODES" => NODES.length.to_s,
              "KUBECONFIG"     => KUBECONFIG_FILE
            }
        end
      end
    end
  end
end
