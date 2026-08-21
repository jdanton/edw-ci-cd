# ---------------------------------------------------------------------------
# modules/sql/variables.tf
# ---------------------------------------------------------------------------

variable "server_name" {
  description = "Logical SQL server name. Globally unique, lowercase, 1-63 chars."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.server_name))
    error_message = "Server names must be lowercase alphanumeric or hyphen, and cannot start or end with a hyphen."
  }
}

variable "database_name" {
  description = "Database name. Must match the <Name> in src/sql/EdwTaxi.Database/EdwTaxi.Database.sqlproj publish profiles."
  type        = string
  default     = "edw"
}

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "environment" { type = string }
variable "tenant_id" { type = string }
variable "subscription_id" { type = string }

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

variable "aad_admin_login" {
  description = "Display name of the Entra group that administers this server. Comes from bootstrap output sql_admin_group_names."
  type        = string
}

variable "aad_admin_object_id" {
  description = "Object ID of that same group. Comes from bootstrap output sql_admin_group_ids."
  type        = string
}

variable "entra_only_authentication" {
  description = <<-EOT
    Refuse SQL authentication entirely.

    true  - only Entra tokens are accepted. sqlpackage authenticates with
            /AccessToken. No password exists. Recommended.
    false - a random SQL admin password is generated and stored in Key Vault.
            Use only when a legacy consumer cannot do Entra.
  EOT
  type        = bool
  default     = true
}

variable "sql_admin_login" {
  description = "SQL admin username, used only when entra_only_authentication = false."
  type        = string
  default     = "edwsqladmin"
}

# ---------------------------------------------------------------------------
# Sizing
# ---------------------------------------------------------------------------

variable "sku_name" {
  description = <<-EOT
    Service objective.

    Template defaults:
      dev  GP_S_Gen5_2   serverless, auto-pauses, ~USD 5-70/mo depending on use
      test GP_S_Gen5_2   serverless
      prod GP_Gen5_4     provisioned - no cold-start on the first morning query

    Clustered columnstore on fact.YellowTaxiTrip needs at least 2 vCore; below
    that SQL silently falls back to rowstore-ish behaviour and the merge is slow.
  EOT
  type        = string
  default     = "GP_S_Gen5_2"
}

variable "max_size_gb" {
  type    = number
  default = 32
}

variable "auto_pause_delay_in_minutes" {
  description = "Serverless auto-pause. -1 disables pausing. Only valid on GP_S_* SKUs; must be null for provisioned SKUs."
  type        = number
  default     = 60
}

variable "min_capacity" {
  description = "Serverless minimum vCores. Must be null for provisioned SKUs."
  type        = number
  default     = 0.5
}

variable "zone_redundant" {
  type    = bool
  default = false
}

variable "pitr_retention_days" {
  description = "Point-in-time restore window, 1-35 days."
  type        = number
  default     = 7
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "public_network_access_enabled" {
  description = "Leave false. When false, ALL access - including sqlpackage from CI - must come through the private endpoint."
  type        = bool
  default     = false
}

variable "private_endpoint_subnet_id" { type = string }

variable "private_dns_zone_ids" {
  type = map(string)

  validation {
    condition     = contains(keys(var.private_dns_zone_ids), "privatelink.database.windows.net")
    error_message = "private_dns_zone_ids must contain privatelink.database.windows.net."
  }
}

# ---------------------------------------------------------------------------
# Security / observability
# ---------------------------------------------------------------------------

variable "audit_storage_endpoint" {
  description = "Blob endpoint for the audit log destination, e.g. https://stedwtaxidev.blob.core.windows.net/. Null disables auditing."
  type        = string
  default     = null
}

variable "audit_retention_days" {
  type    = number
  default = 90
}

variable "enable_threat_detection" {
  description = "Microsoft Defender for SQL alerting. Adds cost per server; on in prod."
  type        = bool
  default     = false
}

variable "security_alert_emails" {
  type    = list(string)
  default = []
}

variable "log_analytics_workspace_id" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "enable_auditing" {
  description = "Enable extended auditing to audit_storage_endpoint. Boolean rather than an is-the-endpoint-null test, for the plan-time reason in enable_diagnostics."
  type        = bool
  default     = true
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
