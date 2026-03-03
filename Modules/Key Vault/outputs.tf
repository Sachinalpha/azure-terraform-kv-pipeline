output "key_vault_name" {
  description = "Name of the key vault"
  value       = azurerm_key_vault.kvault.name
}
output "key_vault_id" {
  description = "The Azure Resource ID of the key vault"
  value       = azurerm_key_vault.kvault.id
}
output "private_endpoint_name" {
  description = "Name of the private endpoint created for the key vault"
  value       = azurerm_private_endpoint.private_endpoint.name
}
output "private_endpoint_id" {
  description = "The Azure Resource ID of the private endpoint created for the key vault"
  value       = azurerm_private_endpoint.private_endpoint.id
}
