# ---------------------------------------------------------------------------
# infra/terraform/outputs.tf
#
# These outputs are not decoration - they are the contract between the
# infrastructure layer and everything downstream:
#
#   scripts/New-DeploymentConfig.ps1    reads `deployment_config` and renders
#                                       src/adf/deployment/config-<env>.csv and
#                                       src/synapse/deployment/config-<env>.csv
#
#   scripts/Deploy-ServerlessSql.ps1    reads `serverless_deployment_context`
#                                       for endpoints and abfss:// locations
#
#   .github/workflows/sql-cd.yml        reads `sql_server_fqdn` for sqlpackage
#
# Renaming an output here breaks a deployment script. Grep before you edit.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------

output "environment" {
  description = "Environment this state file represents."
  value       = var.environment
}

output "resource_group_name" {
  description = "Resource group containing the whole environment."
  value       = azurerm_resource_group.this.name
}

output "location" {
  value       = azurerm_resource_group.this.location
  description = "Azure region."
}

output "name_suffix" {
  description = "The random (or fixed) suffix used for globally-unique names. Record this: if you lose Terraform state, you need it to import rather than recreate."
  value       = local.suffix
}

# ---------------------------------------------------------------------------
# Lake
# ---------------------------------------------------------------------------

output "storage_account_name" {
  value       = module.storage.name
  description = "ADLS Gen2 account name."
}

output "lake_dfs_endpoint" {
  description = "https://<account>.dfs.core.windows.net/ - the url property of the ADF AzureBlobFS linked service."
  value       = module.storage.dfs_endpoint
}

output "lake_abfss_uris" {
  description = "Per-filesystem abfss:// URIs. Stamped into the Synapse serverless EXTERNAL DATA SOURCE definitions."
  value       = module.storage.abfss_uris
}

# ---------------------------------------------------------------------------
# Key Vault
# ---------------------------------------------------------------------------

output "key_vault_name" {
  value       = module.keyvault.name
  description = "Key Vault name."
}

output "key_vault_uri" {
  value       = module.keyvault.vault_uri
  description = "Vault base URL - the baseUrl property of the ADF AzureKeyVault linked service."
}

# ---------------------------------------------------------------------------
# Data Factory
# ---------------------------------------------------------------------------

output "data_factory_name" {
  description = "The -DataFactoryName argument to Publish-AdfV2FromJson."
  value       = module.datafactory.name
}

output "data_factory_principal_id" {
  description = <<-EOT
    ADF managed identity object ID.

    Needed OUTSIDE Terraform, twice:
      1. src/sql/Scripts/PostDeploy/030_ServicePrincipals.sql creates a
         contained user for this identity in Azure SQL.
      2. src/synapse/serverless/090_permissions.sql creates a login and user
         for it in the serverless database.

    Azure RBAC cannot do either - SQL keeps its own principal store.
  EOT
  value       = module.datafactory.principal_id
}

output "data_factory_ir_name" {
  description = "Managed-VNet integration runtime name. Every linked service in src/adf/ pins this in connectVia."
  value       = module.datafactory.managed_vnet_ir_name
}

output "data_factory_studio_url" {
  value       = module.datafactory.studio_url
  description = "Deep link to ADF Studio."
}

# ---------------------------------------------------------------------------
# Synapse
# ---------------------------------------------------------------------------

output "synapse_workspace_name" {
  description = "The -WorkspaceName argument to Publish-SynapseFromJson."
  value       = module.synapse.name
}

output "synapse_serverless_endpoint" {
  description = "<ws>-ondemand.sql.azuresynapse.net. Target for scripts/Deploy-ServerlessSql.ps1 and for the ADF linked service LS_Synapse_Serverless."
  value       = module.synapse.serverless_sql_endpoint
}

output "synapse_dev_endpoint" {
  description = "https://<ws>.dev.azuresynapse.net. What azure.synapse.tools connects to. Must resolve to a private IP from your runner."
  value       = module.synapse.dev_endpoint
}

output "synapse_principal_id" {
  description = "Synapse workspace managed identity. This is what the serverless DATABASE SCOPED CREDENTIAL 'Managed Identity' resolves to when reading the lake."
  value       = module.synapse.principal_id
}

# ---------------------------------------------------------------------------
# Azure SQL
# ---------------------------------------------------------------------------

output "sql_server_name" {
  value       = module.sql.server_name
  description = "Logical server short name."
}

output "sql_server_fqdn" {
  description = "Full server name for sqlpackage /TargetServerName and for the ADF linked service LS_AzureSql_Edw."
  value       = module.sql.server_fqdn
}

output "sql_database_name" {
  value       = module.sql.database_name
  description = "Serving database name."
}

output "sql_connection_string" {
  description = "ADO.NET connection string with Entra auth, for local testing from inside the VNet."
  value       = module.sql.connection_string_adonet
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

output "log_analytics_workspace_id" {
  value       = module.monitoring.workspace_id
  description = "Log Analytics workspace resource ID."
}

output "log_analytics_customer_id" {
  value       = module.monitoring.workspace_customer_id
  description = "Workspace GUID for the Log Analytics query API."
}

# ---------------------------------------------------------------------------
# Connectivity self-check
#
# Surfaced as first-class outputs because these two booleans are the single
# most common cause of a green `terraform apply` followed by a red deployment.
# ---------------------------------------------------------------------------

output "runner_peering_enabled" {
  description = "True if Terraform created the bidirectional peering to your runner VNet. If false, verify connectivity yourself before running any data-plane deployment."
  value       = module.network.runner_peering_enabled
}

output "runner_vnet_dns_linked" {
  description = "True if the privatelink.* zones are linked to your runner VNet. If false, your runners will resolve PUBLIC IPs for Synapse and Azure SQL, and every deployment will hang until it times out."
  value       = module.network.runner_vnet_dns_linked
}

output "required_private_dns_zones" {
  description = "The zones this platform depends on, with the reason for each. Hand this to your networking team when create_private_dns_zones = false."
  value       = module.network.private_dns_zone_names
}

# ---------------------------------------------------------------------------
# Consolidated bundles for the deployment scripts
# ---------------------------------------------------------------------------

output "deployment_config" {
  description = <<-EOT
    Everything scripts/New-DeploymentConfig.ps1 needs to render the
    azure.datafactory.tools and azure.synapse.tools config CSVs for this
    environment.

    Consume it with:
      terraform output -json deployment_config | ConvertFrom-Json
  EOT
  value = {
    environment       = var.environment
    resourceGroupName = azurerm_resource_group.this.name
    location          = azurerm_resource_group.this.location
    subscriptionId    = var.subscription_id

    dataFactoryName        = module.datafactory.name
    dataFactoryIrName      = module.datafactory.managed_vnet_ir_name
    dataFactoryPrincipalId = module.datafactory.principal_id

    synapseWorkspaceName      = module.synapse.name
    synapseServerlessEndpoint = module.synapse.serverless_sql_endpoint
    synapseDevEndpoint        = module.synapse.dev_endpoint
    synapsePrincipalId        = module.synapse.principal_id
    synapseServerlessDatabase = "edw_lake"

    sqlServerFqdn   = module.sql.server_fqdn
    sqlDatabaseName = module.sql.database_name

    storageAccountName = module.storage.name
    lakeDfsEndpoint    = module.storage.dfs_endpoint
    lakeBlobEndpoint   = module.storage.blob_endpoint
    lakeAbfssUris      = module.storage.abfss_uris

    keyVaultName = module.keyvault.name
    keyVaultUri  = module.keyvault.vault_uri

    # The public NYC Taxi source. Identical in every environment - it is
    # included so that the config CSV has a single, complete picture of every
    # linked service endpoint rather than some in code and some in config.
    openDatasetsBlobEndpoint = "https://azureopendatastorage.blob.core.windows.net"
    openDatasetsContainer    = "nyctlc"
  }
}

output "serverless_deployment_context" {
  description = "Arguments for scripts/Deploy-ServerlessSql.ps1: which endpoint to connect to, which database to create, and where the lake layers live."
  value = {
    serverlessEndpoint = module.synapse.serverless_sql_endpoint
    databaseName       = "edw_lake"
    workspaceName      = module.synapse.name
    rawLocation        = module.storage.abfss_uris["raw"]
    curatedLocation    = module.storage.abfss_uris["curated"]
    sandboxLocation    = module.storage.abfss_uris["sandbox"]
    dataFactoryName    = module.datafactory.name
    synapseAdminGroup  = var.synapse_aad_admin_login
  }
}
