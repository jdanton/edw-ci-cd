output "id" {
  description = "Synapse workspace resource ID."
  value       = azurerm_synapse_workspace.this.id
}

output "name" {
  description = "Workspace name. This is the -WorkspaceName argument to azure.synapse.tools' Publish-SynapseFromJson."
  value       = azurerm_synapse_workspace.this.name
}

output "principal_id" {
  description = <<-EOT
    Workspace system-assigned managed identity.

    This identity is what the serverless DATABASE SCOPED CREDENTIAL
    `WITH IDENTITY = 'Managed Identity'` resolves to. It must hold
    Storage Blob Data Contributor on the lake or every OPENROWSET and CETAS
    fails with "External table is not accessible because content of directory
    cannot be listed" - which reads like a path problem and is actually RBAC.
  EOT
  value       = azurerm_synapse_workspace.this.identity[0].principal_id
}

output "serverless_sql_endpoint" {
  description = <<-EOT
    Serverless SQL endpoint FQDN, e.g. syn-edwtaxi-dev-ab12-ondemand.sql.azuresynapse.net

    Used by:
      * scripts/Deploy-ServerlessSql.ps1  (deploys src/synapse/serverless/*.sql)
      * ADF linked service LS_Synapse_Serverless (via the config CSV)
      * analysts connecting from SSMS / Azure Data Studio
  EOT
  value       = azurerm_synapse_workspace.this.connectivity_endpoints["sqlOnDemand"]
}

output "dev_endpoint" {
  description = "Artifact/development REST endpoint, e.g. https://syn-edwtaxi-dev-ab12.dev.azuresynapse.net. This is what azure.synapse.tools connects to."
  value       = azurerm_synapse_workspace.this.connectivity_endpoints["dev"]
}

output "sql_endpoint" {
  description = "Dedicated SQL pool endpoint. Unused in this template (serverless only), exposed for completeness."
  value       = azurerm_synapse_workspace.this.connectivity_endpoints["sql"]
}

output "connectivity_endpoints" {
  description = "All endpoints Azure reports for the workspace."
  value       = azurerm_synapse_workspace.this.connectivity_endpoints
}

output "managed_private_endpoint_names" {
  description = "Managed private endpoints created out of the workspace's managed VNet."
  value       = keys(azurerm_synapse_managed_private_endpoint.this)
}

output "sql_admin_password" {
  description = "Random SQL admin password, or null under Entra-only authentication."
  value       = try(random_password.sql_admin[0].result, null)
  sensitive   = true
}

output "private_link_hub_id" {
  description = "Private Link Hub resource ID, or null."
  value       = try(azurerm_synapse_private_link_hub.this[0].id, null)
}
