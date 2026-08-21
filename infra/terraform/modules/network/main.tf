# ---------------------------------------------------------------------------
# modules/network/main.tf
#
# Spoke VNet for the EDW platform. It holds nothing but private endpoints (and
# optionally a Bastion host). No compute lives here: ADF and Synapse both use
# their own *managed* virtual networks, which are Microsoft-owned address space
# that we reach outbound-only via managed private endpoints.
#
#   +-------------------------------------------------------------+
#   |  Your existing runner VNet (self-hosted GH Actions runners)  |
#   |    - peered to this VNet                                     |
#   |    - linked to every privatelink.* zone below                |
#   +------------------------------+------------------------------+
#                                  | peering
#   +------------------------------v------------------------------+
#   |  vnet-edwtaxi-<env>                                          |
#   |    snet-private-endpoints                                    |
#   |      pe-adls-blob   pe-adls-dfs    pe-kv                     |
#   |      pe-sql         pe-syn-sql     pe-syn-sqlondemand        |
#   |      pe-syn-dev     pe-adf-portal  pe-adf                    |
#   +-------------------------------------------------------------+
#            ^                    ^                     ^
#            | managed PE         | managed PE          | managed PE
#      +-----+------+      +------+-------+      +------+------+
#      | ADF managed |     | Synapse mgd  |      |  (approved  |
#      |    VNet     |     |    VNet      |      |  by TF/PS)  |
#      +-------------+     +--------------+      +-------------+
#
# ---------------------------------------------------------------------------

locals {
  # ---------------------------------------------------------------------
  # Every Private DNS zone this platform needs, and why.
  #
  # Getting this list wrong is the number one cause of "it works from the
  # portal but the pipeline times out". Each private endpoint registers an A
  # record in exactly one of these zones; if the zone is missing, or not linked
  # to the *caller's* VNet, the caller resolves the public IP and hangs.
  # ---------------------------------------------------------------------
  private_dns_zones = {
    # ADLS Gen2 needs BOTH. The dfs endpoint serves the hierarchical-namespace
    # (Data Lake) API; the blob endpoint serves the flat Blob API. ADF's Parquet
    # connector and Synapse OPENROWSET use dfs; some tools still use blob.
    "privatelink.dfs.core.windows.net"  = "ADLS Gen2 - Data Lake (dfs) endpoint"
    "privatelink.blob.core.windows.net" = "ADLS Gen2 - Blob endpoint"

    # Key Vault. Note the zone is vaultcore, not vault.
    "privatelink.vaultcore.azure.net" = "Azure Key Vault"

    # Azure SQL Database (TDS 1433). sqlpackage.exe needs this resolvable from
    # the runner, or SDK-style .sqlproj deployment fails with a login timeout.
    "privatelink.database.windows.net" = "Azure SQL Database"

    # Synapse. Three separate sub-resources, two separate zones:
    #   Sql          -> <ws>.sql.azuresynapse.net          (dedicated pools)
    #   SqlOnDemand  -> <ws>-ondemand.sql.azuresynapse.net (serverless)  <-- we use this
    #   Dev          -> <ws>.dev.azuresynapse.net          (artifact/REST API)
    # azure.synapse.tools talks to the Dev endpoint. Miss this zone and
    # Publish-SynapseFromJson fails with an opaque connectivity error.
    "privatelink.sql.azuresynapse.net" = "Synapse SQL - both dedicated and serverless (Sql, SqlOnDemand)"
    "privatelink.dev.azuresynapse.net" = "Synapse artifact/development REST API (Dev) - required by azure.synapse.tools"

    # Synapse Studio itself, served through a Private Link Hub. Only needed if
    # humans must open Studio from inside the private network.
    "privatelink.azuresynapse.net" = "Synapse Studio via Private Link Hub (Web)"

    # Data Factory. Again two zones:
    #   dataFactory -> <adf>.datafactory.azure.net  (runtime / self-hosted IR)
    #   portal      -> adf.azure.com                (Studio authoring UI)
    # azure.datafactory.tools uses the ARM control plane (management.azure.com,
    # always public) so it does NOT strictly need these - but Studio does.
    "privatelink.datafactory.azure.net" = "Azure Data Factory runtime endpoint"
    "privatelink.adf.azure.com"         = "Azure Data Factory Studio (portal sub-resource)"
  }

  # Resolve zone IDs: either the ones we just created, or centrally-managed ones
  # handed in by the platform team.
  private_dns_zone_ids = var.create_private_dns_zones ? {
    for k, z in azurerm_private_dns_zone.this : k => z.id
  } : var.existing_private_dns_zone_ids

  # Parse the runner VNet ID so we can create the reverse peering.
  # /subscriptions/{0..1}/resourceGroups/{2..3}/providers/{4..5}/virtualNetworks/{6..7}
  runner_vnet_parts = var.runner_vnet_id == null ? [] : split("/", trimprefix(var.runner_vnet_id, "/"))
  runner_vnet_rg    = var.runner_vnet_id == null ? null : local.runner_vnet_parts[3]
  runner_vnet_name  = var.runner_vnet_id == null ? null : local.runner_vnet_parts[7]

  do_peer = var.runner_vnet_id != null && var.peer_runner_vnet

  # Which VNets get a Private DNS zone link.
  dns_link_vnets = merge(
    { "spoke" = azurerm_virtual_network.this.id },
    var.runner_vnet_id != null && var.link_private_dns_to_runner_vnet ? { "runner" = var.runner_vnet_id } : {},
    { for idx, id in var.additional_dns_link_vnet_ids : "extra-${idx}" => id },
  )

  # Cartesian product of (zone x vnet) - one link resource each.
  dns_links = var.create_private_dns_zones ? {
    for pair in setproduct(keys(local.private_dns_zones), keys(local.dns_link_vnets)) :
    "${pair[0]}|${pair[1]}" => {
      zone_name = pair[0]
      vnet_key  = pair[1]
      vnet_id   = local.dns_link_vnets[pair[1]]
    }
  } : {}
}

# ---------------------------------------------------------------------------
# VNet + subnets
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.address_space
  tags                = var.tags
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "snet-private-endpoints"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_private_endpoints_prefix]

  # Private endpoints are reached from peered VNets, so this subnet needs no
  # service endpoints. Network policies for private endpoints default to
  # Disabled on new subnets in recent API versions; we set it explicitly
  # because an NSG is attached below and we DO want it to apply.
  private_endpoint_network_policies = "Enabled"
}

resource "azurerm_subnet" "bastion" {
  count = var.deploy_bastion ? 1 : 0

  # The name is mandated by Azure. It cannot be anything else.
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_bastion_prefix]
}

# ---------------------------------------------------------------------------
# NSG on the private endpoint subnet
#
# Deny-by-default inbound from the internet, allow from peered/private space.
# Private endpoints honour NSGs (this has been GA since 2021), so this is a
# real control, not decoration.
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "nsg-${var.name_prefix}-pe"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_network_security_rule" "pe_allow_vnet_inbound" {
  name                        = "Allow-VirtualNetwork-Inbound"
  description                 = "Peered VNets (runners, jumpboxes) reach private endpoints. VirtualNetwork includes peered address space."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["443", "1433", "1443", "11000-11999"]
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "VirtualNetwork"
}

resource "azurerm_network_security_rule" "pe_deny_internet_inbound" {
  name                        = "Deny-Internet-Inbound"
  description                 = "Belt and braces. Private endpoints have no public IP, but an explicit deny documents intent and satisfies most CIS/NIST control mappings."
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.private_endpoints.name
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# ---------------------------------------------------------------------------
# Private DNS zones
# ---------------------------------------------------------------------------

resource "azurerm_private_dns_zone" "this" {
  for_each = var.create_private_dns_zones ? local.private_dns_zones : {}

  name                = each.key
  resource_group_name = var.resource_group_name
  tags                = merge(var.tags, { purpose = each.value })
}

# One link per (zone, VNet). The runner VNet link is the load-bearing one:
# without it, self-hosted runners resolve public IPs and every data-plane
# deployment step hangs until it times out.
resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.dns_links

  name                  = "link-${each.value.vnet_key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.value.zone_name].name
  virtual_network_id    = each.value.vnet_id

  # We never want Azure auto-registering VM records into privatelink zones.
  registration_enabled = false

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Peering to the runner VNet
#
# Both directions are required. Azure peering is not transitive and not
# implicit: creating A->B without B->A leaves the peering in state
# "Initiated" and no traffic flows.
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network_peering" "spoke_to_runner" {
  count = local.do_peer ? 1 : 0

  name                      = "peer-to-runners"
  resource_group_name       = var.resource_group_name
  virtual_network_name      = azurerm_virtual_network.this.name
  remote_virtual_network_id = var.runner_vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  # This VNet has no gateway and does not want the runner VNet's.
  allow_gateway_transit = false
  use_remote_gateways   = false
}

resource "azurerm_virtual_network_peering" "runner_to_spoke" {
  count = local.do_peer ? 1 : 0

  name                      = "peer-to-${var.name_prefix}"
  resource_group_name       = local.runner_vnet_rg
  virtual_network_name      = local.runner_vnet_name
  remote_virtual_network_id = azurerm_virtual_network.this.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

# ---------------------------------------------------------------------------
# Optional Bastion - break-glass access to Synapse Studio / ADF Studio and
# SSMS from a jumpbox when the private data plane is otherwise unreachable.
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "bastion" {
  count = var.deploy_bastion ? 1 : 0

  name                = "pip-${var.name_prefix}-bastion"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_bastion_host" "this" {
  count = var.deploy_bastion ? 1 : 0

  name                = "bas-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"
  tags                = var.tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion[0].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}
