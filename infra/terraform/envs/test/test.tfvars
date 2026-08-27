# ---------------------------------------------------------------------------
# infra/terraform/envs/test/test.tfvars
#
# TEST is a production rehearsal. Its job is to prove that the artifacts
# promoted out of dev deploy cleanly against an environment that no human has
# hand-edited. Sizing stays cheap; SHAPE matches prod.
#
# The things that differ from prod are deliberate and listed in
# docs/09-cicd-workflows.md#environment-parity.
# ---------------------------------------------------------------------------

environment    = "test"
project        = "edwtaxi"
location       = "eastus"
location_short = "eus"

subscription_id = "424d0f78-5980-4d31-98ec-624616db8e74"
tenant_id       = "eabcb629-4b15-4995-9e10-86623c1e2e77"

sql_aad_admin_login         = "sg-edwtaxi-sqladmin-test"
sql_aad_admin_object_id     = "954ca8b4-0f1f-48a5-bea8-9598b6feca6e"
synapse_aad_admin_login     = "sg-edwtaxi-synapseadmin-test"
synapse_aad_admin_object_id = "b70bea72-226a-4384-a31e-60c6c93e1574"

# ---------------------------------------------------------------------------
# Networking - a different /24, still peered to the same runner VNet.
# ---------------------------------------------------------------------------

vnet_address_space              = ["10.61.0.0/24"]
subnet_private_endpoints_prefix = "10.61.0.0/26"
subnet_bastion_prefix           = "10.61.0.64/26"
deploy_bastion                  = false

runner_vnet_id                  = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-github-runner-eus/providers/Microsoft.Network/virtualNetworks/vnet-eastus-1"
peer_runner_vnet                = true
link_private_dns_to_runner_vnet = true

# ---------------------------------------------------------------------------
# Storage - ZRS so that the replication behaviour matches prod. Lifecycle
# windows match prod too, because "the archive tier broke our rebuild" is
# exactly the class of problem test exists to catch.
# ---------------------------------------------------------------------------

storage_replication_type  = "ZRS"
storage_lifecycle_enabled = true
raw_cool_after_days       = 30
raw_archive_after_days    = 180

create_data_lake_directories = true

key_vault_purge_protection_enabled = true

# ---------------------------------------------------------------------------
# Data Factory - NO Git integration. Test runs in live mode and receives
# artifacts only from .github/workflows/adf-cd.yml.
# ---------------------------------------------------------------------------

adf_ir_time_to_live_min              = 15
adf_ir_core_count                    = 8
adf_deploy_factory_private_endpoints = true
adf_github_configuration             = null

synapse_data_exfiltration_protection_enabled = false
synapse_deploy_private_link_hub              = false
auto_approve_managed_private_endpoints       = true

# ---------------------------------------------------------------------------
# Azure SQL - still serverless, but with a longer auto-pause so that a test run
# kicked off at 09:00 does not pay the cold-start penalty on every activity.
# ---------------------------------------------------------------------------

sql_database_name               = "edw"
sql_sku_name                    = "GP_S_Gen5_2"
sql_max_size_gb                 = 64
sql_auto_pause_delay_in_minutes = 360
sql_min_capacity                = 1
sql_zone_redundant              = false
sql_pitr_retention_days         = 7
sql_entra_only_authentication   = true
sql_enable_threat_detection     = false

log_retention_in_days = 30
log_daily_quota_gb    = 5

alert_email_receivers = {
  # platform = "data-platform@your-org.com"
}

pipeline_sla_minutes                   = 120
serverless_data_processed_gb_threshold = 100

tags = {
  cost-center = "FIN-1234"
  owner       = "data-platform@your-org.com"
  criticality = "medium"
}

# Deployment identity for this environment (bootstrap: deploy_principal_ids).
deployer_principal_id = "3a900958-36f7-45bc-b000-b37a919fb984"

# ---------------------------------------------------------------------------
# PRIVATE DNS: SHARED, NOT PER-ENVIRONMENT.
#
# A virtual network can hold exactly ONE link per zone namespace. dev creates
# the nine privatelink zones and links vnet-eastus-1 - the runner - to all of
# them. When this environment tried to create its own copies and link the same
# runner, Azure refused:
#
#   A virtual network cannot be linked to multiple zones with overlapping
#   namespaces.
#
# and everything that resolves privately failed behind it - the Key Vault
# data-plane reads in this apply came back as connection timeouts naming the
# vault, not DNS.
#
# So test and prod consume the zones dev created rather than creating their
# own. Their private endpoints register their own A records in those shared
# zones, which is what a central connectivity subscription would do - see
# docs/04-networking.md#central-dns. The zones living in a resource group named
# for dev is the wart: they are shared infrastructure, and dev happens to have
# built them first. Moving them to their own resource group is the tidier end
# state and needs a migration, not an edit.
# ---------------------------------------------------------------------------

create_private_dns_zones = false

existing_private_dns_zone_ids = {
  "privatelink.adf.azure.com" = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-edwtaxi-dev-eus-2/providers/Microsoft.Network/privateDnsZones/privatelink.adf.azure.com"
  "privatelink.azuresynapse.net" = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-edwtaxi-dev-eus-2/providers/Microsoft.Network/privateDnsZones/privatelink.azuresynapse.net"
  "privatelink.blob.core.windows.net" = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-edwtaxi-dev-eus-2/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
  "privatelink.database.windows.net" = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-edwtaxi-dev-eus-2/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net"
  "privatelink.datafactory.azure.net" = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-edwtaxi-dev-eus-2/providers/Microsoft.Network/privateDnsZones/privatelink.datafactory.azure.net"
  "privatelink.dev.azuresynapse.net" = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-edwtaxi-dev-eus-2/providers/Microsoft.Network/privateDnsZones/privatelink.dev.azuresynapse.net"
  "privatelink.dfs.core.windows.net" = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-edwtaxi-dev-eus-2/providers/Microsoft.Network/privateDnsZones/privatelink.dfs.core.windows.net"
  "privatelink.sql.azuresynapse.net" = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-edwtaxi-dev-eus-2/providers/Microsoft.Network/privateDnsZones/privatelink.sql.azuresynapse.net"
  "privatelink.vaultcore.azure.net" = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-edwtaxi-dev-eus-2/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net"
}
