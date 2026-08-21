# ---------------------------------------------------------------------------
# infra/terraform/envs/dev/dev.tfvars
#
#   terraform plan -var-file=envs/dev/dev.tfvars
#
# DEV is the only Git-connected environment and the only one where humans are
# expected to author directly in ADF Studio and Synapse Studio. Everything else
# receives artefacts exclusively from the pipeline.
#
# Cost posture: everything that can auto-pause or scale to zero does.
# Rough steady-state cost with the pipelines idle is well under USD 100/month,
# dominated by private endpoints (10 x ~USD 7.30) - see docs/13-cost.md.
# ---------------------------------------------------------------------------

environment    = "dev"
project        = "edwtaxi"
location       = "eastus2"
location_short = "eus2"

# From: cd bootstrap && terraform output -raw 'tfvars_fragments["dev"]'
subscription_id = "00000000-0000-0000-0000-000000000000"
tenant_id       = "11111111-1111-1111-1111-111111111111"

sql_aad_admin_login         = "sg-edwtaxi-sqladmin-dev"
sql_aad_admin_object_id     = "REPLACE-ME"
synapse_aad_admin_login     = "sg-edwtaxi-synapseadmin-dev"
synapse_aad_admin_object_id = "REPLACE-ME"

# ---------------------------------------------------------------------------
# Networking
#
# vnet_address_space must NOT overlap your runner VNet, or the peering fails
# with "AnotherPeeringWithOverlappingSpaceExists" / cannot be created at all.
# Check yours with:
#   az network vnet show --ids <runner_vnet_id> --query addressSpace.addressPrefixes
# ---------------------------------------------------------------------------

vnet_address_space              = ["10.60.0.0/24"]
subnet_private_endpoints_prefix = "10.60.0.0/26"
subnet_bastion_prefix           = "10.60.0.64/26"
deploy_bastion                  = false

# The VNet your self-hosted GitHub Actions runners already live in. Terraform
# peers to it and links every privatelink.* zone to it, which is what makes
# sqlpackage, azure.synapse.tools and the serverless DDL work at all.
#
#   az network vnet list --query "[].{name:name, id:id}" -o table
runner_vnet_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-github-runners/providers/Microsoft.Network/virtualNetworks/vnet-github-runners"
peer_runner_vnet                = true
link_private_dns_to_runner_vnet = true

create_private_dns_zones = true

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

storage_replication_type  = "LRS"
storage_lifecycle_enabled = true
raw_cool_after_days       = 7 # aggressive in dev - the data is disposable
raw_archive_after_days    = 30

create_data_lake_directories = true

# ---------------------------------------------------------------------------
# Key Vault
#
# Purge protection OFF in dev so `terraform destroy` followed by a rebuild can
# reuse the same vault name. With it on you would have to wait out the
# soft-delete window or pick a new suffix.
# ---------------------------------------------------------------------------

key_vault_purge_protection_enabled = false

# ---------------------------------------------------------------------------
# Data Factory
# ---------------------------------------------------------------------------

adf_ir_time_to_live_min              = 10
adf_ir_core_count                    = 8
adf_deploy_factory_private_endpoints = true

# Git integration: leave null on the first apply. Connect dev to Git ONCE via
# ADF Studio, verify it works, then uncomment this so Terraform adopts the
# configuration rather than fighting it. See docs/06-data-factory.md.
#
# adf_github_configuration = {
#   account_name       = "your-org"
#   repository_name    = "edw-ci-cd"
#   branch_name        = "main"
#   root_folder        = "/src/adf"
#   publishing_enabled = false
# }

# ---------------------------------------------------------------------------
# Synapse
#
# data_exfiltration_protection is CREATE-TIME ONLY. Leave it false in dev: with
# it on, every outbound destination needs a managed private endpoint and the
# workspace cannot be changed without a full replace.
# ---------------------------------------------------------------------------

synapse_data_exfiltration_protection_enabled = false
synapse_deploy_private_link_hub              = false
auto_approve_managed_private_endpoints       = true

# ---------------------------------------------------------------------------
# Azure SQL
#
# GP_S_Gen5_2 is serverless: it auto-pauses after an hour idle and costs
# storage only overnight. The first query after a pause takes 30-60 seconds to
# resume, which is fine in dev and would not be in prod.
# ---------------------------------------------------------------------------

sql_database_name               = "edw"
sql_sku_name                    = "GP_S_Gen5_2"
sql_max_size_gb                 = 32
sql_auto_pause_delay_in_minutes = 60
sql_min_capacity                = 0.5
sql_zone_redundant              = false
sql_pitr_retention_days         = 7
sql_entra_only_authentication   = true
sql_enable_threat_detection     = false

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------

log_retention_in_days = 30
log_daily_quota_gb    = 2

alert_email_receivers = {
  # platform = "data-platform@your-org.com"
}

pipeline_sla_minutes                   = 180
serverless_data_processed_gb_threshold = 50

tags = {
  cost-center = "FIN-1234"
  owner       = "data-platform@your-org.com"
  criticality = "low"
}
