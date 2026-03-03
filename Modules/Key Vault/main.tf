resource "azurerm_key_vault" "kvault" {
  name                            = var.key_vault_name
  location                        = local.effective_location
  resource_group_name             = var.resource_group_name
  tenant_id                       = var.tenant_id
  public_network_access_enabled   = false
  enabled_for_disk_encryption     = true
  enabled_for_template_deployment = true
  enabled_for_deployment          = false
  enable_rbac_authorization       = false # Specify to use RBAC only
  purge_protection_enabled        = true
  soft_delete_retention_days      = 90
  sku_name                        = "premium"
  lifecycle {
    create_before_destroy = true
  }
}

data "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  resource_group_name = var.vnet_rg
}


# Create private endpoint
resource "azurerm_private_endpoint" "private_endpoint" {
  name                = var.private_endpoint_name
  location            = local.effective_location
  resource_group_name = var.resource_group_name
  subnet_id           = data.azurerm_subnet.pep_subnet.id
  private_service_connection {
    name                           = replace(var.private_endpoint_name, "pep", "pec")
    private_connection_resource_id = azurerm_key_vault.kvault.id
    subresource_names              = [var.private_endpoint_subresources]
    is_manual_connection           = false
  }
  # subnet_id: when a subnet for PEP is expanded (because there we no more available IPs in the old subnet),
  #            we do not want to re-deploy the PEP - it should stay in the old/original subnet. So ignore_changes
  # private_dns_zone_group: DNS settings are auto-applied by Azure policy. We want to ignore these changes so
  #                         that the TF re-deployment (apply-apply) does not fight the settings set by the Azure policy
  lifecycle {
    ignore_changes = [
      subnet_id,
      private_dns_zone_group
    ]
  }
}

resource "terraform_data" "testing_dns_entry_for_key_pep" {
  triggers_replace = [
    azurerm_key_vault.kvault.id
  ]
  provisioner "local-exec" {
    command     = <<-EOT
      $keyname = "${var.key_vault_name}.privatelink.vaultcore.azure.net"
      Write-Host "Testing connection to $keyname on port 443"
      $connectionTest = Test-Connection -TargetName $keyname -TCPPort 443 -Quiet
      $connectionTest
      for($i=0; $i -lt 20; $i++) {
        $connectionTest = Test-Connection -TargetName $keyname -TCPPort 443 -Quiet
        if (-not $connectionTest) {
            Write-Host "Retry $($i): DNS entry is absent for $keyname sleeping 5 seconds"
            Start-Sleep -Seconds 5
        }
        else {
            $connectionTest
            Write-Host "Connection to $keyname was successful sleeping 60 seconds"
            # At this point the DNS entry is there but the Key Vault is not yet fully operating.
            # If we hit it immediately we'd get a 403 error. So we wait additional 60 seconds.
            Start-Sleep -Seconds 60
            break
        }
      }
      if (-not $connectionTest) {
        Write-Host "Private endpoint DNS entry $keyname not available after 100 seconds. Terminating..."
        exit 1
      }
      exit 0
    EOT
    interpreter = ["pwsh", "-Command"]
  }
  depends_on = [azurerm_private_endpoint.private_endpoint]
}
