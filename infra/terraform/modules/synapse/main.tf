# ---------------------------------------------------------------------------
# modules/synapse/main.tf
#
# Synapse Analytics workspace, SERVERLESS SQL ONLY. No dedicated SQL pool, no
# Spark pool. The workspace exists to give us:
#
#   * a serverless SQL endpoint (<ws>-ondemand.sql.azuresynapse.net) that reads
#     Parquet straight off the lake with OPENROWSET, and writes conformed
#     Parquet back with CETAS
#   * a logical data warehouse - external tables and views that analysts and
#     Power BI can query without moving data
#   * a managed VNet with managed private endpoints, so none of that traffic
#     traverses a public endpoint
#
# ---------------------------------------------------------------------------
# THE ORDERING PROBLEM, READ THIS BEFORE DEBUGGING A FAILED APPLY
# ---------------------------------------------------------------------------
# Synapse splits its API surface in two:
#
#   control plane  management.azure.com          always public
#   data plane     <ws>.dev.azuresynapse.net     private when public access off
#
# `azurerm_synapse_managed_private_endpoint` and `azurerm_synapse_firewall_rule`
# are DATA-PLANE resources. With public_network_access_enabled = false they can
# only be created from a host that (a) can route to the Dev private endpoint and
# (b) resolves privatelink.dev.azuresynapse.net.
#
# So the dependency chain has to be:
#     workspace -> Dev private endpoint -> DNS zone group -> managed PEs
#
# It is encoded with depends_on below. It still means `terraform apply` MUST run
# on your VNet-attached self-hosted runner, not a laptop. From outside you get
# a bare "context deadline exceeded" with no hint that DNS is the cause.
# ---------------------------------------------------------------------------

locals {
  # Managed private endpoints the workspace needs to do its job.
  #
  # ADLS needs BOTH blob and dfs, for the same reason the spoke VNet does:
  # OPENROWSET/CETAS use dfs, but some internal paths use blob.
  default_managed_private_endpoints = merge(
    {
      "lake-dfs" = {
        target_resource_id = var.lake_storage_account_id
        subresource_name   = "dfs"
        description        = "Serverless SQL reads raw Parquet and writes curated Parquet over the Data Lake API."
      }
      "lake-blob" = {
        target_resource_id = var.lake_storage_account_id
        subresource_name   = "blob"
        description        = "Blob API fallback used by some Synapse internals."
      }
    },
    var.enable_key_vault_endpoint ? {
      "keyvault" = {
        target_resource_id = var.key_vault_id
        subresource_name   = "vault"
        description        = "Synapse linked services resolve secrets from Key Vault."
      }
    } : {},
    var.enable_sql_endpoint ? {
      "azure-sql" = {
        target_resource_id = var.sql_server_id
        subresource_name   = "sqlServer"
        description        = "Optional: lets Synapse pipelines reach the serving database directly."
      }
    } : {},
  )

  managed_private_endpoints = merge(local.default_managed_private_endpoints, var.additional_managed_private_endpoints)

  # Sub-resource -> DNS zone mapping for the workspace's own private endpoints.
  workspace_private_endpoints = {
    "sql" = {
      subresource = "Sql"
      zone        = "privatelink.sql.azuresynapse.net"
      description = "Dedicated SQL pool endpoint. Created even though we run serverless-only: the SqlOnDemand endpoint shares this DNS zone, and having both avoids a confusing partial-resolution state if a dedicated pool is added later."
    }
    "sqlondemand" = {
      subresource = "SqlOnDemand"
      zone        = "privatelink.sql.azuresynapse.net"
      description = "Serverless SQL endpoint - <ws>-ondemand.sql.azuresynapse.net. This is what the serverless DDL deployment and ADF's Script activity connect to."
    }
    "dev" = {
      subresource = "Dev"
      zone        = "privatelink.dev.azuresynapse.net"
      description = "Artifact/development REST API. azure.synapse.tools (Publish-SynapseFromJson) talks to this. Without it, artifact deployment cannot work at all."
    }
  }
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

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------

resource "azurerm_synapse_workspace" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  # Every workspace demands a default ADLS Gen2 filesystem. It holds workspace
  # metadata and Spark artifacts - NOT your data. Keep it separate from the
  # medallion filesystems so nobody confuses the two.
  storage_data_lake_gen2_filesystem_id = var.default_filesystem_id

  # Both of these are set-at-creation-only. Changing either forces a full
  # replace of the workspace, which drops every serverless database, view and
  # external table in it. They are the two most important decisions in this file.
  managed_virtual_network_enabled = true

  # Data exfiltration protection restricts outbound traffic from the managed
  # VNet to an approved tenant list. It is the right answer for regulated data,
  # but it means EVERY outbound target needs a managed private endpoint - there
  # is no "just reach the public internet" escape hatch. Default off so the
  # template works out of the box; turn on deliberately.
  data_exfiltration_protection_enabled = var.data_exfiltration_protection_enabled

  # ALWAYS true at CREATE. Locked down afterwards by
  # null_resource.disable_public_network_access below.
  #
  # Creating a managed-VNet workspace with public access DISABLED does not
  # merely take longer - it never finishes. Measured on this subscription:
  #
  #   publicNetworkAccess = Disabled   30+ min, no completion, ends Failed
  #   publicNetworkAccess = Enabled    7 minutes, Succeeded
  #
  # Same storage account, same filesystem, same managed VNet; the flag was the
  # only difference. Synapse needs to reach its own endpoints while
  # provisioning, and disabling public access before it exists denies it that.
  #
  # Raising the Terraform timeout does NOT fix this - it only makes the failure
  # take longer to arrive, because Azure was never going to finish.
  public_network_access_enabled = true

  sql_administrator_login          = var.entra_only_authentication ? null : var.sql_admin_login
  sql_administrator_login_password = var.entra_only_authentication ? null : random_password.sql_admin[0].result

  # Entra-only authentication for the serverless SQL endpoint.
  azuread_authentication_only = var.entra_only_authentication

  identity {
    type = "SystemAssigned"
  }

  # Purview integration and CMK are deliberately out of scope for the template.

  tags = var.tags

  # ---------------------------------------------------------------------
  # 30 MINUTES IS NOT ENOUGH, AND THE FAILURE LOOKS LIKE SOMETHING ELSE.
  #
  # The provider default for create is 30m. A managed-VNet workspace in a cold
  # region routinely exceeds it, and when it does you get:
  #
  #   Error: waiting for creation of Workspace: Future#WaitForCompletion:
  #   context has been cancelled: StatusCode=200 -- Original Error: context
  #   deadline exceeded
  #
  # Read StatusCode=200: AZURE WAS STILL WORKING AND HAPPY. The cancellation is
  # Terraform's own deadline, not an Azure error. But the workspace is then left
  # mid-provision and settles into provisioningState = Failed, so the next
  # apply finds a Failed workspace and the whole thing looks like a broken
  # configuration rather than a timeout.
  #
  # That misreading cost several 30-minute cycles here. Ninety minutes is
  # generous rather than tuned - the cost of being wrong in this direction is
  # only waiting, while the cost of being wrong the other way is a Failed
  # workspace that must be deleted by hand before anything can proceed.
  # ---------------------------------------------------------------------
  lifecycle {
    ignore_changes = [
      # Created with public access enabled and disabled straight afterwards, so
      # Azure always reports Disabled while this configuration says true.
      # Without this, every plan proposes turning it back on.
      public_network_access_enabled,

      # THE ONE THAT DESTROYED THIS WORKSPACE ON EVERY APPLY.
      #
      # With azuread_authentication_only = true we deliberately pass no SQL
      # administrator - there is no password anywhere in this platform. But
      # Azure does not store "none": it assigns a default, "sqladminuser".
      #
      # So state holds "sqladminuser", configuration holds null, and
      # sql_administrator_login is ForceNew. Every plan therefore read:
      #
      #   - sql_administrator_login = "sqladminuser" -> null # forces replacement
      #
      # and every apply destroyed and recreated the workspace - taking its
      # managed private endpoints, diagnostic settings, role assignments and
      # every ADF endpoint pointing at it along for the ride. Plan: 17 to add,
      # 3 to change, 10 to destroy, on a configuration nobody had changed.
      #
      # The login is inert: azuread_authentication_only = true means SQL
      # authentication is refused outright, so what Azure recorded in that field
      # can never be used to connect. Ignoring it is safe, and is the only way
      # to express "we did not set this" to a provider whose API has no way to
      # represent it.
      sql_administrator_login,
    ]
  }

  timeouts {
    create = "90m"
    update = "60m"
    delete = "60m"
  }
}

# ---------------------------------------------------------------------------
# Administrators
#
# In azurerm 3.x these were `aad_admin` and `sql_aad_admin` blocks INSIDE the
# workspace resource. Provider 4.0 removed them in favour of these two separate
# resources, because the inline blocks could not express "unset" and produced
# perpetual diffs when the admin was managed elsewhere.
#
# Both point at the SAME Entra group, deliberately:
#
#   azurerm_synapse_workspace_aad_admin      -> Synapse RBAC (Studio, artifacts)
#   azurerm_synapse_workspace_sql_aad_admin  -> serverless SQL endpoint (sysadmin)
#
# The GitHub Actions deployment service principal is a member of that group
# (bootstrap/main.tf puts it there), which is what lets a single OIDC token
# both publish artifacts with azure.synapse.tools AND run the serverless DDL in
# src/synapse/serverless/ - with no password and no extra grant.
# ---------------------------------------------------------------------------

resource "azurerm_synapse_workspace_aad_admin" "this" {
  synapse_workspace_id = azurerm_synapse_workspace.this.id
  login                = var.aad_admin_login
  object_id            = var.aad_admin_object_id
  tenant_id            = var.tenant_id
}

resource "azurerm_synapse_workspace_sql_aad_admin" "this" {
  synapse_workspace_id = azurerm_synapse_workspace.this.id
  login                = var.aad_admin_login
  object_id            = var.aad_admin_object_id
  tenant_id            = var.tenant_id
}

# ---------------------------------------------------------------------------
# SYNAPSE RBAC - the third permission system, and the one nothing else covers.
#
# Azure RBAC governs the resource. The two admin blocks above govern the SQL
# endpoints. NEITHER grants anything in Synapse Studio, which is governed by
# Synapse RBAC - a separate store, seeded with exactly one assignment: whoever
# CREATED the workspace.
#
# Here the creator is the deployment service principal, because Terraform makes
# the workspace. So CI could publish artifacts through the Dev API from day one
# while every human - including a subscription Owner who is a member of the
# Entra admin group - got
#
#   Failed to load one or more resources due to no access, error code 403
#
# on every dataset, pipeline and linked service, and could not query the
# serverless endpoint either. Nothing in the platform said why, because from
# Azure RBAC's point of view they had everything.
#
# Granting the admin group Synapse Administrator is what closes that. Without
# this resource a freshly built environment ships locked to its own pipeline.
#
# This is a DEV-API call: it needs the workspace endpoint to be reachable, so it
# only works from the self-hosted runner (or any host on a linked VNet), and it
# is ordered after the private endpoints for that reason.
# ---------------------------------------------------------------------------

resource "azurerm_synapse_role_assignment" "admins" {
  synapse_workspace_id = azurerm_synapse_workspace.this.id
  role_name            = "Synapse Administrator"
  principal_id         = var.aad_admin_object_id
  principal_type       = "Group"

  depends_on = [
    azurerm_private_endpoint.workspace,
    azurerm_synapse_workspace_aad_admin.this,
  ]
}

# ---------------------------------------------------------------------------
# Workspace private endpoints (into OUR spoke VNet)
#
# Direction: caller -> Synapse. These are what let the self-hosted runner, and
# ADF's managed VNet, reach the workspace.
# ---------------------------------------------------------------------------

resource "azurerm_private_endpoint" "workspace" {
  for_each = local.workspace_private_endpoints

  name                = "pe-${var.name}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id

  tags = merge(var.tags, { purpose = each.value.description })

  private_service_connection {
    name                           = "psc-${var.name}-${each.key}"
    private_connection_resource_id = azurerm_synapse_workspace.this.id
    subresource_names              = [each.value.subresource]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids[each.value.zone]]
  }
}

# ---------------------------------------------------------------------------
# Private Link Hub - Synapse Studio over Private Link
#
# Studio (web.azuresynapse.net) is a separate service from the workspace. To
# open Studio from inside a private network you need a Private Link Hub plus a
# private endpoint on it. Skip this if humans always use Studio from the
# corporate network over the public endpoint.
# ---------------------------------------------------------------------------

resource "azurerm_synapse_private_link_hub" "this" {
  count = var.deploy_private_link_hub ? 1 : 0

  name                = var.private_link_hub_name
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_private_endpoint" "private_link_hub" {
  count = var.deploy_private_link_hub ? 1 : 0

  name                = "pe-${var.private_link_hub_name}-web"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.private_link_hub_name}-web"
    private_connection_resource_id = azurerm_synapse_private_link_hub.this[0].id
    subresource_names              = ["Web"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids["privatelink.azuresynapse.net"]]
  }
}

# ---------------------------------------------------------------------------
# Managed private endpoints (OUT of the Synapse managed VNet)
#
# Direction: Synapse -> data. DATA-PLANE resources; see the header note.
#
# Freshly created managed private endpoints sit in state "Pending" on the
# TARGET resource until someone approves the connection. Terraform does not do
# that for you. The approval is handled by the null_resource below (or, if you
# prefer, manually - see docs/04-networking.md).
# ---------------------------------------------------------------------------

# A private endpoint is not usable the instant Terraform returns. The NIC, the
# DNS zone group A record, and the workspace's own view of the approved
# connection all settle independently, over tens of seconds.
#
# Creating the managed private endpoints immediately afterwards raced that, and
# failed with a 403 that blames the caller's IP rather than the timing:
#
#   ClientIpAddressNotAuthorized: Client IP address 172.16.0.4 is not authorized
#   to access private endpoint connection with link ID ... in workspace ...
#
# The IP was correct and the connection WAS approved - it simply had not
# propagated. Same class of problem as the Entra RBAC waits elsewhere.
resource "time_sleep" "wait_for_workspace_private_endpoints" {
  depends_on      = [azurerm_private_endpoint.workspace]
  create_duration = "90s"
}

resource "azurerm_synapse_managed_private_endpoint" "this" {
  for_each = local.managed_private_endpoints

  name                 = "mpe-${each.key}"
  synapse_workspace_id = azurerm_synapse_workspace.this.id
  target_resource_id   = each.value.target_resource_id
  subresource_name     = each.value.subresource_name

  depends_on = [
    # Data-plane call through the Dev endpoint: it must exist, resolve
    # privately, AND have settled. See the time_sleep above.
    azurerm_private_endpoint.workspace,
    time_sleep.wait_for_workspace_private_endpoints,
  ]
}

# ---------------------------------------------------------------------------
# Lock the workspace down, now that it exists.
#
# Ordered AFTER the managed private endpoints: those are Dev-API (data-plane)
# calls, and doing them before the private path is proven leaves no way back in
# if something is wrong. By this point the workspace private endpoints exist,
# DNS has settled, and the runner reaches the Dev endpoint privately.
#
# az synapse workspace update has no flag for this, so it is a generic ARM
# PATCH. Verified: the workspace stays provisioningState = Succeeded.
# ---------------------------------------------------------------------------

resource "null_resource" "disable_public_network_access" {
  count = var.public_network_access_enabled ? 0 : 1

  triggers = {
    workspace_id = azurerm_synapse_workspace.this.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      echo "Disabling public network access on ${azurerm_synapse_workspace.this.name}..."
      az resource update         --ids "${azurerm_synapse_workspace.this.id}"         --set properties.publicNetworkAccess=Disabled         --output none
      echo "  publicNetworkAccess is now $(az resource show --ids "${azurerm_synapse_workspace.this.id}" --query properties.publicNetworkAccess -o tsv)"
    EOT
  }

  depends_on = [
    azurerm_private_endpoint.workspace,
    azurerm_synapse_managed_private_endpoint.this,
    null_resource.approve_managed_private_endpoints,
  ]
}

# ---------------------------------------------------------------------------
# Approve the pending connections on the target resources.
#
# `az network private-endpoint-connection approve` is idempotent-ish: it errors
# if the connection is already approved, so the script filters on state first.
# Runs on every apply where the set of endpoints changes.
# ---------------------------------------------------------------------------

resource "null_resource" "approve_managed_private_endpoints" {
  count = var.auto_approve_managed_private_endpoints ? 1 : 0

  triggers = {
    endpoints = join(",", [for k, v in local.managed_private_endpoints : "${k}:${v.target_resource_id}:${v.subresource_name}"])
    workspace = azurerm_synapse_workspace.this.id
  }

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-File"]
    command     = "${path.module}/../../../../scripts/Approve-PrivateEndpointConnections.ps1"

    environment = {
      TARGET_RESOURCE_IDS = join(",", distinct([for v in local.managed_private_endpoints : v.target_resource_id]))
      APPROVAL_REASON     = "Auto-approved by Terraform for Synapse workspace ${var.name}"
      CONNECTION_PREFIX   = var.name
    }
  }

  depends_on = [azurerm_synapse_managed_private_endpoint.this]
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.enable_diagnostics ? 1 : 0

  name                       = "diag"
  target_resource_id         = azurerm_synapse_workspace.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # BuiltinSqlReqsEnded is THE table for serverless. It records every query,
  # its duration, and - critically - dataProcessedBytes, which is what you are
  # billed on. Cost surprises in serverless are always visible here first.
  enabled_log { category = "BuiltinSqlReqsEnded" }
  enabled_log { category = "SynapseRbacOperations" }
  enabled_log { category = "GatewayApiRequests" }
  enabled_log { category = "SynapseLinkEvent" }

  enabled_metric {
    category = "AllMetrics"
  }
}
