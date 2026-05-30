packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.0.10"
    }
  }
}

locals {
  # OS-specific config branched on var.os_variant
  os_config = {
    ubuntu24 = {
      iso_url       = "https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-${var.arch}.iso"
      iso_checksum  = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
      http_dir      = "packer/http/ubuntu"
      boot_command  = [
        "<wait5>",
        "e<wait>",
        "<down><down><down><end>",
        " autoinstall ds=nocloud-net\\;seedfrom=http://{{ .HTTPIP }}:{{ .HTTPPort }}/",
        "<f10>"
      ]
      harden_script   = "packer/scripts/cis-harden-host.sh"
      ca_install_cmd  = ["sudo cp /tmp/lab-root-ca.crt /usr/local/share/ca-certificates/lab-root-ca.crt", "sudo chmod 0644 /usr/local/share/ca-certificates/lab-root-ca.crt", "sudo update-ca-certificates"]
      firewall_script = "packer/scripts/ufw-discovery.sh"
    }
    rocky9 = {
      iso_url       = "https://download.rockylinux.org/pub/rocky/9/isos/${var.arch}/Rocky-9-latest-${var.arch}-minimal.iso"
      iso_checksum  = "file:https://download.rockylinux.org/pub/rocky/9/isos/${var.arch}/Rocky-9-latest-${var.arch}-minimal.iso.CHECKSUM"
      http_dir      = "packer/http/rocky"
      boot_command  = [
        "<up><wait>",
        "e<wait>",
        "<down><down><end>",
        " inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg",
        "<f10>"
      ]
      harden_script   = "packer/scripts/rocky-cis-harden-host.sh"
      ca_install_cmd  = ["sudo cp /tmp/lab-root-ca.crt /etc/pki/ca-trust/source/anchors/lab-root-ca.crt", "sudo chmod 0644 /etc/pki/ca-trust/source/anchors/lab-root-ca.crt", "sudo update-ca-trust extract"]
      firewall_script = "packer/scripts/firewalld-discovery.sh"
    }
  }

  cfg           = local.os_config[var.os_variant]
  output_format = var.arch == "arm64" ? "img" : "qcow2"
  vm_name       = "discovery-${var.os_variant}-${var.arch}.${local.output_format}"
}

source "qemu" "discovery" {
  iso_url          = local.cfg.iso_url
  iso_checksum     = local.cfg.iso_checksum
  output_directory = var.output_directory
  vm_name          = local.vm_name
  format           = local.output_format
  headless         = var.headless

  memory      = 2048
  cpus        = 2
  disk_size   = "20G"
  net_device  = "virtio-net"
  disk_interface = "virtio"

  http_directory = local.cfg.http_dir

  boot_wait    = "5s"
  boot_command = local.cfg.boot_command

  ssh_username         = "packer"
  ssh_password         = "packer-build"
  ssh_timeout          = "30m"
  ssh_handshake_attempts = 100
  shutdown_command     = "sudo shutdown -P now"
}

build {
  sources = ["source.qemu.discovery"]

  # 1. Inject Root CA certificate
  provisioner "file" {
    content     = var.root_ca_cert
    destination = "/tmp/lab-root-ca.crt"
  }

  # 2. Install Root CA (OS-specific trust update)
  provisioner "shell" {
    inline = concat(local.cfg.ca_install_cmd, ["rm -f /tmp/lab-root-ca.crt"])
  }

  # 3. CIS host hardening (OS-specific script)
  provisioner "file" {
    source      = local.cfg.harden_script
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

  # 4. Install phone-home service (only when discover_sh is provided)
  provisioner "file" {
    source      = var.discover_sh
    destination = "/tmp/discover.sh"
    # Guard: if discover_sh is empty the build will fail here — set it via -var
    generated   = true
  }
  provisioner "file" {
    source      = "packer/scripts/install-phone-home.sh"
    destination = "/tmp/install-phone-home.sh"
  }
  provisioner "shell" {
    inline = [
      "set -eux",
      "chmod +x /tmp/install-phone-home.sh",
      "sudo /tmp/install-phone-home.sh",
      "rm -f /tmp/install-phone-home.sh"
    ]
  }

  # 5. Inject discovery enrollment certificate
  provisioner "shell" {
    inline = [
      "set -eux",
      "sudo mkdir -p /etc/discovery",
      "sudo chmod 0700 /etc/discovery"
    ]
  }
  provisioner "file" {
    content     = var.discovery_enrollment_cert
    destination = "/tmp/discovery-enrollment.crt"
  }
  provisioner "shell" {
    inline = [
      "set -eux",
      "sudo mv /tmp/discovery-enrollment.crt /etc/discovery/enrollment.crt",
      "sudo chmod 0644 /etc/discovery/enrollment.crt"
    ]
  }

  # 6. Inject discovery enrollment key (sensitive — file removed from disk after copy)
  provisioner "file" {
    content     = var.discovery_enrollment_key
    destination = "/tmp/discovery-enrollment.key"
  }
  provisioner "shell" {
    inline = [
      "set -eux",
      "sudo mv /tmp/discovery-enrollment.key /etc/discovery/enrollment.key",
      "sudo chmod 0600 /etc/discovery/enrollment.key",
      "sudo chown root:root /etc/discovery/enrollment.key"
    ]
  }

  # 7. Apply restrictive firewall — outbound DNS and Genie HTTPS only
  provisioner "file" {
    source      = local.cfg.firewall_script
    destination = "/tmp/firewall-discovery.sh"
  }
  provisioner "shell" {
    inline = [
      "set -eux",
      "chmod +x /tmp/firewall-discovery.sh",
      "sudo /tmp/firewall-discovery.sh '${var.genie_endpoint}'",
      "rm -f /tmp/firewall-discovery.sh"
    ]
  }

  # 8. Cleanup: remove packer user, truncate machine-id
  provisioner "shell" {
    inline = [
      "set -eux",
      "sudo userdel -r packer 2>/dev/null || true",
      "sudo rm -f /etc/sudoers.d/packer",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      "sudo sync"
    ]
  }
}
