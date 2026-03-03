output "key_vault_name" {
  description = "Name of the key vault"
  value       = module.kvault.key_vault_name
}

output "key_vault_id" {
  description = "The Azure Resource ID of the key vault"
  value       = module.kvault.key_vault_id
}

output "private_endpoint_name" {
  description = "Name of the private endpoint created for the key vault"
  value       = module.kvault.private_endpoint_name
}

output "private_endpoint_id" {
  description = "The Azure Resource ID of the private endpoint created for the key vault"
  value       = module.kvault.private_endpoint_id
}
