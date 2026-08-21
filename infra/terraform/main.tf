# ---------------------------------------------------------------------------
# infra/terraform/main.tf
#
# Composition root. Creates one complete EDW environment:
#
#   Log Analytics -> Network -> Storage -> Key Vault
#                                  |
#                                  +--> Azure SQL
#                                  +--> Synapse (serverless)
#                                  +--> Data Factory
#                                  |
#                          data-plane RBAC (below)
#
# Note that ALL cross-service RBAC lives in this file rather than inside the
# modules. That is not a stylistic choice: putting "grant the ADF identity
# access to the lake" inside modules/storage would make storage depend on
# datafactory, while datafactory already depends on storage for the account ID.
# Terraform resolves dependencies at MODULE granularity, so that is a cycle.
# Hoisting the role assignments to the root breaks it.
# ---------------------------------------------------------------------------

resource "random_string" "suffix" {
  count = var.name_suffix == null ? 1 : 0

  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  suffix = var.name_suffix != null ? var.name_suffix : random_string.suffix[0].result

  # <project>-<env>, e.g. edwtaxi-dev. Used verbatim in non-unique names.
  name_prefix = "${var.project}-${var.environment}"

  resource_group_name = coalesce(
    var.resource_group_name,
    "rg-${var.project}-${var.environment}-${var.location_short}"
  )

  # Globally-unique names. Storage is the tightest constraint at 24 characters
  # of lowercase alphanumerics, which is why `project` is capped at 8.
  storage_account_name = substr("st${var.project}${var.environment}${local.suffix}", 0, 24)
  key_vault_name       = substr("kv-${var.project}-${var.environment}-${local.suffix}", 0, 24)
  synapse_name         = "syn-${var.project}-${var.environment}-${local.suffix}"
  sql_server_name      = "sql-${var.project}-${var.environment}-${local.suffix}"
  data_factory_name    = "adf-${var.project}-${var.environment}-${local.suffix}"
  log_analytics_name   = "log-${var.project}-${var.environment}-${var.location_short}"

  # Private Link Hub names reject hyphens, unlike every other Synapse name.
  private_link_hub_name = substr("plh${var.project}${var.environment}${local.suffix}", 0, 45)

  common_tags = merge(
    {
      environment = var.environment
      project     = var.project
      workload    = "edw-platform"
      managed-by  = "terraform"
      repository  = "edw-ci-cd"
    },
    var.tags,
  )

  # -------------------------------------------------------------------------
  # The medallion layout.
  #
  # Paths matter: they are hard-coded in the ADF datasets, in the Synapse
  # external data sources, and in the curated CETAS output locations. Changing
  # one here means changing it in src/adf/dataset/*.json and
  # src/synapse/serverless/*.sql too. docs/10-making-a-change.md walks through
  # exactly that scenario.
  # -------------------------------------------------------------------------
  filesystems = {
    raw = {
      description = "Immutable landing zone. Source-format files exactly as received, partitioned by source system and business date. Written only by ADF; never edited."
      # LEAF paths only. ADLS creates parent directories implicitly, so
      # declaring "nyctlc" as well as "nyctlc/yellow" is a race: whichever
      # runs first creates both, and the other fails with
      #   a resource with the ID ".../raw/nyctlc" already exists
      directories = [
        "nyctlc/yellow",
        "nyctlc/green",
        "nyctlc/reference",
        "_quarantine",
      ]
    }
    curated = {
      description = "Conformed, typed, deduplicated Parquet produced by Synapse serverless CETAS. The contract between the lake and the warehouse."
      # Leaf paths only - see the note on the raw filesystem.
      directories = [
        "nyctlc/yellow_trip",
        "nyctlc/taxi_zone",
      ]
    }
    sandbox = {
      description = "Analyst scratch space. Not backed up. Lifecycle-deleted after 30 days."
      directories = []
    }
    synapse = {
      description = "Synapse workspace system filesystem. Workspace metadata only - do not put data here."
      directories = []
    }
    logs = {
      description = "Diagnostic and audit sink: Azure SQL extended auditing, exported pipeline telemetry."
      directories = ["sqlaudit"]
    }
  }
}

# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "this" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.common_tags
}

# ---------------------------------------------------------------------------
# Observability first - every other module wants the workspace ID.
# ---------------------------------------------------------------------------

module "monitoring" {
  source = "./modules/monitoring"

  name                = local.log_analytics_name
  name_prefix         = local.name_prefix
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  retention_in_days = var.log_retention_in_days
  daily_quota_gb    = var.log_daily_quota_gb

  alert_email_receivers   = var.alert_email_receivers
  alert_webhook_receivers = var.alert_webhook_receivers

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Alerts - separate module because the rules need resource IDs for ADF,
# Synapse and SQL, all of which need the workspace ID above. One module would
# be a cycle; two is a straight line.
# ---------------------------------------------------------------------------

module "alerts" {
  source = "./modules/alerts"

  name_prefix         = local.name_prefix
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  environment         = var.environment

  log_analytics_workspace_id = module.monitoring.workspace_id
  action_group_id            = module.monitoring.action_group_id

  data_factory_id      = module.datafactory.id
  synapse_workspace_id = module.synapse.id
  sql_database_id      = module.sql.database_id

  pipeline_sla_minutes                   = var.pipeline_sla_minutes
  serverless_data_processed_gb_threshold = var.serverless_data_processed_gb_threshold

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Network - VNet, private DNS, and the peering to your runner VNet
# ---------------------------------------------------------------------------

module "network" {
  source = "./modules/network"

  name_prefix         = local.name_prefix
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  address_space                   = var.vnet_address_space
  subnet_private_endpoints_prefix = var.subnet_private_endpoints_prefix
  subnet_bastion_prefix           = var.subnet_bastion_prefix
  deploy_bastion                  = var.deploy_bastion

  runner_vnet_id                  = var.runner_vnet_id
  peer_runner_vnet                = var.peer_runner_vnet
  link_private_dns_to_runner_vnet = var.link_private_dns_to_runner_vnet
  additional_dns_link_vnet_ids    = var.additional_dns_link_vnet_ids

  create_private_dns_zones      = var.create_private_dns_zones
  existing_private_dns_zone_ids = var.existing_private_dns_zone_ids

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Lake
# ---------------------------------------------------------------------------

module "storage" {
  source = "./modules/storage"

  name                = local.storage_account_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  environment         = var.environment

  replication_type = var.storage_replication_type
  filesystems      = local.filesystems

  create_data_lake_directories = var.create_data_lake_directories

  # true + deny-all, not false. See the note on the module variable: false
  # disables the rule set entirely and blocks Synapse workspace creation.
  public_network_access_enabled = true

  private_endpoint_subnet_id = module.network.private_endpoint_subnet_id
  private_dns_zone_ids       = module.network.private_dns_zone_ids

  # Empty on purpose - see the header comment. Assignments live in rbac.tf.
  data_plane_role_assignments = {}

  lifecycle_rules_enabled = var.storage_lifecycle_enabled
  raw_cool_after_days     = var.raw_cool_after_days
  raw_archive_after_days  = var.raw_archive_after_days

  log_analytics_workspace_id = module.monitoring.workspace_id

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Key Vault
# ---------------------------------------------------------------------------

module "keyvault" {
  source = "./modules/keyvault"

  name                = local.key_vault_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tenant_id           = var.tenant_id

  purge_protection_enabled   = var.key_vault_purge_protection_enabled
  soft_delete_retention_days = var.environment == "prod" ? 90 : 7

  public_network_access_enabled = false
  private_endpoint_subnet_id    = module.network.private_endpoint_subnet_id
  private_dns_zone_ids          = module.network.private_dns_zone_ids

  # Assignments live in rbac.tf for the cycle-avoidance reason above, and the
  # deployer's Secrets Officer grant lives in secrets.tf alongside the secrets
  # it exists to write - so the module must not create a second, conflicting
  # assignment for the same principal.
  grant_deployer_secrets_officer = false
  role_assignments               = {}

  # Seeded in secrets.tf once the SQL and Synapse modules have produced values.
  secrets = {}

  log_analytics_workspace_id = module.monitoring.workspace_id

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Azure SQL - the serving layer
# ---------------------------------------------------------------------------

module "sql" {
  source = "./modules/sql"

  server_name         = local.sql_server_name
  database_name       = var.sql_database_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  environment         = var.environment
  tenant_id           = var.tenant_id
  subscription_id     = var.subscription_id

  aad_admin_login           = var.sql_aad_admin_login
  aad_admin_object_id       = var.sql_aad_admin_object_id
  entra_only_authentication = var.sql_entra_only_authentication

  sku_name                    = var.sql_sku_name
  max_size_gb                 = var.sql_max_size_gb
  auto_pause_delay_in_minutes = var.sql_auto_pause_delay_in_minutes
  min_capacity                = var.sql_min_capacity
  zone_redundant              = var.sql_zone_redundant
  pitr_retention_days         = var.sql_pitr_retention_days

  public_network_access_enabled = false
  private_endpoint_subnet_id    = module.network.private_endpoint_subnet_id
  private_dns_zone_ids          = module.network.private_dns_zone_ids

  # Auditing is defined at the root (rbac.tf) so it can be ordered after the
  # role assignment it depends on. See the comment there.
  enable_auditing         = false
  audit_storage_endpoint  = module.storage.blob_endpoint
  enable_threat_detection = var.sql_enable_threat_detection
  security_alert_emails   = var.sql_security_alert_emails

  log_analytics_workspace_id = module.monitoring.workspace_id

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Synapse - serverless SQL over the lake
# ---------------------------------------------------------------------------

module "synapse" {
  source = "./modules/synapse"

  name                = local.synapse_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  tenant_id           = var.tenant_id

  default_filesystem_id = module.storage.filesystem_ids["synapse"]

  aad_admin_login           = var.synapse_aad_admin_login
  aad_admin_object_id       = var.synapse_aad_admin_object_id
  entra_only_authentication = true

  public_network_access_enabled        = false
  data_exfiltration_protection_enabled = var.synapse_data_exfiltration_protection_enabled

  private_endpoint_subnet_id = module.network.private_endpoint_subnet_id
  private_dns_zone_ids       = module.network.private_dns_zone_ids

  deploy_private_link_hub = var.synapse_deploy_private_link_hub
  private_link_hub_name   = local.private_link_hub_name

  lake_storage_account_id = module.storage.id
  key_vault_id            = module.keyvault.id
  sql_server_id           = module.sql.server_id

  auto_approve_managed_private_endpoints = var.auto_approve_managed_private_endpoints

  log_analytics_workspace_id = module.monitoring.workspace_id

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Data Factory - orchestration
# ---------------------------------------------------------------------------

module "datafactory" {
  source = "./modules/datafactory"

  name                = local.data_factory_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location

  public_network_enabled = false

  managed_vnet_ir_name = "IR-ManagedVNet"
  ir_core_count        = var.adf_ir_core_count
  ir_time_to_live_min  = var.adf_ir_time_to_live_min

  lake_storage_account_id = module.storage.id
  sql_server_id           = module.sql.server_id
  synapse_workspace_id    = module.synapse.id
  key_vault_id            = module.keyvault.id

  auto_approve_managed_private_endpoints = var.auto_approve_managed_private_endpoints

  deploy_factory_private_endpoints = var.adf_deploy_factory_private_endpoints
  private_endpoint_subnet_id       = module.network.private_endpoint_subnet_id
  private_dns_zone_ids             = module.network.private_dns_zone_ids

  github_configuration = var.adf_github_configuration

  log_analytics_workspace_id = module.monitoring.workspace_id

  tags = local.common_tags
}
