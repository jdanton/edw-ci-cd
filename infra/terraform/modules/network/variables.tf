# ---------------------------------------------------------------------------
# modules/network/variables.tf
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Naming prefix, e.g. \"edwtaxi-dev\"."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that will contain the VNet and Private DNS zones."
  type        = string
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "address_space" {
  description = "VNet address space. A /24 is plenty: the only things in it are private endpoints, which consume one IP each."
  type        = list(string)
}

variable "subnet_private_endpoints_prefix" {
  description = "CIDR for the private endpoint subnet. Sized for ~50 endpoints; this template creates about 10."
  type        = string
}

variable "subnet_bastion_prefix" {
  description = "CIDR for AzureBastionSubnet. Must be at least /26. Set to null to skip Bastion."
  type        = string
  default     = null
}

variable "deploy_bastion" {
  description = "Deploy an Azure Bastion host for break-glass access to the private data plane from the portal. Costs roughly USD 140/month for the Basic SKU, so it defaults off; docs/05-runner-connectivity.md explains when you want it."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Connectivity to the pre-existing self-hosted GitHub Actions runner VNet
#
# This template assumes you already run self-hosted runners inside a VNet -
# they are mandatory here, because every data-plane endpoint (Synapse Dev API,
# Synapse serverless SQL, Azure SQL TDS, ADLS dfs) has public access disabled.
#
# Three things must be true for a runner to deploy into this platform:
#   1. Network reachability   -> VNet peering (or the runner lives in this VNet)
#   2. Name resolution        -> Private DNS zone links to the runner's VNet
#   3. Identity               -> the OIDC federated SP from bootstrap/
#
# (2) is the one that silently bites: without a zone link the runner resolves
# `mysql.database.windows.net` to the PUBLIC IP, gets a TCP timeout, and the
# error message says nothing about DNS.
# ---------------------------------------------------------------------------

variable "runner_vnet_id" {
  description = <<-EOT
    Resource ID of the VNet your self-hosted GitHub Actions runners live in.

    Set to null only if the runners are inside THIS VNet already (in which case
    supply `runner_subnet_id` instead and skip peering), or if peering and DNS
    are managed by a separate connectivity subscription.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.runner_vnet_id == null || can(regex("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Network/virtualNetworks/[^/]+$", var.runner_vnet_id))
    error_message = "runner_vnet_id must be a full virtualNetworks resource ID."
  }
}

variable "peer_runner_vnet" {
  description = <<-EOT
    Create a bidirectional VNet peering between this VNet and `runner_vnet_id`.

    Requires the deployment identity to hold Network Contributor on BOTH VNets -
    peering is not one-sided. Set false when your hub/spoke topology already
    routes between them, or when the peering is owned by a network team.
  EOT
  type        = bool
  default     = true
}

variable "link_private_dns_to_runner_vnet" {
  description = <<-EOT
    Link every privatelink.* zone created here to the runner VNet.

    Leave true unless the runner VNet uses custom DNS servers or an Azure DNS
    Private Resolver, in which case forward the privatelink zones there instead
    and set this to false. See docs/05-runner-connectivity.md.
  EOT
  type        = bool
  default     = true
}

variable "additional_dns_link_vnet_ids" {
  description = "Extra VNet IDs to link the Private DNS zones to - e.g. a jumpbox VNet, or an on-premises-connected hub. Peering is NOT created for these."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Central DNS escape hatch
# ---------------------------------------------------------------------------

variable "create_private_dns_zones" {
  description = <<-EOT
    Create the privatelink.* Private DNS zones in this resource group.

    Set to false in organisations where a central connectivity subscription owns
    all privatelink zones (very common, usually enforced by an Azure Policy
    DeployIfNotExists on privateDnsZoneGroups). Then supply
    `existing_private_dns_zone_ids` so the private endpoints created by the other
    modules still get their A records registered in the right place.
  EOT
  type        = bool
  default     = true
}

variable "existing_private_dns_zone_ids" {
  description = "Map of zone name -> existing Private DNS zone resource ID. Only read when create_private_dns_zones = false. Keys must match the zone names in local.private_dns_zones (see main.tf)."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
