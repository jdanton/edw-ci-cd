# ---------------------------------------------------------------------------
# modules/storage/outputs.tf
# ---------------------------------------------------------------------------

output "id" {
  description = "Storage account resource ID."
  value       = azurerm_storage_account.this.id
}

output "name" {
  description = "Storage account name."
  value       = azurerm_storage_account.this.name
}

output "principal_id" {
  description = "System-assigned managed identity of the storage account itself. Needed only if you adopt customer-managed keys."
  value       = azurerm_storage_account.this.identity[0].principal_id
}

output "dfs_endpoint" {
  description = <<-EOT
    Primary Data Lake (dfs) endpoint, e.g. https://stedwtaxidevab12.dfs.core.windows.net/

    This is the value that goes into the ADF linked service `LS_ADLS_Lake` via
    the azure.datafactory.tools config CSV, and into the Synapse serverless
    EXTERNAL DATA SOURCE definitions.
  EOT
  value       = azurerm_storage_account.this.primary_dfs_endpoint
}

output "dfs_host" {
  description = "Hostname only, without scheme or trailing slash - e.g. stedwtaxidevab12.dfs.core.windows.net. Convenient for building abfss:// URIs."
  value       = replace(replace(azurerm_storage_account.this.primary_dfs_endpoint, "https://", ""), "/", "")
}

output "blob_endpoint" {
  description = "Primary Blob endpoint."
  value       = azurerm_storage_account.this.primary_blob_endpoint
}

output "filesystem_names" {
  description = "The filesystems that were created."
  value       = keys(azurerm_storage_data_lake_gen2_filesystem.this)
}

output "filesystem_ids" {
  description = <<-EOT
    Map of filesystem name -> resource ID.

    The Synapse module needs `filesystem_ids[\"synapse\"]` for its mandatory
    default filesystem. Everything else indexes it when scoping a role
    assignment to a single layer rather than the whole account.
  EOT
  value       = { for k, v in azurerm_storage_data_lake_gen2_filesystem.this : k => v.id }
}

output "container_resource_ids" {
  description = "ARM-style container IDs (<account>/blobServices/default/containers/<name>), which is the scope format Azure RBAC expects when granting per-filesystem access."
  value = {
    for k in keys(var.filesystems) :
    k => "${azurerm_storage_account.this.id}/blobServices/default/containers/${k}"
  }
}

output "abfss_uris" {
  description = <<-EOT
    Ready-to-use abfss:// URIs per filesystem, e.g.
      raw = "abfss://raw@stedwtaxidevab12.dfs.core.windows.net"

    Consumed by the Synapse serverless deployment script when it stamps out
    EXTERNAL DATA SOURCE locations.
  EOT
  value = {
    for fs in keys(var.filesystems) :
    fs => "abfss://${fs}@${replace(replace(azurerm_storage_account.this.primary_dfs_endpoint, "https://", ""), "/", "")}"
  }
}
