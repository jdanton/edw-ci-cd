# ---------------------------------------------------------------------------
# modules/keyvault/main.tf
#
# One vault per environment. It holds a deliberately short list:
#
#   * synapse-sql-admin-password  - the SQL-auth admin Synapse insists on having
#                                   at creation time, even when you then lock
#                                   the workspace to Entra-only authentication.
#   * sql-admin-password          - same story for Azure SQL when
#                                   entra_only_authentication = false.
#   * any connection string an ADF linked service resolves at runtime.
#
# ADF and Synapse read from here with their managed identities via the
# AzureKeyVault linked service, so no secret value ever appears in an artifact
# JSON file or in a config CSV.
#
# RBAC (not access policies) is used throughout. Access policies are legacy,
# do not support deny, and cannot be audited with the same tooling as the rest
# of Azure.
# ---------------------------------------------------------------------------

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id

  sku_name = "standard"

  rbac_authorization_enabled = true

  # Soft delete is mandatory and cannot be disabled. Purge protection CAN be
  # disabled, but a vault without it can be permanently destroyed by anyone
  # with Contributor. Off in dev (so you can tear the environment down and
  # rebuild with the same name), on everywhere else.
  purge_protection_enabled   = var.purge_protection_enabled
  soft_delete_retention_days = var.soft_delete_retention_days

  public_network_access_enabled = var.public_network_access_enabled

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.allowed_ip_rules
  }

  tags = var.tags
}

resource "azurerm_private_endpoint" "this" {
  name                = "pe-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids["privatelink.vaultcore.azure.net"]]
  }
}

# ---------------------------------------------------------------------------
# The identity running Terraform needs to write secrets. Contributor on the
# vault does not grant that - with RBAC authorization enabled, the data plane
# is a separate permission surface.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "terraform_secrets_officer" {
  count = var.grant_deployer_secrets_officer ? 1 : 0

  scope                            = azurerm_key_vault.this.id
  role_definition_name             = "Key Vault Secrets Officer"
  principal_id                     = data.azurerm_client_config.current.object_id
  skip_service_principal_aad_check = true
  description                      = "Terraform deployment identity - required to create the secrets below."
}

# Entra RBAC takes up to a few minutes to propagate to the Key Vault data
# plane. Without this wait the very first apply reliably fails with
# "Caller is not authorized to perform action on resource".
resource "time_sleep" "wait_for_rbac" {
  count = var.grant_deployer_secrets_officer ? 1 : 0

  depends_on      = [azurerm_role_assignment.terraform_secrets_officer]
  create_duration = "60s"
}

resource "azurerm_role_assignment" "consumers" {
  for_each = var.role_assignments

  scope                            = azurerm_key_vault.this.id
  role_definition_name             = each.value.role
  principal_id                     = each.value.principal_id
  principal_type                   = each.value.principal_type
  skip_service_principal_aad_check = true
  description                      = each.value.description
}

# ---------------------------------------------------------------------------
# Secrets
#
# DATA PLANE - same caveat as the lake filesystems. These only succeed from a
# host that can reach the private endpoint.
# ---------------------------------------------------------------------------

resource "azurerm_key_vault_secret" "this" {
  # `var.secrets` is sensitive, and Terraform refuses to derive resource
  # instance KEYS from a sensitive value - the keys would leak into plan output
  # and state addresses. nonsensitive() is applied to the key set only; the
  # VALUES are still looked up sensitively on the next line.
  for_each = nonsensitive(toset(keys(var.secrets)))

  name         = each.value
  value        = var.secrets[each.value].value
  key_vault_id = azurerm_key_vault.this.id
  content_type = var.secrets[each.value].content_type

  # Force a rotation cadence to show up in the portal and in Defender for Cloud.
  expiration_date = var.secrets[each.value].expiration_date

  tags = merge(var.tags, {
    "rotation-owner" = var.secrets[each.value].rotation_owner
  })

  depends_on = [
    azurerm_private_endpoint.this,
    time_sleep.wait_for_rbac,
  ]

  lifecycle {
    # Rotating a password out-of-band (via a runbook, or Entra PIM) should not
    # cause Terraform to reset it on the next apply.
    ignore_changes = [value]
  }
}

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.log_analytics_workspace_id == null ? 0 : 1

  name                       = "diag"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_log {
    category = "AzurePolicyEvaluationDetails"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
