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
  description = "Names of the secrets seeded by Terraform. Names only - never values."
  # var.secrets is sensitive, so anything derived from it inherits that mark,
  # including its KEYS. Terraform then refuses to expose it as a ROOT module
  # output without `sensitive = true` - and marking it sensitive would be
  # wrong, because a secret's name is not a secret and hiding it makes the
  # output useless for its only purpose (telling you what was created).
  #
  # nonsensitive() on the keys is the same reasoning as the for_each in
  # main.tf: the names are safe, the values never leave this module.
  #
  # This only bites when the module is validated STANDALONE, where its outputs
  # are root outputs. As a child module it inherits no such restriction, which
  # is why the root module validated cleanly while pr-validate did not.
  value = nonsensitive(keys(var.secrets))
}
