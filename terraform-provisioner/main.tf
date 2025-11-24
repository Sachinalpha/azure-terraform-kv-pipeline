# Get current Azure client info
data "azurerm_client_config" "current" {}

# Existing resource group
data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# Existing Key Vault
data "azurerm_key_vault" "kv" {
  name                = var.key_vault_name
  resource_group_name = var.resource_group_name
}

# 1. Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.resource_group_name}-vnet"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = var.resource_group_name
  address_space       = ["10.0.0.0/16"]
}

# 2. Subnet for Private Endpoint (removed unsupported argument)
resource "azurerm_subnet" "private" {
  name                 = "private-subnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

# 3. Update Key Vault (tags)
resource "azurerm_key_vault" "kv_update" {
  name                = data.azurerm_key_vault.kv.name
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  tags = {
    environment = "prod"
    owner       = "platform-team"
  }
}

# 4. Access Policies (fixed capitalization)
resource "azurerm_key_vault_access_policy" "policy" {
  key_vault_id = data.azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = var.app_object_id

  secret_permissions = ["Get", "Set", "List"]
}

# 5. Key Rotation Policy (added key_opts)
resource "azurerm_key_vault_key" "rotate" {
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
}

# 6. Private Endpoint
resource "azurerm_private_endpoint" "kv_pe" {
  name                = "${var.key_vault_name}-pe"
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = var.resource_group_name
  subnet_id           = azurerm_subnet.private.id

  private_service_connection {
    name                           = "kvprivatelink"
    private_connection_resource_id = data.azurerm_key_vault.kv.id
    subresource_names              = ["vault"]
  }
}


