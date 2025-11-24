output "private_endpoint_id" {
  value = azurerm_private_endpoint.kv_pe.id
}

output "vnet_id" {
  value = azurerm_virtual_network.vnet.id
}

