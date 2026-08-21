output "server_id" {
  description = "Logical server resource ID."
  value       = azurerm_mssql_server.this.id
}

output "server_name" {
  description = "Logical server name (without the .database.windows.net suffix)."
  value       = azurerm_mssql_server.this.name
}

output "server_fqdn" {
  description = <<-EOT
    Fully qualified server name, e.g. sql-edwtaxi-dev-ab12.database.windows.net

    Used in three places:
      1. ADF linked service LS_AzureSql_Edw (via the config CSV)
      2. sqlpackage /TargetServerName in .github/workflows/sql-cd.yml
      3. The publish profiles in src/sql/EdwTaxi.Database/Properties/

    With public access disabled this name resolves - from a VNet linked to
    privatelink.database.windows.net - to the private endpoint's IP.
  EOT
  value       = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "database_id" {
  value       = azurerm_mssql_database.this.id
  description = "Database resource ID."
}

output "database_name" {
  value       = azurerm_mssql_database.this.name
  description = "Database name."
}

output "principal_id" {
  description = "System-assigned managed identity of the logical server. Needs Storage Blob Data Contributor on the lake for auditing to work."
  value       = azurerm_mssql_server.this.identity[0].principal_id
}

output "admin_password" {
  description = "Randomly generated SQL admin password, or null under Entra-only authentication. Written to Key Vault by the calling module - never printed."
  value       = try(random_password.sql_admin[0].result, null)
  sensitive   = true
}

output "connection_string_adonet" {
  description = "ADO.NET connection string using Entra (Active Directory Default) auth. Handy for local SSMS/Azure Data Studio testing from inside the VNet."
  value       = "Server=tcp:${azurerm_mssql_server.this.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.this.name};Encrypt=True;TrustServerCertificate=False;Authentication=Active Directory Default;"
}
