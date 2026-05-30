# =============================================================================
# variables.pkr.hcl — Shared Packer variable definitions
# =============================================================================
# All PKI material is injected at build time via these variables.
# No PKI variable has a default — build fails fast if any is missing.
# =============================================================================

# ── PKI material (sensitive, no defaults) ─────────────────────────────────────

variable "root_ca_cert" {
  description = "PEM-encoded root CA certificate from security-infra/pki/root-ca.crt"
  type        = string
  sensitive   = true
}

variable "discovery_enrollment_cert" {
  description = "PEM-encoded discovery enrollment certificate from security-infra/pki/discovery-enrollment.crt"
  type        = string
  sensitive   = true
  default     = ""
}

variable "discovery_enrollment_key" {
  description = "PEM-encoded discovery enrollment private key from security-infra/pki/discovery-enrollment.key"
  type        = string
  sensitive   = true
  default     = ""
}

# ── Discovery endpoint (no default) ──────────────────────────────────────────

variable "genie_endpoint" {
  description = "Full URL of the Genie discovery endpoint (e.g. https://genie.lab.sarins.info/discover)"
  type        = string
  default     = ""
}

# ── Discovery script (path on the build host) ─────────────────────────────────

variable "discover_sh" {
  description = "Local path to discover.sh from the infra-controller repo; injected via file provisioner"
  type        = string
  default     = ""
}

# ── OS selection (for shared discovery template) ──────────────────────────────

variable "os_variant" {
  description = "OS variant to build: ubuntu24 | rocky9"
  type        = string
  default     = "ubuntu24"

  validation {
    condition     = contains(["ubuntu24", "rocky9"], var.os_variant)
    error_message = "os_variant must be ubuntu24 or rocky9."
  }
}

# ── Architecture ──────────────────────────────────────────────────────────────

variable "arch" {
  description = "Target architecture: amd64 | arm64"
  type        = string
  default     = "amd64"

  validation {
    condition     = contains(["amd64", "arm64"], var.arch)
    error_message = "arch must be amd64 or arm64."
  }
}

# ── Build output ──────────────────────────────────────────────────────────────

variable "output_directory" {
  description = "Directory where built disk images are written"
  type        = string
  default     = ".packer/output"
}

variable "headless" {
  description = "Run QEMU in headless mode (no display window)"
  type        = bool
  default     = true
}
