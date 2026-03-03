# Get resource group location 
data "azurerm_resource_group" "current" {
  name = var.resource_group_name
}
# Get current subscription
data "azurerm_subscription" "current" {
}
# Get the subnet id for the provided subnet
data "azurerm_subnet" "pep_subnet" {
  name                 = var.shared_subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = var.vnet_rg
}
