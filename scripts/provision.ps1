param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string]$AppObjectId
)

# -----------------------------
# Check Resource Group
# -----------------------------
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($rg -eq $null) {
    Write-Host "Resource Group $ResourceGroupName does not exist!"
    exit 1
} else {
    Write-Host "Resource Group exists. Adding 'environment=prod' tag..."
    $rg.Tags["environment"] = "prod"
    Set-AzResourceGroup -Name $ResourceGroupName -Tag $rg.Tags
}

# -----------------------------
# Check Key Vault
# -----------------------------
$kv = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($kv -eq $null) {
    Write-Host "Key Vault $KeyVaultName does not exist!"
    exit 1
}

# -----------------------------
# Key Vault Access Policy
# -----------------------------
Set-AzKeyVaultAccessPolicy -VaultName $KeyVaultName `
                           -ObjectId $AppObjectId `
                           -PermissionsToSecrets @("Get","Set","List") `
                           -PermissionsToKeys @(
                               "Get","Create","Update","Delete","Sign","Verify",
                               "WrapKey","UnwrapKey","SetRotationPolicy","GetRotationPolicy"
                           )

# -----------------------------
# Key Vault Key Creation / Rotation
# -----------------------------
$key = Get-AzKeyVaultKey -VaultName $KeyVaultName -Name "app-key" -ErrorAction SilentlyContinue
if ($key -eq $null) {
    Write-Host "Creating Key Vault key 'app-key'..."
    Add-AzKeyVaultKey -VaultName $KeyVaultName -Name "app-key" `
                      -Destination "Software" `
                      -KeyType "RSA" `
                      -KeySize 2048 `
                      -KeyOps @("encrypt","decrypt","sign","verify")
} else {
    Write-Host "Key 'app-key' already exists."
}

# -----------------------------
# Virtual Network
# -----------------------------
$vnetName = "${ResourceGroupName}-vnet"
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($vnet -eq $null) {
    Write-Host "Creating Virtual Network $vnetName..."
    $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName `
                                 -Location $rg.Location -AddressPrefix "10.0.0.0/16"
}

# -----------------------------
# Subnet
# -----------------------------
$subnetName = "pe-subnet"
$subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet -ErrorAction SilentlyContinue
if ($subnet -eq $null) {
    Write-Host "Creating Subnet $subnetName..."
    Add-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix "10.0.1.0/24" -VirtualNetwork $vnet | Set-AzVirtualNetwork
}

# -----------------------------
# Private Endpoint for Key Vault
# -----------------------------
$peName = "${KeyVaultName}-pe"
$existingPE = Get-AzPrivateEndpoint -Name $peName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($existingPE -eq $null) {
    Write-Host "Creating Private Endpoint $peName..."
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
    New-AzPrivateEndpoint -Name $peName `
                          -ResourceGroupName $ResourceGroupName `
                          -Location $rg.Location `
                          -SubnetId $subnet.Id `
                          -PrivateLinkServiceConnection @(@{
                              Name = "kvprivatelink"
                              PrivateLinkServiceId = $kv.ResourceId
                              GroupIds = @("vault")
                              RequestMessage = "Auto-approved"
                          })
} else {
    Write-Host "Private Endpoint $peName already exists."
}
