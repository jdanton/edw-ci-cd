# ---------------------------------------------------------------------------
# modules/datafactory/main.tf
#
# Azure Data Factory - the orchestrator.
#
# ---------------------------------------------------------------------------
# THE INFRASTRUCTURE / ARTIFACT BOUNDARY
# ---------------------------------------------------------------------------
# ADF blurs the line between "infrastructure" and "code". Terraform can create
# pipelines and linked services; so can azure.datafactory.tools. If both do,
# they fight, and every deployment produces spurious diffs.
#
# This template draws the line here:
#
#   TERRAFORM owns          |  azure.datafactory.tools owns
#   ------------------------+--------------------------------
#   the factory resource    |  pipeline/
#   managed virtual network |  dataset/
#   managed private endpts  |  linkedService/
#   integration runtimes    |  trigger/
#   diagnostic settings     |  dataflow/
#   RBAC / managed identity |  factory/ (global parameters)
#
# Rationale: the left column is network-and-identity shaped, changes rarely, and
# needs to exist BEFORE any artifact can be published (a linked service that
# references IR-ManagedVNet cannot deploy if that IR does not exist). The right
# column is code, is authored in ADF Studio, and belongs in Git.
#
# The consequence is that .github/workflows/adf-cd.yml must exclude
# integrationRuntime and managedVirtualNetwork from publication. That exclusion
# lives in src/adf/deployment/publish_config.json - if you ever see Terraform
# and the pipeline flip-flopping an IR, that file is where to look.
# ---------------------------------------------------------------------------

locals {
  # Everything the factory's managed VNet must reach privately.
  #
  # NOT included: the public NYC Taxi source (azureopendatastorage). Managed
  # VNet integration runtimes retain outbound access to public endpoints, so
  # the anonymous read of the open dataset works without a managed PE. If you
  # enable data exfiltration protection on Synapse or add an equivalent egress
  # lockdown here, that copy is the thing that breaks first.
  default_managed_private_endpoints = merge(
    {
      "lake-dfs" = {
        target_resource_id = var.lake_storage_account_id
        subresource_name   = "dfs"
        fqdns              = []
        description        = "Copy activity writes raw Parquet and reads curated Parquet."
      }
      "lake-blob" = {
        target_resource_id = var.lake_storage_account_id
        subresource_name   = "blob"
        fqdns              = []
        description        = "Blob API path used by the Binary and Delete activities."
      }
      "azure-sql" = {
        target_resource_id = var.sql_server_id
        subresource_name   = "sqlServer"
        fqdns              = []
        description        = "Copy sink and Stored Procedure activity against the serving database."
      }
    },
    var.key_vault_id == null ? {} : {
      "keyvault" = {
        target_resource_id = var.key_vault_id
        subresource_name   = "vault"
        fqdns              = []
        description        = "LS_KeyVault resolves secrets at pipeline runtime."
      }
    },
    var.synapse_workspace_id == null ? {} : {
      "synapse-sqlondemand" = {
        target_resource_id = var.synapse_workspace_id
        subresource_name   = "SqlOnDemand"
        fqdns              = []
        description        = "Script activity runs the CETAS procedures on the serverless pool."
      }
      "synapse-dev" = {
        target_resource_id = var.synapse_workspace_id
        subresource_name   = "Dev"
        fqdns              = []
        description        = "Synapse Notebook / pipeline activities, if you add them later."
      }
    },
  )

  managed_private_endpoints = merge(local.default_managed_private_endpoints, var.additional_managed_private_endpoints)

  factory_private_endpoints = {
    "datafactory" = {
      subresource = "dataFactory"
      zone        = "privatelink.datafactory.azure.net"
      description = "Runtime endpoint. Required by self-hosted integration runtimes and by the Studio data preview."
    }
    "portal" = {
      subresource = "portal"
      zone        = "privatelink.adf.azure.com"
      description = "ADF Studio authoring UI over Private Link."
    }
  }
}

resource "azurerm_data_factory" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  # Managed VNet. Once enabled, the AutoResolveIntegrationRuntime still exists
  # but is NOT in the managed VNet - only IRs explicitly created with
  # virtual_network_enabled = true are. artifacts must reference the managed IR
  # by name or their traffic leaves via public endpoints.
  managed_virtual_network_enabled = true

  # Disables the ADF *data plane* public endpoint. The ARM control plane stays
  # public, which is why azure.datafactory.tools (built on Az.DataFactory ARM
  # cmdlets) still works. Studio, however, needs the private endpoints below.
  public_network_enabled = var.public_network_enabled

  identity {
    type = "SystemAssigned"
  }

  # -------------------------------------------------------------------------
  # Git integration
  #
  # DELIBERATELY OPTIONAL AND DEFAULT-OFF. Reasons:
  #
  #  1. Only the DEV factory should ever be Git-connected. Test and prod run in
  #     "live mode" and receive artifacts exclusively from the pipeline. A
  #     Git-connected prod factory invites someone to publish from Studio.
  #  2. Configuring Git here creates a chicken-and-egg with repository
  #     creation, and the first `terraform apply` after connecting frequently
  #     reports a diff on `root_folder` that never converges.
  #  3. GitHub configuration via ARM requires the caller to have already
  #     completed the OAuth consent flow in the portal at least once.
  #
  # The template's recommendation: connect dev to Git ONCE through ADF Studio,
  # then set `import_existing_git_configuration = true` here so Terraform
  # adopts rather than fights it. See docs/06-data-factory.md.
  # -------------------------------------------------------------------------
  dynamic "github_configuration" {
    for_each = var.github_configuration == null ? [] : [var.github_configuration]
    content {
      account_name       = github_configuration.value.account_name
      branch_name        = github_configuration.value.branch_name
      git_url            = github_configuration.value.git_url
      repository_name    = github_configuration.value.repository_name
      root_folder        = github_configuration.value.root_folder
      publishing_enabled = github_configuration.value.publishing_enabled
    }
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Integration runtime inside the managed VNet
#
# Every artifact in src/adf/ references this by name. If you rename it here you
# must rename it in every linked service JSON, or add the mapping to the config
# CSV so azure.datafactory.tools rewrites it per environment.
#
# time_to_live keeps the compute warm between activities. Without it, each
# activity pays a 60-90 second managed-VNet cold start, which on a pipeline
# with a ForEach over 12 months is over 15 minutes of pure waiting.
# ---------------------------------------------------------------------------

resource "azurerm_data_factory_integration_runtime_azure" "managed_vnet" {
  name            = var.managed_vnet_ir_name
  data_factory_id = azurerm_data_factory.this.id
  location        = var.location

  virtual_network_enabled = true
  compute_type            = var.ir_compute_type
  core_count              = var.ir_core_count
  time_to_live_min        = var.ir_time_to_live_min

  description = "Managed VNet integration runtime. All copy and script activities in this factory run here so that traffic to the lake, Synapse and Azure SQL stays on managed private endpoints."
}

# ---------------------------------------------------------------------------
# Managed private endpoints (ADF managed VNet -> data)
#
# Unlike Synapse's, these are ARM control-plane resources, so Terraform can
# create them from anywhere. They still need approval on the target side.
# ---------------------------------------------------------------------------

resource "azurerm_data_factory_managed_private_endpoint" "this" {
  for_each = local.managed_private_endpoints

  name               = "mpe-${each.key}"
  data_factory_id    = azurerm_data_factory.this.id
  target_resource_id = each.value.target_resource_id
  subresource_name   = each.value.subresource_name
  fqdns              = length(each.value.fqdns) > 0 ? each.value.fqdns : null

  depends_on = [azurerm_data_factory_integration_runtime_azure.managed_vnet]
}

resource "null_resource" "approve_managed_private_endpoints" {
  count = var.auto_approve_managed_private_endpoints ? 1 : 0

  triggers = {
    endpoints = join(",", [for k, v in local.managed_private_endpoints : "${k}:${v.target_resource_id}:${v.subresource_name}"])
    factory   = azurerm_data_factory.this.id
  }

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-File"]
    command     = "${path.module}/../../../../scripts/Approve-PrivateEndpointConnections.ps1"

    environment = {
      TARGET_RESOURCE_IDS = join(",", distinct([for v in local.managed_private_endpoints : v.target_resource_id]))
      APPROVAL_REASON     = "Auto-approved by Terraform for Data Factory ${var.name}"
      CONNECTION_PREFIX   = var.name
    }
  }

  depends_on = [azurerm_data_factory_managed_private_endpoint.this]
}

# ---------------------------------------------------------------------------
# Private endpoints on the factory itself (caller -> ADF)
# ---------------------------------------------------------------------------

resource "azurerm_private_endpoint" "factory" {
  for_each = var.deploy_factory_private_endpoints ? local.factory_private_endpoints : {}

  name                = "pe-${var.name}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = merge(var.tags, { purpose = each.value.description })

  private_service_connection {
    name                           = "psc-${var.name}-${each.key}"
    private_connection_resource_id = azurerm_data_factory.this.id
    subresource_names              = [each.value.subresource]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids[each.value.zone]]
  }
}

# ---------------------------------------------------------------------------
# Diagnostics
#
# ActivityRuns and PipelineRuns are what the operations runbook queries. Without
# them, a failed overnight load leaves you with only the 45-day ADF Studio
# monitor retention and no way to trend failures.
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "this" {
  count = var.log_analytics_workspace_id == null ? 0 : 1

  name                       = "diag"
  target_resource_id         = azurerm_data_factory.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  # Resource-specific tables (ADFActivityRun, ADFPipelineRun, ...) rather than
  # the legacy AzureDiagnostics blob. Much cheaper to query and far easier to
  # write KQL against.
  log_analytics_destination_type = "Dedicated"

  enabled_log { category = "ActivityRuns" }
  enabled_log { category = "PipelineRuns" }
  enabled_log { category = "TriggerRuns" }
  enabled_log { category = "SandboxPipelineRuns" }
  enabled_log { category = "SandboxActivityRuns" }

  enabled_metric {
    category = "AllMetrics"
  }
}
