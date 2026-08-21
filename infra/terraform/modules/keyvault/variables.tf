# ---------------------------------------------------------------------------
# modules/keyvault/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Key Vault name. Globally unique, 3-24 chars, alphanumeric and hyphens, must start with a letter."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.name))
    error_message = "Key Vault names are 3-24 chars, start with a letter, end alphanumeric, and contain only letters, digits and hyphens."
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }

variable "tenant_id" {
  description = "Entra tenant ID that owns the vault."
  type        = string
}

variable "purge_protection_enabled" {
  description = "Prevents permanent deletion during the soft-delete window. Leave false in dev so you can rebuild with the same name; true in test/prod."
  type        = bool
  default     = false
}

variable "soft_delete_retention_days" {
  type    = number
  default = 7

  validation {
    condition     = var.soft_delete_retention_days >= 7 && var.soft_delete_retention_days <= 90
    error_message = "Must be between 7 and 90."
  }
}

variable "public_network_access_enabled" {
  type    = bool
  default = false
}

variable "allowed_ip_rules" {
  description = "Public IPs allowed through the vault firewall. Only meaningful when public_network_access_enabled = true."
  type        = list(string)
  default     = []
}

variable "private_endpoint_subnet_id" { type = string }

variable "private_dns_zone_ids" {
  type = map(string)

  validation {
    condition     = contains(keys(var.private_dns_zone_ids), "privatelink.vaultcore.azure.net")
    error_message = "private_dns_zone_ids must contain privatelink.vaultcore.azure.net."
  }
}

variable "grant_deployer_secrets_officer" {
  description = "Grant the identity running Terraform the Key Vault Secrets Officer role so it can create var.secrets. Set false if your platform team pre-grants this."
  type        = bool
  default     = true
}

variable "role_assignments" {
  description = <<-EOT
    Managed identities that read secrets at runtime, keyed by a stable label.

    In this template:
      adf     -> Key Vault Secrets User (resolves linked service secrets)
      synapse -> Key Vault Secrets User
  EOT
  type = map(object({
    principal_id   = string
    role           = optional(string, "Key Vault Secrets User")
    principal_type = optional(string, "ServicePrincipal")
    description    = optional(string, "")
  }))
  default = {}
}

variable "secrets" {
  description = "Secrets to seed. Values normally come from random_password resources in the calling module, never from tfvars."
  type = map(object({
    value           = string
    content_type    = optional(string, "text/plain")
    expiration_date = optional(string, null)
    rotation_owner  = optional(string, "data-platform")
  }))
  default   = {}
  sensitive = true
}

variable "log_analytics_workspace_id" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "enable_diagnostics" {
  description = <<-EOT
    Create the diagnostic setting for this resource.

    A BOOLEAN, not a `log_analytics_workspace_id != null` test - `count` must be
    resolvable at PLAN time, and the workspace ID is a resource attribute that
    does not exist until apply. Deriving count from it fails on a fresh state:

        Error: Invalid count argument
        The "count" value depends on resource attributes that cannot be
        determined until apply, so Terraform cannot predict how many instances
        will be created.

    The ID itself may be unknown; only the PREDICATE has to be known.
  EOT
  type        = bool
  default     = true
}
