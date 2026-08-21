output "id" {
  description = "Data Factory resource ID."
  value       = azurerm_data_factory.this.id
}

output "name" {
  description = "Factory name. The -DataFactoryName argument to Publish-AdfV2FromJson."
  value       = azurerm_data_factory.this.name
}

output "principal_id" {
  description = <<-EOT
    Factory system-assigned managed identity object ID.

    Everything ADF touches is authorised through this:
      * Storage Blob Data Contributor on the lake
      * Key Vault Secrets User on the vault
      * a contained database user in Azure SQL      (created by the .sqlproj
        post-deploy script - see src/sql/Scripts/PostDeploy/)
      * a login + user in the Synapse serverless database (created by
        src/synapse/serverless/090_permissions.sql)

    The last two are easy to forget: RBAC alone does not grant SQL access.
  EOT
  value       = azurerm_data_factory.this.identity[0].principal_id
}

output "tenant_id" {
  description = "Tenant of the factory's managed identity."
  value       = azurerm_data_factory.this.identity[0].tenant_id
}

output "managed_vnet_ir_name" {
  description = "Name of the managed-VNet integration runtime that artifacts reference via connectVia."
  value       = azurerm_data_factory_integration_runtime_azure.managed_vnet.name
}

output "managed_private_endpoint_names" {
  description = "Managed private endpoints created out of the factory's managed VNet."
  value       = keys(azurerm_data_factory_managed_private_endpoint.this)
}

output "studio_url" {
  description = "Deep link to ADF Studio for this factory."
  value       = "https://adf.azure.com/en/home?factory=${azurerm_data_factory.this.id}"
}
