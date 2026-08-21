# ---------------------------------------------------------------------------
# infra/terraform/variables.tf
#
# Every variable here is set from envs/<env>/<env>.tfvars. Values that come out
# of the bootstrap layer are marked "from bootstrap"; regenerate them with
#   cd bootstrap && terraform output -raw 'tfvars_fragments["dev"]'
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Identity and subscription
# ---------------------------------------------------------------------------

variable "subscription_id" {
  description = "Target subscription. From bootstrap."
  type        = string
}

variable "tenant_id" {
  description = "Entra tenant. From bootstrap."
  type        = string
}

variable "use_oidc" {
  description = "Authenticate the azurerm provider with a federated OIDC token. True in GitHub Actions; leave true - the provider falls back to Azure CLI credentials automatically when no OIDC token is present."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Naming and placement
# ---------------------------------------------------------------------------

variable "project" {
  description = "Short project token. Must match the value used in bootstrap so that names line up."
  type        = string
  default     = "edwtaxi"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,7}$", var.project))
    error_message = "project must be 3-8 lowercase alphanumeric characters starting with a letter."
  }
}

variable "environment" {
  description = "Environment name. Must be exactly one of dev/test/prod - it is used as the GitHub Environment name, the state key, and the -Stage argument for the Azure-Player deployment tools."
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be dev, test or prod."
  }
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus2"
}

variable "location_short" {
  description = "Abbreviation used in resource names, e.g. eus2 for East US 2. Kept separate from `location` because Azure has no canonical short form and every organisation picks its own."
  type        = string
  default     = "eus2"
}

variable "resource_group_name" {
  description = "Override the resource group name. Null derives it as rg-<project>-<environment>-<location_short>."
  type        = string
  default     = null
}

variable "name_suffix" {
  description = <<-EOT
    Optional fixed suffix for globally-unique names (storage, Key Vault,
    Synapse, SQL server).

    Leave null and Terraform generates a random 4-character suffix and keeps it
    in state. Set it explicitly if you need names to be reproducible across a
    state rebuild, or if your naming standard mandates a specific token.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.name_suffix == null || can(regex("^[a-z0-9]{2,6}$", coalesce(var.name_suffix, "ab12")))
    error_message = "name_suffix must be 2-6 lowercase alphanumeric characters."
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vnet_address_space" {
  description = "Address space for the EDW spoke VNet. Must not overlap the runner VNet, or peering fails."
  type        = list(string)
  default     = ["10.60.0.0/24"]
}

variable "subnet_private_endpoints_prefix" {
  description = "CIDR for the private endpoint subnet."
  type        = string
  default     = "10.60.0.0/26"
}

variable "subnet_bastion_prefix" {
  description = "CIDR for AzureBastionSubnet. Must be /26 or larger."
  type        = string
  default     = "10.60.0.64/26"
}

variable "deploy_bastion" {
  description = "Deploy Azure Bastion for break-glass access into the private data plane."
  type        = bool
  default     = false
}

variable "runner_vnet_id" {
  description = <<-EOT
    Resource ID of the VNet hosting your self-hosted GitHub Actions runners.

    THIS IS EFFECTIVELY MANDATORY for this template. Every data-plane endpoint
    has public access disabled, so a GitHub-hosted runner cannot:
      * create the ADLS filesystems (Terraform, dfs data plane)
      * publish Synapse artifacts (azure.synapse.tools -> dev.azuresynapse.net)
      * run the serverless DDL (-ondemand.sql.azuresynapse.net, TDS)
      * publish the DACPAC (sqlpackage -> database.windows.net, TDS)

    Set to null only if the runners already live inside `vnet_address_space`
    (in which case pass their subnet via `runner_subnet_id`) or if a network
    team owns peering and DNS out of band.
  EOT
  type        = string
  default     = null
}

variable "peer_runner_vnet" {
  description = "Create bidirectional peering between the EDW VNet and the runner VNet. Requires Network Contributor on BOTH. Set false if the peering already exists in a hub/spoke topology."
  type        = bool
  default     = true
}

variable "link_private_dns_to_runner_vnet" {
  description = "Link every privatelink.* zone to the runner VNet. Set false only if the runner VNet uses custom DNS or a DNS Private Resolver that already forwards these zones."
  type        = bool
  default     = true
}

variable "additional_dns_link_vnet_ids" {
  description = "Extra VNets to link the private DNS zones to - jumpbox VNets, hub VNets carrying ExpressRoute traffic, and so on."
  type        = list(string)
  default     = []
}

variable "create_private_dns_zones" {
  description = "Create the privatelink zones here. Set false where a central connectivity subscription owns them."
  type        = bool
  default     = true
}

variable "existing_private_dns_zone_ids" {
  description = "Map of zone name -> ID when create_private_dns_zones = false."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Data platform administrators (from bootstrap)
# ---------------------------------------------------------------------------

variable "sql_aad_admin_login" {
  description = "Display name of the Entra group administering Azure SQL. From bootstrap output sql_admin_group_names."
  type        = string
}

variable "sql_aad_admin_object_id" {
  description = "Object ID of that group. From bootstrap output sql_admin_group_ids."
  type        = string
}

variable "synapse_aad_admin_login" {
  description = "Display name of the Entra group administering Synapse. From bootstrap output synapse_admin_group_names."
  type        = string
}

variable "synapse_aad_admin_object_id" {
  description = "Object ID of that group. From bootstrap output synapse_admin_group_ids."
  type        = string
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

variable "storage_replication_type" {
  type    = string
  default = "LRS"
}

variable "storage_lifecycle_enabled" {
  type    = bool
  default = true
}

variable "raw_cool_after_days" {
  type    = number
  default = 30
}

variable "raw_archive_after_days" {
  type    = number
  default = 180
}

variable "create_data_lake_directories" {
  description = "Pre-create the medallion directory skeleton. Requires data-plane access from wherever Terraform runs - i.e. your VNet-attached runner."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Key Vault
# ---------------------------------------------------------------------------

variable "key_vault_purge_protection_enabled" {
  description = "Off in dev so the environment can be destroyed and rebuilt with the same vault name. On in test/prod."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Data Factory
# ---------------------------------------------------------------------------

variable "adf_ir_time_to_live_min" {
  description = "Managed VNet IR warm-pool TTL in minutes. You pay for the window; 10 in dev, 20-30 in prod where pipelines chain."
  type        = number
  default     = 10
}

variable "adf_ir_core_count" {
  type    = number
  default = 8
}

variable "adf_deploy_factory_private_endpoints" {
  description = "Private endpoints for the ADF runtime and Studio. Two endpoints of cost per environment."
  type        = bool
  default     = true
}

variable "adf_github_configuration" {
  description = "Git integration for the DEV factory only. See modules/datafactory/variables.tf for the shape and the strong recommendation to leave it null."
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

# ---------------------------------------------------------------------------
# Synapse
# ---------------------------------------------------------------------------

variable "synapse_data_exfiltration_protection_enabled" {
  description = "CREATE-TIME ONLY. Changing this replaces the workspace and destroys every serverless database, view and external table."
  type        = bool
  default     = false
}

variable "synapse_deploy_private_link_hub" {
  description = "Deploy a Private Link Hub so Synapse Studio is usable from inside the VNet."
  type        = bool
  default     = false
}

variable "auto_approve_managed_private_endpoints" {
  description = "Let Terraform approve the private endpoint connections that ADF and Synapse raise against the lake, Key Vault and Azure SQL. Requires `az` and `pwsh` on the runner."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Azure SQL
# ---------------------------------------------------------------------------

variable "sql_database_name" {
  description = "Serving database name. Must match the publish profiles in src/sql/EdwTaxi.Database/Properties/."
  type        = string
  default     = "edw"
}

variable "sql_sku_name" {
  type    = string
  default = "GP_S_Gen5_2"
}

variable "sql_max_size_gb" {
  type    = number
  default = 32
}

variable "sql_auto_pause_delay_in_minutes" {
  description = "Serverless auto-pause delay. Set to null for provisioned SKUs, -1 to never pause."
  type        = number
  default     = 60
}

variable "sql_min_capacity" {
  description = "Serverless minimum vCores. Must be null for provisioned SKUs."
  type        = number
  default     = 0.5
}

variable "sql_zone_redundant" {
  type    = bool
  default = false
}

variable "sql_pitr_retention_days" {
  type    = number
  default = 7
}

variable "sql_entra_only_authentication" {
  description = "Refuse SQL authentication. Recommended - the deployment SP is a member of the admin group and uses an Entra token."
  type        = bool
  default     = true
}

variable "sql_enable_threat_detection" {
  type    = bool
  default = false
}

variable "sql_security_alert_emails" {
  type    = list(string)
  default = []
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

variable "log_retention_in_days" {
  type    = number
  default = 30
}

variable "log_daily_quota_gb" {
  type    = number
  default = 5
}

variable "alert_email_receivers" {
  description = "Map of short receiver name -> email address."
  type        = map(string)
  default     = {}
}

variable "alert_webhook_receivers" {
  description = "Map of short receiver name -> webhook URI (Teams, Slack, PagerDuty)."
  type        = map(string)
  default     = {}
}

variable "pipeline_sla_minutes" {
  type    = number
  default = 120
}

variable "serverless_data_processed_gb_threshold" {
  type    = number
  default = 100
}

# ---------------------------------------------------------------------------
# Tagging
# ---------------------------------------------------------------------------

variable "tags" {
  description = "Tags merged onto every resource. The module adds environment, project and managed-by automatically."
  type        = map(string)
  default     = {}
}

variable "sql_enable_auditing" {
  description = "Enable Azure SQL extended auditing to the lake's logs. The policy is defined in rbac.tf, not modules/sql, because it must be ordered after the role assignment that grants the server identity blob access."
  type        = bool
  default     = true
}

variable "sql_audit_retention_days" {
  description = "Retention for extended audit logs."
  type        = number
  default     = 90
}

variable "deployer_principal_id" {
  description = <<-EOT
    Object ID of the identity that runs Terraform, used for the grants it needs
    on its own resources (blob data on the lake, secrets in Key Vault).

    Set this to the environment's deployment service principal - bootstrap
    output `deploy_principal_ids`. Leave null and it falls back to whoever is
    running, via data.azurerm_client_config.

    WHY IT IS A VARIABLE. With the fallback alone, the grants follow the CALLER:
    plan from a laptop and Terraform proposes replacing them with your user
    object ID, and an apply from a laptop would revoke the deployment
    identity's access - breaking CI until the next pipeline run put it back.
    Pinning it makes the assignment a property of the ENVIRONMENT rather than
    of whoever last ran the tool.

    A human who also needs this access should get it through the admin groups,
    not by applying Terraform as themselves.
  EOT
  type        = string
  default     = null
}
