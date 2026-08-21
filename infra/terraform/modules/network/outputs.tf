# ---------------------------------------------------------------------------
# modules/network/outputs.tf
# ---------------------------------------------------------------------------

output "vnet_id" {
  description = "Resource ID of the EDW spoke VNet."
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Name of the EDW spoke VNet."
  value       = azurerm_virtual_network.this.name
}

output "private_endpoint_subnet_id" {
  description = "Subnet that every private endpoint in this platform is created in. Passed to the storage, sql, synapse and datafactory modules."
  value       = azurerm_subnet.private_endpoints.id
}

output "private_dns_zone_ids" {
  description = <<-EOT
    Map of zone name -> resource ID, e.g.
      "privatelink.database.windows.net" = "/subscriptions/.../privateDnsZones/privatelink.database.windows.net"

    Downstream modules index this map when building their
    `private_dns_zone_group` blocks. Using a map rather than nine separate
    outputs means adding a tenth zone touches exactly one place.
  EOT
  value       = local.private_dns_zone_ids
}

output "private_dns_zone_names" {
  description = "The zone names this module expects to exist, with a note on what each one is for. Useful when create_private_dns_zones = false and you need to tell a central networking team exactly which zones to link."
  value       = local.private_dns_zones
}

output "runner_peering_enabled" {
  description = "Whether Terraform created the bidirectional peering to the runner VNet. False means you are responsible for connectivity."
  value       = local.do_peer
}

output "runner_vnet_dns_linked" {
  description = "Whether the privatelink zones were linked to the runner VNet. If false, self-hosted runners will resolve public IPs unless your own DNS forwards these zones."
  value       = var.runner_vnet_id != null && var.link_private_dns_to_runner_vnet && var.create_private_dns_zones
}

output "bastion_id" {
  description = "Bastion host resource ID, or null when deploy_bastion = false."
  value       = try(azurerm_bastion_host.this[0].id, null)
}
