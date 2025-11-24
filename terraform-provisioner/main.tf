data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

data "azurerm_key_vault" "kv" {
  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.resource_group_name}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = var.resource_group_name
  address_space       = ["10.0.0.0/16"]

  tags = {
    environment = "prod"
  }
}

resource "azurerm_subnet" "pe_subnet" {
  name                 = "pe-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_key_vault_access_policy" "policy" {
  key_vault_id = data.azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = var.app_object_id

  secret_permissions = ["Get", "Set", "List"]
  key_permissions = [
    "Get",
    "Create",
    "Update",
    "Delete",
    "Sign",
    "Verify",
    "WrapKey",
    "UnwrapKey",
    "SetRotationPolicy"
  ]

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      secret_permissions,
      key_permissions
    ]
  }
}

resource "azurerm_key_vault_key" "rotate" {
  depends_on = [azurerm_key_vault_access_policy.policy]

  name         = "app-key"
  key_vault_id = data.azurerm_key_vault.kv.id
  key_type     = "RSA"
  key_size     = 2048
  key_opts     = ["encrypt", "decrypt", "sign", "verify"]

  rotation_policy {
    automatic {
      time_after_creation = "P30D"
    }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      rotation_policy,
      key_opts,
      key_size
    ]
  }
}

resource "azurerm_private_endpoint" "kv_pe" {
  depends_on = [azurerm_subnet.pe_subnet]

  name                = "${var.key_vault_name}-pe"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = var.resource_group_name
  subnet_id           = azurerm_subnet.pe_subnet.id

  private_service_connection {
    name                           = "kvprivatelink"
    private_connection_resource_id = data.azurerm_key_vault.kv.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }
}
