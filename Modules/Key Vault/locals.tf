locals {
  effective_location = var.location != "" ? var.location : data.azurerm_resource_group.current.location
}
