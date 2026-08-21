# ---------------------------------------------------------------------------
# infra/terraform/envs/dev/dev.tfvars
#
#   terraform plan -var-file=envs/dev/dev.tfvars
#
# DEV is the only Git-connected environment and the only one where humans are
# expected to author directly in ADF Studio and Synapse Studio. Everything else
# receives artifacts exclusively from the pipeline.
#
# Cost posture: everything that can auto-pause or scale to zero does.
# Rough steady-state cost with the pipelines idle is well under USD 100/month,
# dominated by private endpoints (10 x ~USD 7.30) - see docs/13-cost.md.
# ---------------------------------------------------------------------------

environment    = "dev"
project        = "edwtaxi"
location       = "eastus"
location_short = "eus"

# From: cd bootstrap && terraform output -raw 'tfvars_fragments["dev"]'
subscription_id = "424d0f78-5980-4d31-98ec-624616db8e74"
tenant_id       = "eabcb629-4b15-4995-9e10-86623c1e2e77"

sql_aad_admin_login         = "sg-edwtaxi-sqladmin-dev"
sql_aad_admin_object_id     = "11f26471-3aa7-40f4-9ead-f2cd8fcf68a5"
synapse_aad_admin_login     = "sg-edwtaxi-synapseadmin-dev"
synapse_aad_admin_object_id = "cf3de544-066c-4ca4-8252-6ec35de4e5b2"

# ---------------------------------------------------------------------------
# Networking - peering to the existing self-hosted runner VNet
# ---------------------------------------------------------------------------
#
# Runner VNet, as it exists today:
#
#   name          vnet-eastus-1
#   resource grp  rg-github-runner-eus
#   region        eastus                    <- why this environment is eastus too
#   address space 172.16.0.0/16
#   subnets       snet-eastus-1      172.16.0.0/24   (NAT gateway attached)
#                 AzureBastionSubnet 172.16.1.0/26
#   custom DNS    none -> Azure-provided DNS, so zone links work directly
#   peerings      none
#   NAT egress    48.195.137.225
#
# REGION. The runner is in eastus, so these environments are in eastus. Peering
# across regions does work (global VNet peering), but every packet between the
# runner and a private endpoint would then be billed as cross-region egress and
# carry ~15ms extra latency - on a sqlpackage publish that is thousands of round
# trips. Same-region is free and faster.
#
# ADDRESS SPACE. 10.60.0.0/24 does not overlap 172.16.0.0/16, so peering is
# clean. Verify before changing either side:
#   az network vnet show --ids <runner_vnet_id> --query addressSpace.addressPrefixes
#
# ---------------------------------------------------------------------------
vnet_address_space              = ["10.60.0.0/24"]
subnet_private_endpoints_prefix = "10.60.0.0/26"

# Not used while deploy_bastion = false, but reserved so the range is not
# re-used by something else later.
subnet_bastion_prefix = "10.60.0.64/26"

# The runner VNet already has an AzureBastionSubnet (172.16.1.0/26). If a
# Bastion host is deployed there on the STANDARD sku, it can reach VMs in this
# peered VNet and a second Bastion here is pure waste. Basic sku cannot do
# cross-VNet, in which case set this true when you need break-glass access.
deploy_bastion = false

runner_vnet_id = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-github-runner-eus/providers/Microsoft.Network/virtualNetworks/vnet-eastus-1"

# Creates BOTH directions. Azure peering is not implicit - one direction alone
# sits in state "Initiated" and carries no traffic. Requires the deployment
# identity to hold Network Contributor on vnet-eastus-1 as well as here; see
# docs/05-runner-connectivity.md#permissions-terraform-needs-on-your-runner-vnet
peer_runner_vnet = true

# Links all nine privatelink.* zones to vnet-eastus-1. This is the step that
# makes sqlpackage, azure.synapse.tools and the serverless DDL work at all.
#
# CAVEAT for this subscription: privatelink.database.windows.net (in rg
# Infrastructure) and privatelink.vaultcore.azure.net (in rg rg-github-runner)
# ALREADY EXIST, linked to other VNets - Infrastructure-vnet and
# gh-runner-01VNET respectively. That is fine: a zone name may exist in several
# resource groups, and vnet-eastus-1 is currently linked to neither.
#
# But a VNet can be linked to only ONE zone of a given name. If somebody later
# links vnet-eastus-1 to the Infrastructure copy of
# privatelink.database.windows.net, that link wins and this platform's SQL
# server stops resolving privately - silently, with connections timing out.
#
# If you would rather reuse the existing zones than create new ones, set
# create_private_dns_zones = false and supply existing_private_dns_zone_ids for
# all nine. See docs/04-networking.md#central-dns
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

# Deployment identity for this environment (bootstrap: deploy_principal_ids).
deployer_principal_id = "73eb8ae2-62c8-44a2-aef6-a44361fdbcb9"

# ---------------------------------------------------------------------------
# Pinned so a rebuild does not depend on a previous environment finishing its
# teardown.
#
# Deleting a managed-VNet Synapse workspace routinely takes 30-60 minutes, and
# the workspace NAME is reserved for the whole of it. With the suffix left
# random-but-held-in-state, a destroy/rebuild cycle reuses the same name and
# blocks on that teardown - which stalled this environment for 40 minutes with
# nothing to do but wait, since Azure puts a deny assignment on the managed
# resource group so you cannot help it along.
#
# Pinning also makes names reproducible, which is worth having anyway: if you
# lose Terraform state you need this value to import rather than recreate.
# ---------------------------------------------------------------------------
name_suffix = "65ri"
