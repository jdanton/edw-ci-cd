# ---------------------------------------------------------------------------
# infra/terraform/envs/prod/prod.tfvars
#
# PROD. Every difference from test below is a deliberate trade of money for
# resilience or of convenience for control. If you change one, write down why.
#
# Protections that live OUTSIDE this file and matter just as much:
#   * GitHub Environment "prod" with required reviewers and a wait timer
#   * The `prod` federated credential is restricted to refs/heads/main
#   * `prevent_destroy` on the storage account and database (set them once the
#     first real load has landed - see the lifecycle blocks in modules/)
#   * A resource lock, if your organisation uses them
# ---------------------------------------------------------------------------

environment    = "prod"
project        = "edwtaxi"
location       = "eastus"
location_short = "eus"

subscription_id = "424d0f78-5980-4d31-98ec-624616db8e74"
tenant_id       = "eabcb629-4b15-4995-9e10-86623c1e2e77"

sql_aad_admin_login         = "sg-edwtaxi-sqladmin-prod"
sql_aad_admin_object_id     = "fc5adbcc-e53c-474e-b71d-986bd431c569"
synapse_aad_admin_login     = "sg-edwtaxi-synapseadmin-prod"
synapse_aad_admin_object_id = "3f6a3573-16f4-4f3b-9d18-3a0a68d42b2f"

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

vnet_address_space              = ["10.62.0.0/24"]
subnet_private_endpoints_prefix = "10.62.0.0/26"
subnet_bastion_prefix           = "10.62.0.64/26"

# The runner VNet (vnet-eastus-1) already has an AzureBastionSubnet at
# 172.16.1.0/26. If a STANDARD-sku Bastion is deployed there it reaches VMs in
# this peered VNet, and a second host here is ~USD 140/month of waste. Basic sku
# cannot do cross-VNet - flip this to true if that is what you have and you need
# break-glass access to the private data plane.
deploy_bastion = false

runner_vnet_id                  = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-github-runner-eus/providers/Microsoft.Network/virtualNetworks/vnet-eastus-1"
peer_runner_vnet                = true
link_private_dns_to_runner_vnet = true

# ---------------------------------------------------------------------------
# Storage - zone-redundant, and lifecycle tuned so the curated layer (which
# Synapse serverless reads constantly) never lands in a per-read-charge tier
# unexpectedly.
# ---------------------------------------------------------------------------

storage_replication_type  = "ZRS"
storage_lifecycle_enabled = true
raw_cool_after_days       = 30
raw_archive_after_days    = 365

create_data_lake_directories = true

key_vault_purge_protection_enabled = true

# ---------------------------------------------------------------------------
# Data Factory
#
# Longer IR TTL: prod runs a chain of pipelines nightly, and paying for 30
# warm minutes is far cheaper than 20 separate 90-second managed-VNet cold
# starts inside the SLA window.
# ---------------------------------------------------------------------------

adf_ir_time_to_live_min              = 30
adf_ir_core_count                    = 16
adf_deploy_factory_private_endpoints = true
adf_github_configuration             = null

# ---------------------------------------------------------------------------
# Synapse
#
# Private Link Hub on: analysts open Studio from the corporate network, which
# routes through the peered hub rather than the public endpoint.
# ---------------------------------------------------------------------------

synapse_data_exfiltration_protection_enabled = false
synapse_deploy_private_link_hub              = true
auto_approve_managed_private_endpoints       = true

# ---------------------------------------------------------------------------
# Azure SQL
#
# PROVISIONED, not serverless. Auto-pause is wrong in prod: the first query of
# the morning would pay a 30-60 second resume, and a paused database cannot be
# the target of a scheduled load.
#
# auto_pause_delay_in_minutes and min_capacity MUST be null for provisioned
# SKUs - Azure rejects the request otherwise.
# ---------------------------------------------------------------------------

sql_database_name               = "edw"
sql_sku_name                    = "GP_Gen5_4"
sql_max_size_gb                 = 250
sql_auto_pause_delay_in_minutes = null
sql_min_capacity                = null
sql_zone_redundant              = true
sql_pitr_retention_days         = 35
sql_entra_only_authentication   = true
sql_enable_threat_detection     = true

sql_security_alert_emails = [
  # "security-ops@your-org.com",
]

# ---------------------------------------------------------------------------
# Monitoring - 90 days so a quarter-end anomaly is still investigable.
# ---------------------------------------------------------------------------

log_retention_in_days = 90
log_daily_quota_gb    = 20

alert_email_receivers = {
  # oncall   = "data-oncall@your-org.com"
  # platform = "data-platform@your-org.com"
}

alert_webhook_receivers = {
  # teams = "https://your-org.webhook.office.com/webhookb2/..."
}

# Load starts 03:00, warehouse must be ready by 06:00 -> alert at 150 minutes
# leaves a 30-minute window to intervene.
pipeline_sla_minutes                   = 150
serverless_data_processed_gb_threshold = 250

tags = {
  cost-center = "FIN-1234"
  owner       = "data-platform@your-org.com"
  criticality = "high"
  compliance  = "internal"
}
