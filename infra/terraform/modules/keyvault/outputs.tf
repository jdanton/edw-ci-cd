output "id" {
  description = "Key Vault resource ID."
  value       = azurerm_key_vault.this.id
}

output "name" {
  description = "Key Vault name. Goes into the ADF linked service LS_KeyVault via the config CSV."
  value       = azurerm_key_vault.this.name
}

output "vault_uri" {
  description = "https://<name>.vault.azure.net/ - the baseUrl property of the ADF AzureKeyVault linked service."
  value       = azurerm_key_vault.this.vault_uri
}

output "secret_names" {
  description = "Secrets seeded by Terraform."
  value       = keys(var.secrets)
}
