packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.0.10"
    }
  }
}

locals {
  ubuntu_iso_url      = "https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-${var.arch}.iso"
  ubuntu_iso_checksum = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
  output_file         = "${var.output_directory}/ubuntu-cloud-init-${var.arch}.qcow2"
}

source "qemu" "ubuntu_cloud_init" {
  iso_url          = local.ubuntu_iso_url
  iso_checksum     = local.ubuntu_iso_checksum
  output_directory = var.output_directory
  vm_name          = "ubuntu-cloud-init-${var.arch}.qcow2"
  format           = "qcow2"
  headless         = var.headless

  memory      = 2048
  cpus        = 2
  disk_size   = "20G"
  net_device  = "virtio-net"
  disk_interface = "virtio"

  # Subiquity autoinstall is served from the Packer HTTP directory
  http_directory = "packer/http/ubuntu"

  boot_wait = "5s"
  boot_command = [
    "<wait5>",
    "e<wait>",
    "<down><down><down><end>",
    " autoinstall ds=nocloud-net\\;seedfrom=http://{{ .HTTPIP }}:{{ .HTTPPort }}/",
    "<f10>"
  ]

  ssh_username         = "packer"
  ssh_password         = "packer-build"
  ssh_timeout          = "30m"
  ssh_handshake_attempts = 100
  shutdown_command     = "sudo shutdown -P now"
}

build {
  sources = ["source.qemu.ubuntu_cloud_init"]

  # 1. Inject Root CA certificate
  provisioner "file" {
    content     = var.root_ca_cert
    destination = "/tmp/lab-root-ca.crt"
  }

  # 2. Install Root CA and update trust store
  provisioner "shell" {
    inline = [
      "set -eux",
      "sudo cp /tmp/lab-root-ca.crt /usr/local/share/ca-certificates/lab-root-ca.crt",
      "sudo chmod 0644 /usr/local/share/ca-certificates/lab-root-ca.crt",
      "sudo update-ca-certificates",
      "rm -f /tmp/lab-root-ca.crt"
    ]
  }

  # 3. CIS host hardening
  provisioner "file" {
    source      = "packer/scripts/cis-harden-host.sh"
    destination = "/tmp/cis-harden-host.sh"
  }
  provisioner "shell" {
    inline = [
      "set -eux",
      "chmod +x /tmp/cis-harden-host.sh",
      "sudo /tmp/cis-harden-host.sh",
      "rm -f /tmp/cis-harden-host.sh"
    ]
  }

  # 4. Cloud-init datasource configuration
  provisioner "file" {
    source      = "packer/scripts/cloud-init-setup.sh"
    destination = "/tmp/cloud-init-setup.sh"
  }
  provisioner "shell" {
    inline = [
      "set -eux",
      "chmod +x /tmp/cloud-init-setup.sh",
      "sudo /tmp/cloud-init-setup.sh",
      "rm -f /tmp/cloud-init-setup.sh"
    ]
  }

  # 5. Cleanup: remove packer user and truncate machine-id for clean cloning
  provisioner "shell" {
    inline = [
      "set -eux",
      "sudo userdel -r packer 2>/dev/null || true",
      "sudo rm -f /etc/sudoers.d/packer",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      "sudo cloud-init clean --logs --seed",
      "sudo sync"
    ]
  }
}
