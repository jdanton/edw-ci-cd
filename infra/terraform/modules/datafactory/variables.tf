# ---------------------------------------------------------------------------
# modules/datafactory/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Data Factory name. Globally unique, 3-63 chars, letters/digits/hyphens, must start and end alphanumeric."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{1,61}[A-Za-z0-9]$", var.name))
    error_message = "Data Factory names are 3-63 chars, alphanumeric and hyphens, starting and ending alphanumeric."
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }

variable "public_network_enabled" {
  description = "ADF data-plane public endpoint. False is the secure default; the ARM control plane stays reachable regardless, so azure.datafactory.tools still works."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Integration runtime
# ---------------------------------------------------------------------------

variable "managed_vnet_ir_name" {
  description = <<-EOT
    Name of the managed-VNet integration runtime.

    Every linked service JSON in src/adf/linkedService/ pins this name in its
    `connectVia` property. Keep it IDENTICAL across environments so the artefact
    JSON needs no per-environment rewrite - that is why it is not suffixed with
    the environment name.
  EOT
  type        = string
  default     = "IR-ManagedVNet"
}

variable "ir_compute_type" {
  description = "General, ComputeOptimized or MemoryOptimized. General is right for copy-heavy workloads; only move if a data flow profile says otherwise."
  type        = string
  default     = "General"

  validation {
    condition     = contains(["General", "ComputeOptimized", "MemoryOptimized"], var.ir_compute_type)
    error_message = "Must be General, ComputeOptimized or MemoryOptimized."
  }
}

variable "ir_core_count" {
  description = "Cores for mapping data flows on this IR. Only billed while a data flow is running. 8 is the minimum."
  type        = number
  default     = 8
}

variable "ir_time_to_live_min" {
  description = <<-EOT
    Minutes the managed-VNet compute stays warm after an activity finishes.

    0  = cold start on every activity (60-90s in a managed VNet). Cheapest, and
         painful on any pipeline with a ForEach.
    10 = the template default. One warm-up per pipeline run.
    60 = for factories running many small pipelines through the day.

    You are billed for the TTL window, so do not set this high in dev.
  EOT
  type        = number
  default     = 10
}

# ---------------------------------------------------------------------------
# Managed private endpoints (ADF -> data)
# ---------------------------------------------------------------------------

variable "lake_storage_account_id" {
  description = "ADLS Gen2 account ID. Managed private endpoints are created for its dfs and blob sub-resources."
  type        = string
}

variable "sql_server_id" {
  description = "Azure SQL logical server ID - the copy sink."
  type        = string
}

variable "synapse_workspace_id" {
  description = "Synapse workspace ID. Null skips the SqlOnDemand/Dev managed private endpoints, which would break PL_Curate_NycTaxi_Yellow."
  type        = string
  default     = null
}

variable "key_vault_id" {
  description = "Key Vault ID for LS_KeyVault. Null to skip."
  type        = string
  default     = null
}

variable "additional_managed_private_endpoints" {
  description = <<-EOT
    Extra managed private endpoints, keyed by name.

    Use `fqdns` for Private Link Service targets and for the handful of
    first-party services that require an explicit FQDN list. Leave it empty for
    normal PaaS targets - ADF derives the FQDN from the resource ID.
  EOT
  type = map(object({
    target_resource_id = string
    subresource_name   = string
    fqdns              = optional(list(string), [])
    description        = optional(string, "")
  }))
  default = {}
}

variable "auto_approve_managed_private_endpoints" {
  description = "Run scripts/Approve-PrivateEndpointConnections.ps1 to approve the pending connections on the target resources. See the equivalent variable in modules/synapse."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Private endpoints on the factory (caller -> ADF)
# ---------------------------------------------------------------------------

variable "deploy_factory_private_endpoints" {
  description = "Create dataFactory and portal private endpoints so ADF Studio works from inside the VNet. Two extra private endpoints of cost; skip in dev if authors use the public Studio."
  type        = bool
  default     = true
}

variable "private_endpoint_subnet_id" { type = string }

variable "private_dns_zone_ids" {
  type    = map(string)
  default = {}
}

# ---------------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------------

variable "github_configuration" {
  description = <<-EOT
    Git integration for the DEV factory only. Null everywhere else.

    Read the long comment in main.tf before setting this. The supported
    workflow is: connect dev to Git once in ADF Studio, confirm it works, then
    describe it here so Terraform adopts the configuration.

    Example:
      github_configuration = {
        account_name    = "your-org"
        repository_name = "edw-ci-cd"
        branch_name     = "main"
        root_folder     = "/src/adf"
        git_url         = "https://github.com"
        publishing_enabled = false   # we publish from CI, not from Studio
      }
  EOT
  type = object({
    account_name       = string
    repository_name    = string
    branch_name        = string
    root_folder        = string
    git_url            = optional(string, "https://github.com")
    publishing_enabled = optional(bool, false)
  })
  default = null
}

variable "log_analytics_workspace_id" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
