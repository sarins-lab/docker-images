packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.0.10"
    }
  }
}

locals {
  rocky_iso_url      = "https://download.rockylinux.org/pub/rocky/9/isos/${var.arch}/Rocky-9-latest-${var.arch}-minimal.iso"
  rocky_iso_checksum = "file:https://download.rockylinux.org/pub/rocky/9/isos/${var.arch}/Rocky-9-latest-${var.arch}-minimal.iso.CHECKSUM"
}

source "qemu" "rocky_cloud_init" {
  iso_url          = local.rocky_iso_url
  iso_checksum     = local.rocky_iso_checksum
  output_directory = var.output_directory
  vm_name          = "rocky-cloud-init-${var.arch}.qcow2"
  format           = "qcow2"
  headless         = var.headless

  memory      = 2048
  cpus        = 2
  disk_size   = "20G"
  net_device  = "virtio-net"
  disk_interface = "virtio"

  # Kickstart is served from the Packer HTTP directory
  http_directory = "packer/http/rocky"

  boot_wait = "10s"
  boot_command = [
    "<up><wait>",
    "e<wait>",
    "<down><down><end>",
    " inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg",
    "<f10>"
  ]

  ssh_username         = "packer"
  ssh_password         = "packer-build"
  ssh_timeout          = "30m"
  ssh_handshake_attempts = 100
  shutdown_command     = "sudo shutdown -P now"
}

build {
  sources = ["source.qemu.rocky_cloud_init"]

  # 1. Inject Root CA certificate
  provisioner "file" {
    content     = var.root_ca_cert
    destination = "/tmp/lab-root-ca.crt"
  }

  # 2. Install Root CA and update trust store
  provisioner "shell" {
    inline = [
      "set -eux",
      "sudo cp /tmp/lab-root-ca.crt /etc/pki/ca-trust/source/anchors/lab-root-ca.crt",
      "sudo chmod 0644 /etc/pki/ca-trust/source/anchors/lab-root-ca.crt",
      "sudo update-ca-trust extract",
      "rm -f /tmp/lab-root-ca.crt"
    ]
  }

  # 3. CIS host hardening
  provisioner "file" {
    source      = "packer/scripts/rocky-cis-harden-host.sh"
    destination = "/tmp/rocky-cis-harden-host.sh"
  }
  provisioner "shell" {
    inline = [
      "set -eux",
      "chmod +x /tmp/rocky-cis-harden-host.sh",
      "sudo /tmp/rocky-cis-harden-host.sh",
      "rm -f /tmp/rocky-cis-harden-host.sh"
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
      "sudo cloud-init clean --logs --seed 2>/dev/null || true",
      "sudo sync"
    ]
  }
}
