packer {
  required_plugins {
    # mkaczanowski/packer-builder-arm customises a pre-built OS image
    # without an ISO install — requires QEMU user-mode emulation on the build host
    arm-image = {
      source  = "github.com/mkaczanowski/packer-builder-arm"
      version = ">= 0.1.7"
    }
  }
}

locals {
  raspbian_image_url      = "https://downloads.raspberrypi.org/raspios_lite_arm64/images/raspios_lite_arm64-2024-03-15/2024-03-15-raspios-bookworm-arm64-lite.img.xz"
  raspbian_image_checksum = "file:https://downloads.raspberrypi.org/raspios_lite_arm64/images/raspios_lite_arm64-2024-03-15/2024-03-15-raspios-bookworm-arm64-lite.img.xz.sha256"
  output_file             = "${var.output_directory}/raspbian-discovery-arm64.img"
}

source "arm-image" "raspbian_discovery" {
  iso_url          = local.raspbian_image_url
  iso_checksum     = local.raspbian_image_checksum
  output_filename  = local.output_file

  image_build_method = "resize"
  image_size         = "4G"
  image_type         = "dos"

  image_partitions {
    name         = "boot"
    type         = "c"
    start_sector = "8192"
    filesystem   = "vfat"
    size         = "256M"
    mountpoint   = "/boot/firmware"
  }

  image_partitions {
    name         = "root"
    type         = "83"
    start_sector = "532480"
    filesystem   = "ext4"
    size         = "0"
    mountpoint   = "/"
  }

  image_chroot_env = [
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
  ]
}

build {
  sources = ["source.arm-image.raspbian_discovery"]

  # 1. Inject Root CA certificate
  provisioner "file" {
    content     = var.root_ca_cert
    destination = "/usr/local/share/ca-certificates/lab-root-ca.crt"
  }

  # 2. Install Root CA
  provisioner "shell" {
    inline = [
      "set -eux",
      "chmod 0644 /usr/local/share/ca-certificates/lab-root-ca.crt",
      "update-ca-certificates"
    ]
  }

  # 3. Raspbian CIS-equivalent hardening
  provisioner "file" {
    source      = "packer/scripts/raspbian-harden.sh"
    destination = "/tmp/raspbian-harden.sh"
  }
  provisioner "shell" {
    inline = [
      "set -eux",
      "chmod +x /tmp/raspbian-harden.sh",
      "/tmp/raspbian-harden.sh",
      "rm -f /tmp/raspbian-harden.sh"
    ]
  }

  # 4. Install phone-home service
  provisioner "file" {
    source      = var.discover_sh
    destination = "/tmp/discover.sh"
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
      "/tmp/install-phone-home.sh",
      "rm -f /tmp/install-phone-home.sh"
    ]
  }

  # 5. Inject discovery enrollment certificate and key
  provisioner "shell" {
    inline = [
      "set -eux",
      "mkdir -p /etc/discovery",
      "chmod 0700 /etc/discovery"
    ]
  }
  provisioner "file" {
    content     = var.discovery_enrollment_cert
    destination = "/etc/discovery/enrollment.crt"
  }
  provisioner "file" {
    content     = var.discovery_enrollment_key
    destination = "/etc/discovery/enrollment.key"
  }
  provisioner "shell" {
    inline = [
      "set -eux",
      "chmod 0644 /etc/discovery/enrollment.crt",
      "chmod 0600 /etc/discovery/enrollment.key",
      "chown root:root /etc/discovery/enrollment.crt /etc/discovery/enrollment.key"
    ]
  }

  # 6. Apply UFW firewall rules
  provisioner "file" {
    source      = "packer/scripts/ufw-discovery.sh"
    destination = "/tmp/ufw-discovery.sh"
  }
  provisioner "shell" {
    inline = [
      "set -eux",
      "chmod +x /tmp/ufw-discovery.sh",
      "/tmp/ufw-discovery.sh '${var.genie_endpoint}'",
      "rm -f /tmp/ufw-discovery.sh"
    ]
  }

  # 7. Cleanup: truncate machine-id, remove first-run wizard
  provisioner "shell" {
    inline = [
      "set -eux",
      "truncate -s 0 /etc/machine-id",
      "rm -f /var/lib/dbus/machine-id",
      "systemctl disable userconfig.service 2>/dev/null || true",
      "sync"
    ]
  }
}
