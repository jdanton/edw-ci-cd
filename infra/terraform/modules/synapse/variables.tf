# ---------------------------------------------------------------------------
# modules/synapse/variables.tf
# ---------------------------------------------------------------------------

variable "name" {
  description = "Synapse workspace name. Globally unique, 3-50 chars, lowercase letters/digits/hyphens, must start with a letter and end alphanumeric. Cannot contain the literal string \"-ondemand\"."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,48}[a-z0-9]$", var.name))
    error_message = "Workspace names are 3-50 chars, lowercase, start with a letter, end alphanumeric."
  }

  validation {
    condition     = !can(regex("-ondemand", var.name))
    error_message = "Workspace names may not contain \"-ondemand\": Azure reserves <ws>-ondemand for the serverless endpoint."
  }
}

variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tenant_id" { type = string }

variable "default_filesystem_id" {
  description = "Resource ID of the ADLS Gen2 filesystem the workspace uses for its own metadata. Use a dedicated filesystem (the template calls it `synapse`), never one of the medallion layers."
  type        = string
}

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

variable "aad_admin_login" {
  description = "Display name of the Entra group that administers the workspace and its SQL endpoints. From bootstrap output synapse_admin_group_names."
  type        = string
}

variable "aad_admin_object_id" {
  description = "Object ID of that group. From bootstrap output synapse_admin_group_ids."
  type        = string
}

variable "entra_only_authentication" {
  description = "Refuse SQL authentication on the serverless endpoint. Recommended: the deployment SP is in the admin group and uses an Entra token, so no password is needed anywhere."
  type        = bool
  default     = true
}

variable "sql_admin_login" {
  description = "SQL admin username, only used when entra_only_authentication = false."
  type        = string
  default     = "synapseadmin"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "public_network_access_enabled" {
  description = "Leave false. When false, azure.synapse.tools and the serverless DDL deployment must run from a VNet-connected runner."
  type        = bool
  default     = false
}

variable "data_exfiltration_protection_enabled" {
  description = <<-EOT
    Restrict managed-VNet outbound traffic to an approved tenant list.

    CREATE-TIME ONLY - changing it replaces the workspace and destroys every
    serverless database, view and external table.

    Turning it on means every outbound destination needs a managed private
    endpoint. In particular, the NYC Taxi ingest reads from the PUBLIC
    azureopendatastorage account, which you cannot create a managed private
    endpoint to. That copy runs in ADF, not Synapse, so this template still
    works - but be aware of the constraint before enabling it.
  EOT
  type        = bool
  default     = false
}

variable "private_endpoint_subnet_id" { type = string }

variable "private_dns_zone_ids" {
  type = map(string)

  validation {
    condition = alltrue([
      contains(keys(var.private_dns_zone_ids), "privatelink.sql.azuresynapse.net"),
      contains(keys(var.private_dns_zone_ids), "privatelink.dev.azuresynapse.net"),
    ])
    error_message = "private_dns_zone_ids must contain privatelink.sql.azuresynapse.net and privatelink.dev.azuresynapse.net."
  }
}

variable "deploy_private_link_hub" {
  description = "Deploy a Synapse Private Link Hub so Studio is reachable from inside the VNet. Costs nothing on its own; the private endpoint costs the usual PE hourly rate."
  type        = bool
  default     = false
}

variable "private_link_hub_name" {
  description = "Private Link Hub name. Alphanumeric only - hyphens are NOT permitted here, unlike the workspace name."
  type        = string
  default     = null

  validation {
    condition     = var.private_link_hub_name == null || can(regex("^[a-zA-Z][a-zA-Z0-9]{2,44}$", coalesce(var.private_link_hub_name, "plhplaceholder")))
    error_message = "Private Link Hub names are alphanumeric only, 3-45 chars, starting with a letter."
  }
}

# ---------------------------------------------------------------------------
# Managed private endpoints (Synapse -> data)
# ---------------------------------------------------------------------------

variable "lake_storage_account_id" {
  description = "ADLS Gen2 account the workspace reads and writes. Managed private endpoints are created for both its dfs and blob sub-resources."
  type        = string
}

variable "key_vault_id" {
  description = "Key Vault the workspace resolves secrets from. Null to skip the managed private endpoint."
  type        = string
  default     = null
}

variable "sql_server_id" {
  description = "Azure SQL logical server. Null to skip. Only needed if Synapse pipelines (rather than ADF) write to the serving database."
  type        = string
  default     = null
}

variable "additional_managed_private_endpoints" {
  description = "Extra managed private endpoints, keyed by name. Merged over the defaults, so you can also override one of them."
  type = map(object({
    target_resource_id = string
    subresource_name   = string
    description        = optional(string, "")
  }))
  default = {}
}

variable "auto_approve_managed_private_endpoints" {
  description = <<-EOT
    Run scripts/Approve-PrivateEndpointConnections.ps1 after creating managed
    private endpoints.

    A managed private endpoint is only half a connection: the TARGET resource
    owner must approve it. When Terraform owns both sides (the normal case
    here) there is nobody else to ask, so we approve programmatically.

    Requires `az` on PATH and an authenticated context - true on your
    self-hosted runner after azure/login. Set false if a security team owns
    approvals, and expect Synapse to fail to read the lake until they act.
  EOT
  type        = bool
  default     = true
}

variable "log_analytics_workspace_id" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
