# ---------------------------------------------------------------------------
# infra/terraform/envs/test/test.tfvars
#
# TEST is a production rehearsal. Its job is to prove that the artefacts
# promoted out of dev deploy cleanly against an environment that no human has
# hand-edited. Sizing stays cheap; SHAPE matches prod.
#
# The things that differ from prod are deliberate and listed in
# docs/09-cicd-workflows.md#environment-parity.
# ---------------------------------------------------------------------------

environment    = "test"
project        = "edwtaxi"
location       = "eastus2"
location_short = "eus2"

subscription_id = "00000000-0000-0000-0000-000000000000"
tenant_id       = "11111111-1111-1111-1111-111111111111"

sql_aad_admin_login         = "sg-edwtaxi-sqladmin-test"
sql_aad_admin_object_id     = "REPLACE-ME"
synapse_aad_admin_login     = "sg-edwtaxi-synapseadmin-test"
synapse_aad_admin_object_id = "REPLACE-ME"

# ---------------------------------------------------------------------------
# Networking - a different /24, still peered to the same runner VNet.
# ---------------------------------------------------------------------------

vnet_address_space              = ["10.61.0.0/24"]
subnet_private_endpoints_prefix = "10.61.0.0/26"
subnet_bastion_prefix           = "10.61.0.64/26"
deploy_bastion                  = false

runner_vnet_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-github-runners/providers/Microsoft.Network/virtualNetworks/vnet-github-runners"
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
# artefacts only from .github/workflows/adf-cd.yml.
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
