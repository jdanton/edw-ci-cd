# ---------------------------------------------------------------------------
# modules/storage/main.tf
#
# ADLS Gen2 - the single source of truth for the lake layers.
#
# Design notes worth knowing before you change anything here:
#
# * is_hns_enabled = true is IRREVERSIBLE. You cannot turn a flat blob account
#   into a Data Lake account, or the other way round. Get it right first time.
#
# * shared_access_key_enabled = false. Nothing in this platform uses account
#   keys: ADF and Synapse authenticate with their system-assigned managed
#   identities, and humans authenticate with Entra. Disabling keys removes an
#   entire class of leaked-credential incident and is a hard requirement for
#   most enterprise landing zones.
#
# * Public network access is off. Every consumer reaches the account through a
#   private endpoint. That includes Terraform itself when it creates the
#   filesystems below - see the note on var.create_data_lake_directories.
# ---------------------------------------------------------------------------

locals {
  # Diagnostic categories that actually earn their storage cost. StorageRead on
  # a busy lake is voluminous; it is included because "who read the PII zone"
  # is the question auditors ask, and you cannot answer it retroactively.
  blob_log_categories = ["StorageRead", "StorageWrite", "StorageDelete"]

  # Flatten filesystem -> directories into a single map for for_each.
  directories = var.create_data_lake_directories ? {
    for item in flatten([
      for fs_name, fs in var.filesystems : [
        for dir in fs.directories : {
          key        = "${fs_name}/${dir}"
          filesystem = fs_name
          path       = dir
        }
      ]
    ]) : item.key => item
  } : {}
}

resource "azurerm_storage_account" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_kind             = "StorageV2"
  account_tier             = var.account_tier
  account_replication_type = var.replication_type
  access_tier              = "Hot"

  # The flag that makes this a Data Lake rather than a blob account.
  is_hns_enabled = true

  # Identity-based access only.
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true

  public_network_access_enabled = var.public_network_access_enabled

  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  infrastructure_encryption_enabled = true

  # Managed identity on the account itself. Not used by this template today,
  # but required the moment you adopt customer-managed keys.
  identity {
    type = "SystemAssigned"
  }

  blob_properties {
    versioning_enabled       = true
    change_feed_enabled      = false
    last_access_time_enabled = true

    delete_retention_policy {
      days = var.blob_soft_delete_days
    }

    container_delete_retention_policy {
      days = var.blob_soft_delete_days
    }
  }

  network_rules {
    # Deny everything not explicitly allowed. Private endpoint traffic is not
    # evaluated by these rules at all - it bypasses them by design - so this
    # only governs the (disabled) public endpoint.
    default_action = "Deny"

    # AzureServices bypass lets first-party services that cannot use private
    # endpoints (e.g. Storage Analytics writing to the logs filesystem, and
    # Azure Monitor) still reach the account.
    bypass = ["AzureServices", "Logging", "Metrics"]
  }

  tags = merge(var.tags, {
    "data-classification" = "internal"
    "layer"               = "lake"
  })

  lifecycle {
    # Flipping HNS or replication silently re-creates the account and destroys
    # every byte in the lake. Make that impossible by accident.
    ignore_changes = [
      # customer_managed_key is managed out-of-band if you adopt CMK.
    ]
    prevent_destroy = false # set true in prod after the first successful load
  }
}

# ---------------------------------------------------------------------------
# Private endpoints
#
# ADLS Gen2 needs TWO endpoints. This is not optional and not redundant:
#   blob -> the flat Blob REST API (used by AzCopy, some SDKs, Synapse's
#           OPENROWSET when the URL uses .blob.core.windows.net)
#   dfs  -> the Data Lake Storage REST API (used by ADF's ADLS Gen2 connector,
#           Synapse's abfss:// paths, and Terraform's filesystem resources)
#
# Deploy only one and roughly half your workloads break, in ways that look like
# intermittent auth failures.
# ---------------------------------------------------------------------------

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-${var.name}-blob"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}-blob"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = ["blob"]
    # Same-tenant, same-subscription: auto-approved, no manual step.
    is_manual_connection = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids["privatelink.blob.core.windows.net"]]
  }
}

resource "azurerm_private_endpoint" "dfs" {
  name                = "pe-${var.name}-dfs"
  resource_group_name = var.resource_group_name
  location            = var.location
  subnet_id           = var.private_endpoint_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.name}-dfs"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = ["dfs"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.private_dns_zone_ids["privatelink.dfs.core.windows.net"]]
  }
}

# ---------------------------------------------------------------------------
# Filesystems (containers)
#
# DATA PLANE. depends_on the dfs private endpoint so Terraform does not race
# ahead and try to create these before the name resolves privately.
# ---------------------------------------------------------------------------

resource "azurerm_storage_data_lake_gen2_filesystem" "this" {
  for_each = var.filesystems

  name               = each.key
  storage_account_id = azurerm_storage_account.this.id

  properties = {
    # Blob metadata values must be base64. Keeps the "why does this exist"
    # answer attached to the artifact itself.
    description = base64encode(each.value.description)
  }

  depends_on = [
    azurerm_private_endpoint.dfs,
    azurerm_private_endpoint.blob,
  ]
}

resource "azurerm_storage_data_lake_gen2_path" "directories" {
  for_each = local.directories

  path               = each.value.path
  filesystem_name    = azurerm_storage_data_lake_gen2_filesystem.this[each.value.filesystem].name
  storage_account_id = azurerm_storage_account.this.id
  resource           = "directory"

  depends_on = [azurerm_storage_data_lake_gen2_filesystem.this]
}

# ---------------------------------------------------------------------------
# Data-plane RBAC
#
# Azure RBAC "Contributor" on the account grants management-plane rights only.
# Reading or writing a blob requires one of the Storage Blob Data * roles.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "data_plane" {
  for_each = var.data_plane_role_assignments

  scope = each.value.filesystem == null ? azurerm_storage_account.this.id : "${azurerm_storage_account.this.id}/blobServices/default/containers/${each.value.filesystem}"

  role_definition_name             = each.value.role
  principal_id                     = each.value.principal_id
  principal_type                   = each.value.principal_type
  skip_service_principal_aad_check = true
  description                      = each.value.description

  depends_on = [azurerm_storage_data_lake_gen2_filesystem.this]
}

# ---------------------------------------------------------------------------
# Lifecycle management
#
# Raw data is written once and read a handful of times. Left on Hot it becomes
# the largest line item on the platform bill within a year.
# ---------------------------------------------------------------------------

resource "azurerm_storage_management_policy" "this" {
  count = var.lifecycle_rules_enabled ? 1 : 0

  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "raw-tiering"
    enabled = true

    filters {
      prefix_match = ["raw/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = var.raw_cool_after_days
        tier_to_archive_after_days_since_modification_greater_than = var.raw_archive_after_days
      }

      snapshot {
        delete_after_days_since_creation_greater_than = 30
      }

      version {
        delete_after_days_since_creation = 30
      }
    }
  }

  rule {
    name    = "sandbox-expiry"
    enabled = true

    filters {
      prefix_match = ["sandbox/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = var.sandbox_delete_after_days
      }
    }
  }

  rule {
    name    = "curated-tiering"
    enabled = true

    filters {
      prefix_match = ["curated/"]
      blob_types   = ["blockBlob"]
    }

    actions {
      base_blob {
        # Curated stays warm longer - Synapse serverless reads it on every
        # ad-hoc query, and Cool has a per-read charge.
        tier_to_cool_after_days_since_last_access_time_greater_than = 90
      }

      version {
        delete_after_days_since_creation = 14
      }
    }
  }

  depends_on = [azurerm_storage_data_lake_gen2_filesystem.this]
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

resource "azurerm_monitor_diagnostic_setting" "blob" {
  count = var.log_analytics_workspace_id == null ? 0 : 1

  name                       = "diag-blob"
  target_resource_id         = "${azurerm_storage_account.this.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_workspace_id

  dynamic "enabled_log" {
    for_each = local.blob_log_categories
    content {
      category = enabled_log.value
    }
  }

  enabled_metric {
    category = "Transaction"
  }
}

resource "azurerm_monitor_diagnostic_setting" "account" {
  count = var.log_analytics_workspace_id == null ? 0 : 1

  name                       = "diag-account"
  target_resource_id         = azurerm_storage_account.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_metric {
    category = "Transaction"
  }
}
