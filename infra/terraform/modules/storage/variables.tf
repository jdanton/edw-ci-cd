# ---------------------------------------------------------------------------
# modules/storage/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Storage account name. Must be globally unique, 3-24 chars, lowercase alphanumeric only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.name))
    error_message = "Storage account names are 3-24 characters, lowercase letters and digits only."
  }
}

variable "resource_group_name" {
  type        = string
  description = "Resource group for the storage account and its private endpoints."
}

variable "location" {
  type        = string
  description = "Azure region."
}

variable "environment" {
  type        = string
  description = "Environment name (dev/test/prod). Drives the retention and replication defaults."
}

variable "replication_type" {
  description = "LRS is fine for dev. Use ZRS or GZRS for prod: a lake is expensive to re-hydrate."
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "GZRS", "RAGRS", "RAGZRS"], var.replication_type)
    error_message = "Invalid replication type."
  }
}

variable "account_tier" {
  type    = string
  default = "Standard"
}

variable "filesystems" {
  description = <<-EOT
    ADLS Gen2 filesystems (containers) to create, keyed by name.

    The template's medallion layout:
      raw      - byte-for-byte landing zone. Immutable. Partitioned by source
                 and ingest date. Nothing but ADF writes here.
      curated  - conformed, typed, deduplicated Parquet written by Synapse
                 serverless CETAS. This is what ADF loads into Azure SQL.
      sandbox  - analyst scratch space. Not backed up, lifecycle-deleted.
      synapse  - the Synapse workspace's mandatory default filesystem. Holds
                 workspace-managed artifacts, NOT your data.
      logs     - diagnostic/audit sink (SQL auditing, ADF activity logs).
  EOT
  type = map(object({
    description = string
    # Directories pre-created inside the filesystem so that ADF's first write
    # lands in an intentional structure rather than inventing one.
    directories = optional(list(string), [])
  }))
}

variable "create_data_lake_directories" {
  description = <<-EOT
    Pre-create the directory skeleton listed in `filesystems[*].directories`.

    IMPORTANT: filesystem and directory creation are DATA-PLANE operations. With
    public_network_access_enabled = false they only succeed from a host that can
    reach the private endpoint and resolve privatelink.dfs.core.windows.net -
    i.e. your self-hosted runner. Terraform depends_on ordering forces the
    private endpoints to exist first, but if you run `terraform apply` from a
    laptop outside the VNet these resources will fail with a 403 AuthorizationFailure
    or a connection timeout. That is expected. See docs/12-troubleshooting.md.
  EOT
  type        = bool
  default     = true
}

variable "public_network_access_enabled" {
  description = "Leave false. Set true only for a short-lived break-glass window, and revert."
  type        = bool
  default     = false
}

variable "private_endpoint_subnet_id" {
  type        = string
  description = "Subnet to place the blob and dfs private endpoints in."
}

variable "private_dns_zone_ids" {
  description = "Map of zone name -> ID from the network module. Must contain privatelink.blob.core.windows.net and privatelink.dfs.core.windows.net."
  type        = map(string)

  validation {
    condition = alltrue([
      contains(keys(var.private_dns_zone_ids), "privatelink.blob.core.windows.net"),
      contains(keys(var.private_dns_zone_ids), "privatelink.dfs.core.windows.net"),
    ])
    error_message = "private_dns_zone_ids must contain both privatelink.blob.core.windows.net and privatelink.dfs.core.windows.net."
  }
}

variable "data_plane_role_assignments" {
  description = <<-EOT
    Managed identities that need data-plane access to the lake, keyed by a
    stable label (the key becomes part of nothing, but changing it re-creates
    the assignment, so keep it stable).

    In this template:
      adf     -> Storage Blob Data Contributor  (writes raw, reads curated)
      synapse -> Storage Blob Data Contributor  (reads raw, writes curated via CETAS)

    Note that "Contributor" at the ARM level does NOT grant data-plane access to
    blobs. That surprise is the single most common ADLS permissions bug.
  EOT
  type = map(object({
    principal_id   = string
    role           = string
    principal_type = optional(string, "ServicePrincipal")
    description    = optional(string, "")
    # Restrict to a single filesystem instead of the whole account.
    filesystem = optional(string, null)
  }))
  default = {}
}

variable "lifecycle_rules_enabled" {
  description = "Apply the tiering/expiry management policy. Turn off if your organisation manages lifecycle centrally."
  type        = bool
  default     = true
}

variable "raw_cool_after_days" {
  description = "Move raw-zone blobs to Cool after this many days since last modification. Raw is written once and read rarely after the curated build."
  type        = number
  default     = 30
}

variable "raw_archive_after_days" {
  description = "Move raw-zone blobs to Archive. Archive rehydration takes hours - only sensible once you trust the curated layer."
  type        = number
  default     = 180
}

variable "sandbox_delete_after_days" {
  description = "Hard-delete anything left in the sandbox filesystem after this many days."
  type        = number
  default     = 30
}

variable "blob_soft_delete_days" {
  type    = number
  default = 14
}

variable "log_analytics_workspace_id" {
  description = "Send storage diagnostics here. Null disables diagnostic settings."
  type        = string
  default     = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
