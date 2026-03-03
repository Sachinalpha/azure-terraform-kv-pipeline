variable "resource_group_name" {
  description = "2 The name of the resource group where the key vault will be created"
  type        = string
}
variable "location" {
  description = "Specifies the supported Azure location where the key vault exists. If not provided, it defaults to the location of the specified resource group."
  type        = string
  default     = ""
  nullable    = false
}
variable "tenant_id" {
  description = "The Tenand ID where the key vault will be deployed"
  type        = string
}
variable "key_vault_name" {
  description = "Specifies the name of key vault"
  type        = string
}
variable "private_endpoint_name" {
  description = "Specifies the name of the private endpoint for the key vault"
  type        = string
}
variable "private_endpoint_subresources" {
  description = "The subresource details used for the Private endpoint creation"
  type        = string
  default     = "Vault"
}
variable "shared_subnet_name" {
  description = "The name of the subnet used for deploying private endpoint resources"
  type        = string
}
variable "vnet_name" {
  description = "The Tenand ID where the key vault will be deployed"
  type        = string
}
variable "vnet_rg" {
  description = "The Tenand ID where the key vault will be deployed"
  type        = string
}
