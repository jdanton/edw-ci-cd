# ---------------------------------------------------------------------------
# infra/terraform/rbac.tf
#
# All cross-service data-plane authorisation, in one place.
#
# Why here and not inside the modules: modules/storage would have to depend on
# modules/datafactory for the ADF principal ID, while modules/datafactory
# already depends on modules/storage for the account ID. Terraform resolves
# dependencies per-module, so that is a cycle. Root-level assignments break it
# and, as a bonus, give you a single file to review when someone asks "what can
# touch the lake?".
#
# ---------------------------------------------------------------------------
# THE THREE-LAYER PERMISSION MODEL - the thing that trips everyone up
# ---------------------------------------------------------------------------
# Getting ADF to read a Parquet file out of ADLS and write a row into Azure SQL
# requires grants at three independent layers. Missing any one produces an error
# that points at the wrong layer.
#
#   Layer 1  Azure RBAC (this file)
#            "Storage Blob Data Contributor" on the account.
#            NOTE: ARM "Contributor" does NOT imply blob data access.
#
#   Layer 2  Network (modules/*, private endpoints)
#            A managed private endpoint out of the ADF managed VNet, APPROVED
#            on the target side.
#
#   Layer 3  Database principals (NOT Terraform)
#            A contained user inside Azure SQL and inside the Synapse
#            serverless database. Created by:
#              src/sql/Scripts/PostDeploy/030_ServicePrincipals.sql
#              src/synapse/serverless/090_permissions.sql
#            Azure RBAC has no visibility into SQL's own permission system.
#
# docs/12-troubleshooting.md maps common error messages back to the layer that
# actually caused them.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Layer 1a: the lake
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "adf_lake_contributor" {
  scope                            = module.storage.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = module.datafactory.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true

  description = "ADF writes raw/ during ingest and reads curated/ when loading Azure SQL."
}

resource "azurerm_role_assignment" "synapse_lake_contributor" {
  scope                            = module.storage.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = module.synapse.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true

  # Contributor, not Reader: CETAS in modules/synapse writes the curated layer.
  # With Reader you get "External table is not accessible because content of
  # directory cannot be listed" on the CREATE EXTERNAL TABLE, which reads like
  # a path bug and is not.
  description = "Synapse serverless reads raw/ via OPENROWSET and writes curated/ via CETAS."
}

# The SQL server's managed identity writes extended audit logs to logs/.
resource "azurerm_role_assignment" "sql_audit_logs" {
  # ACCOUNT scope, not the logs container.
  #
  # Container scope looks tighter and does not work: SQL auditing creates and
  # manages its OWN container (sqldbauditlogs) and enumerates the account to do
  # it. With a container-scoped grant, enabling the policy fails with
  #
  #   BlobAuditingInsufficientStorageAccountPermissions: Insufficient read or
  #   write permissions on storage account '...'. Add permissions to the server
  #   Identity to the storage account.
  #
  # which names the account, not the container, precisely because that is the
  # scope it needs.
  scope                            = module.storage.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = module.sql.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true

  description = "Azure SQL extended auditing. Needs account scope: the service creates its own sqldbauditlogs container."
}

# Role assignments take a couple of minutes to reach the storage data plane, and
# the auditing policy calls that data plane the instant it is created.
resource "time_sleep" "wait_for_sql_audit_rbac" {
  depends_on      = [azurerm_role_assignment.sql_audit_logs]
  create_duration = "60s"
}

# ---------------------------------------------------------------------------
# Extended auditing lives HERE, not in modules/sql, and it has to.
#
# The policy depends on the role assignment above; the role assignment depends
# on module.sql.principal_id. Putting the policy inside modules/sql would make
# the module depend on a resource that depends on the module - a cycle, because
# Terraform resolves dependencies at MODULE granularity.
#
# Same reason all the other cross-service RBAC is at the root. See the header.
# ---------------------------------------------------------------------------
resource "azurerm_mssql_server_extended_auditing_policy" "sql" {
  count = var.sql_enable_auditing ? 1 : 0

  server_id                       = module.sql.server_id
  storage_endpoint                = module.storage.blob_endpoint
  storage_account_subscription_id = var.subscription_id
  retention_in_days               = var.sql_audit_retention_days
  log_monitoring_enabled          = true

  # No storage_account_access_key: the server's managed identity is used, which
  # is the only option available anyway - the lake has shared_access_key_enabled
  # = false.

  depends_on = [time_sleep.wait_for_sql_audit_rbac]
}

# ---------------------------------------------------------------------------
# Layer 1b: Key Vault
#
# ADF and Synapse linked services resolve secrets at pipeline runtime through
# their managed identities. "Key Vault Secrets User" grants get only - they
# cannot enumerate, set or delete.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "adf_keyvault_secrets" {
  scope                            = module.keyvault.id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = module.datafactory.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true

  description = "LS_KeyVault resolves linked-service secrets at runtime."
}

resource "azurerm_role_assignment" "synapse_keyvault_secrets" {
  scope                            = module.keyvault.id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = module.synapse.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true

  description = "Synapse linked services resolve secrets at runtime."
}

# ---------------------------------------------------------------------------
# Layer 1c: analyst read access to the lake
#
# The Synapse admin group gets Storage Blob Data Reader so that humans running
# ad-hoc OPENROWSET queries in Synapse Studio succeed. Serverless passes the
# CALLER's identity through when the external data source has no credential -
# so without this, the query works for the pipeline (workspace MI) and fails
# for the human, which is a genuinely confusing support ticket.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "synapse_admins_lake_reader" {
  scope                = module.storage.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = var.synapse_aad_admin_object_id
  principal_type       = "Group"

  description = "Interactive Synapse Studio users running ad-hoc OPENROWSET against the lake."
}

# ---------------------------------------------------------------------------
# Layer 1d: ADF -> Synapse
#
# ADF's Script activity against the serverless endpoint authenticates with the
# factory's managed identity. The workspace-level Synapse RBAC role is what
# lets that identity connect at all; the SQL-level grant that lets it EXECUTE
# the CETAS procedures is layer 3 (src/synapse/serverless/090_permissions.sql).
# ---------------------------------------------------------------------------

resource "azurerm_synapse_role_assignment" "adf_synapse_user" {
  synapse_workspace_id = module.synapse.id
  role_name            = "Synapse User"
  principal_id         = module.datafactory.principal_id

  depends_on = [
    module.synapse,
    module.datafactory,
  ]
}

# ---------------------------------------------------------------------------
# Layer 1e: let the deployment identity read what it needs at deploy time
#
# The GitHub Actions SP already holds Contributor from bootstrap. It also needs
# blob DATA access so that:
#   * `terraform apply` can create the filesystems and directories
#   * scripts can upload the NYC taxi zone reference CSV
#
# Contributor does not cover that, for the reason in the header.
# ---------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

locals {
  # Pinned per environment, falling back to the caller. See the long note on
  # var.deployer_principal_id for why the fallback alone is not enough.
  deployer_principal_id = coalesce(var.deployer_principal_id, data.azurerm_client_config.current.object_id)
}

resource "azurerm_role_assignment" "deployer_lake_contributor" {
  scope                            = module.storage.id
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = local.deployer_principal_id
  skip_service_principal_aad_check = true

  description = "Terraform / CI deployment identity - creates filesystems, directories and seeds reference data."
}
