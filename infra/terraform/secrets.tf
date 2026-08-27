# ---------------------------------------------------------------------------
# infra/terraform/secrets.tf
#
# Key Vault contents.
#
# Under the template defaults (Entra-only authentication on both Azure SQL and
# Synapse) there are NO passwords to store, and this file creates almost
# nothing. That is the point: the best secret management is not having secrets.
#
# The conditional entries below exist for the cases where you genuinely cannot
# use Entra-only auth - a legacy reporting tool with a hard-coded SQL login, a
# third-party ETL agent, and so on.
#
# DATA PLANE WARNING: with public_network_access_enabled = false on the vault,
# these resources only succeed from a host that can reach the private endpoint.
# See docs/12-troubleshooting.md#key-vault-403.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Azure SQL administrator password (only when SQL auth is permitted)
# ---------------------------------------------------------------------------

resource "azurerm_key_vault_secret" "sql_admin_password" {
  count = var.sql_entra_only_authentication ? 0 : 1

  name         = "sql-admin-password"
  value        = module.sql.admin_password
  key_vault_id = module.keyvault.id
  content_type = "password"

  tags = merge(local.common_tags, {
    "rotation-owner"  = "data-platform"
    "rotation-period" = "P90D"
  })

  lifecycle {
    # If the password is rotated by a runbook, Terraform must not reset it.
    ignore_changes = [value]
  }

  # module.keyvault, not just the RBAC wait. The vault's data plane is private,
  # so a secret write needs its PRIVATE ENDPOINT and DNS zone group in place, not
  # merely permission - and nothing in the graph connects a key_vault_secret to
  # either. The module's own secrets already depend on the endpoint; these did
  # not, which made this an ordering bug waiting for an environment where DNS
  # was not already resolvable.
  #
  # dev never showed it: dev created its privatelink zones and linked the runner
  # VNet to them, so the name resolved no matter when the write happened. In test
  # the same zone names cannot be linked to that runner - one VNet, one link per
  # namespace - so test consumes dev's zones, and the write raced the zone group
  # being re-pointed at them. It lost, and the error blamed the vault:
  #
  #   checking for presence of existing Secret "lake-dfs-endpoint": autorest/
  #   Client#Do: Preparing request failed: StatusCode=0
  #
  # StatusCode=0 is a connection that never happened, not a permission denied.
  depends_on = [
    module.keyvault,
    time_sleep.wait_for_keyvault_rbac,
  ]
}

# ---------------------------------------------------------------------------
# Connection metadata
#
# NOT secret - these are hostnames - but ADF linked services can reference Key
# Vault for any value, and centralising endpoints here means a rebuilt
# environment with a new random suffix does not require an artifact change.
#
# The template does NOT use this path: it rewrites endpoints through the
# azure.datafactory.tools config CSV instead, which is more explicit and shows
# up in code review. These entries exist because the Key Vault approach is
# common in the wild and you may be migrating from it. See
# docs/06-data-factory.md#config-csv-vs-key-vault.
# ---------------------------------------------------------------------------

resource "azurerm_key_vault_secret" "lake_dfs_endpoint" {
  name         = "lake-dfs-endpoint"
  value        = module.storage.dfs_endpoint
  key_vault_id = module.keyvault.id
  content_type = "uri"

  tags = merge(local.common_tags, { "secret-class" = "endpoint-not-secret" })

  # module.keyvault, not just the RBAC wait. The vault's data plane is private,
  # so a secret write needs its PRIVATE ENDPOINT and DNS zone group in place, not
  # merely permission - and nothing in the graph connects a key_vault_secret to
  # either. The module's own secrets already depend on the endpoint; these did
  # not, which made this an ordering bug waiting for an environment where DNS
  # was not already resolvable.
  #
  # dev never showed it: dev created its privatelink zones and linked the runner
  # VNet to them, so the name resolved no matter when the write happened. In test
  # the same zone names cannot be linked to that runner - one VNet, one link per
  # namespace - so test consumes dev's zones, and the write raced the zone group
  # being re-pointed at them. It lost, and the error blamed the vault:
  #
  #   checking for presence of existing Secret "lake-dfs-endpoint": autorest/
  #   Client#Do: Preparing request failed: StatusCode=0
  #
  # StatusCode=0 is a connection that never happened, not a permission denied.
  depends_on = [
    module.keyvault,
    time_sleep.wait_for_keyvault_rbac,
  ]
}

resource "azurerm_key_vault_secret" "synapse_serverless_endpoint" {
  name         = "synapse-serverless-endpoint"
  value        = module.synapse.serverless_sql_endpoint
  key_vault_id = module.keyvault.id
  content_type = "fqdn"

  tags = merge(local.common_tags, { "secret-class" = "endpoint-not-secret" })

  # module.keyvault, not just the RBAC wait. The vault's data plane is private,
  # so a secret write needs its PRIVATE ENDPOINT and DNS zone group in place, not
  # merely permission - and nothing in the graph connects a key_vault_secret to
  # either. The module's own secrets already depend on the endpoint; these did
  # not, which made this an ordering bug waiting for an environment where DNS
  # was not already resolvable.
  #
  # dev never showed it: dev created its privatelink zones and linked the runner
  # VNet to them, so the name resolved no matter when the write happened. In test
  # the same zone names cannot be linked to that runner - one VNet, one link per
  # namespace - so test consumes dev's zones, and the write raced the zone group
  # being re-pointed at them. It lost, and the error blamed the vault:
  #
  #   checking for presence of existing Secret "lake-dfs-endpoint": autorest/
  #   Client#Do: Preparing request failed: StatusCode=0
  #
  # StatusCode=0 is a connection that never happened, not a permission denied.
  depends_on = [
    module.keyvault,
    time_sleep.wait_for_keyvault_rbac,
  ]
}

resource "azurerm_key_vault_secret" "sql_server_fqdn" {
  name         = "sql-server-fqdn"
  value        = module.sql.server_fqdn
  key_vault_id = module.keyvault.id
  content_type = "fqdn"

  tags = merge(local.common_tags, { "secret-class" = "endpoint-not-secret" })

  # module.keyvault, not just the RBAC wait. The vault's data plane is private,
  # so a secret write needs its PRIVATE ENDPOINT and DNS zone group in place, not
  # merely permission - and nothing in the graph connects a key_vault_secret to
  # either. The module's own secrets already depend on the endpoint; these did
  # not, which made this an ordering bug waiting for an environment where DNS
  # was not already resolvable.
  #
  # dev never showed it: dev created its privatelink zones and linked the runner
  # VNet to them, so the name resolved no matter when the write happened. In test
  # the same zone names cannot be linked to that runner - one VNet, one link per
  # namespace - so test consumes dev's zones, and the write raced the zone group
  # being re-pointed at them. It lost, and the error blamed the vault:
  #
  #   checking for presence of existing Secret "lake-dfs-endpoint": autorest/
  #   Client#Do: Preparing request failed: StatusCode=0
  #
  # StatusCode=0 is a connection that never happened, not a permission denied.
  depends_on = [
    module.keyvault,
    time_sleep.wait_for_keyvault_rbac,
  ]
}

# ---------------------------------------------------------------------------
# The deployment identity needs data-plane rights to write the above.
#
# With enable_rbac_authorization = true, Contributor on the vault does NOT
# grant secret access - the data plane is a separate permission surface. This
# is the Key Vault equivalent of the "Contributor does not grant blob access"
# trap documented in rbac.tf.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "deployer_keyvault_secrets_officer" {
  scope                            = module.keyvault.id
  role_definition_name             = "Key Vault Secrets Officer"
  principal_id                     = local.deployer_principal_id
  skip_service_principal_aad_check = true

  description = "Terraform / CI deployment identity - creates and updates the secrets in this file."
}

# Entra RBAC takes up to a couple of minutes to reach the Key Vault data plane.
# Without this pause, the very first apply reliably fails with
# "Caller is not authorized to perform action on resource".
resource "time_sleep" "wait_for_keyvault_rbac" {
  depends_on      = [azurerm_role_assignment.deployer_keyvault_secrets_officer]
  create_duration = "60s"
}
