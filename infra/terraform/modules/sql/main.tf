# ---------------------------------------------------------------------------
# modules/sql/main.tf
#
# Azure SQL Database - the serving layer. This is where the star schema lives
# and what Power BI / SSRS / applications actually query.
#
# Deployment model: SDK-style .sqlproj (Microsoft.Build.Sql) compiled to a
# DACPAC and published with sqlpackage. See src/sql/ and docs/08-azure-sql.md.
#
# The authentication story is the part that matters for CI/CD:
#
#   * The server's Entra administrator is a GROUP (created in bootstrap/).
#   * The GitHub Actions deployment service principal is a MEMBER of that group.
#   * Therefore sqlpackage, running on your self-hosted runner, authenticates
#     with `/AccessToken:` from the OIDC-federated token and lands as `sa`-
#     equivalent inside the database - with no password anywhere.
#
# If you instead made a single human the Entra admin, the pipeline would need
# a SQL login and you would be back to storing a password.
# ---------------------------------------------------------------------------

locals {
  # Long-Term Retention only makes sense once the data is real.
  ltr = var.environment == "prod"
}

resource "random_password" "sql_admin" {
  count = var.entra_only_authentication ? 0 : 1

  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_mssql_server" "this" {
  name                = var.server_name
  resource_group_name = var.resource_group_name
  location            = var.location
  version             = "12.0"

  # SQL-auth admin. Only created when Entra-only auth is off. Even then the
  # password is random, stored in Key Vault, and never used by the pipeline.
  administrator_login          = var.entra_only_authentication ? null : var.sql_admin_login
  administrator_login_password = var.entra_only_authentication ? null : random_password.sql_admin[0].result

  minimum_tls_version           = "1.2"
  public_network_access_enabled = var.public_network_access_enabled

  # Used by auditing and vulnerability assessment to write to the logs
  # container, and by any future OPENROWSET/BULK INSERT from the lake.
  identity {
    type = "SystemAssigned"
  }

  azuread_administrator {
    login_username = var.aad_admin_login
    object_id      = var.aad_admin_object_id
    tenant_id      = var.tenant_id

    # When true, SQL authentication is refused entirely - only Entra tokens
    # are accepted. This is the recommended posture and works with sqlpackage
    # via /AccessToken. Set false only if a legacy app needs a SQL login.
    azuread_authentication_only = var.entra_only_authentication
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

resource "azurerm_mssql_database" "this" {
  name      = var.database_name
  server_id = azurerm_mssql_server.this.id

  sku_name    = var.sku_name
  max_size_gb = var.max_size_gb
  collation   = "SQL_Latin1_General_CP1_CI_AS"

  # Serverless compute (GP_S_*) auto-pauses. Excellent for dev - the database
  # costs storage only overnight - and a trap in prod, where the first query
  # after a pause takes 30-60s to resume.
  auto_pause_delay_in_minutes = var.auto_pause_delay_in_minutes
  min_capacity                = var.min_capacity

  zone_redundant = var.zone_redundant
  license_type   = null

  # Point-in-time restore window.
  short_term_retention_policy {
    retention_days = var.pitr_retention_days
  }

  dynamic "long_term_retention_policy" {
    for_each = local.ltr ? [1] : []
    content {
      weekly_retention  = "P4W"
      monthly_retention = "P12M"
      yearly_retention  = "P7Y"
      week_of_year      = 1
    }
  }

  # Ledger is off: this is an analytical serving layer that gets truncated and
  # reloaded, not a system of record.
  ledger_enabled = false

  # Transparent Data Encryption is on by default with a service-managed key.

  tags = var.tags

  lifecycle {
    prevent_destroy = false # flip to true in prod once loaded
  }
}

# ---------------------------------------------------------------------------
# Private endpoint
#
# Sub-resource "sqlServer" covers TDS on 1433. Note that the Azure SQL gateway
# also uses "redirect" mode on ports 11000-11999 for connections originating
# INSIDE Azure - the NSG in modules/network opens that range for exactly this
# reason. sqlpackage from your runner will negotiate Redirect and silently fail
# if 11000-11999 is blocked, with a misleading "network-related or
# instance-specific error".
# ---------------------------------------------------------------------------

resource "azurerm_private_endpoint" "sql" {
  name                = "pe-${var.server_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.server_name}"
    private_connection_resource_id = azurerm_mssql_server.this.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids["privatelink.database.windows.net"]]
  }
}

# ---------------------------------------------------------------------------
# Auditing
#
# Writes to the lake's `logs` filesystem using the server's managed identity.
# The identity needs Storage Blob Data Contributor there - granted by the
# caller through modules/storage's data_plane_role_assignments.
# ---------------------------------------------------------------------------

resource "azurerm_mssql_server_extended_auditing_policy" "this" {
  count = var.enable_auditing ? 1 : 0

  server_id                               = azurerm_mssql_server.this.id
  storage_endpoint                        = var.audit_storage_endpoint
  storage_account_subscription_id         = var.subscription_id
  retention_in_days                       = var.audit_retention_days
  log_monitoring_enabled                  = true
  storage_account_access_key_is_secondary = false

  # No storage_account_access_key -> the server's managed identity is used.
}

resource "azurerm_mssql_server_security_alert_policy" "this" {
  count = var.enable_threat_detection ? 1 : 0

  resource_group_name = var.resource_group_name
  server_name         = azurerm_mssql_server.this.name
  state               = "Enabled"

  email_account_admins = true
  email_addresses      = var.security_alert_emails
  retention_days       = 30

  disabled_alerts = []
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "database" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "diag"
  target_resource_id         = azurerm_mssql_database.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # QueryStoreRuntimeStatistics and Errors are the two that pay for themselves
  # the first time a merge proc regresses.
  enabled_log { category = "SQLInsights" }
  enabled_log { category = "AutomaticTuning" }
  enabled_log { category = "QueryStoreRuntimeStatistics" }
  enabled_log { category = "QueryStoreWaitStatistics" }
  enabled_log { category = "Errors" }
  enabled_log { category = "DatabaseWaitStatistics" }
  enabled_log { category = "Timeouts" }
  enabled_log { category = "Blocks" }
  enabled_log { category = "Deadlocks" }

  enabled_metric {
    category = "Basic"
  }
}

# ---------------------------------------------------------------------------
# Maintenance window - keep patching away from the nightly load.
# ---------------------------------------------------------------------------

resource "azurerm_mssql_server_transparent_data_encryption" "this" {
  server_id = azurerm_mssql_server.this.id
  # Service-managed key. Swap to key_vault_key_id for CMK/BYOK.
}
