param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string]$AppObjectId
)

# Install Az if missing
if (-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az

# Login with Service Principal
$securePassword = ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($env:AZURE_CLIENT_ID, $securePassword)

Connect-AzAccount -ServicePrincipal `
    -Tenant $env:AZURE_TENANT_ID `
    -Credential $cred

Select-AzSubscription -SubscriptionId $env:AZURE_SUBSCRIPTION_ID

# Retry Helper
function Retry-AzGetResourceGroup {
    param([string]$Name, [int]$MaxAttempts=10, [int]$Delay=5)

    for ($i=1; $i -le $MaxAttempts; $i++) {
        $rg = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
        if ($rg) { return $rg }
        Write-Host "[$i/$MaxAttempts] Resource Group '$Name' not found. Retrying in $Delay sec..."
        Start-Sleep -Seconds $Delay
    }
    return $null
}

# Check Resource Group
$rg = Retry-AzGetResourceGroup -Name $ResourceGroupName
if (-not $rg) {
    Write-Host "Resource Group '$ResourceGroupName' does not exist after retries!"
    exit 1
}
Write-Host "Resource Group exists: $($rg.ResourceGroupName)"

# Check Key Vault
$kv = Get-AzKeyVault -VaultName $KeyVaultName `
                     -ResourceGroupName $ResourceGroupName `
                     -ErrorAction SilentlyContinue

if (-not $kv) {
    Write-Host "Key Vault '$KeyVaultName' does not exist!"
    exit 1
}
Write-Host "Key Vault exists: $KeyVaultName"

# Key Vault Access Policy (Bypass Graph)
Write-Host "Setting Access Policy (bypassing validation)..."

Set-AzKeyVaultAccessPolicy -VaultName $KeyVaultName `
                           -ObjectId $AppObjectId `
                           -PermissionsToSecrets @("Get","Set","List") `
                           -PermissionsToKeys @(
                               "Get","Create","Update","Delete",
                               "Sign","Verify","WrapKey","UnwrapKey",
                               "SetRotationPolicy","GetRotationPolicy"
                           ) `
                           -BypassObjectIdValidation `
                           -ErrorAction Stop

Write-Host "Access policy applied"

# Key Creation
$key = Get-AzKeyVaultKey -VaultName $KeyVaultName -Name "app-key" -ErrorAction SilentlyContinue

if (-not $key) {
    Write-Host "Creating Key Vault key 'app-key'..."
    Add-AzKeyVaultKey -VaultName $KeyVaultName -Name "app-key" `
                      -Destination "Software" `
                      -KeyType "RSA" `
                      -KeySize 2048 `
                      -KeyOps @("encrypt","decrypt","sign","verify")
} else {
    Write-Host "Key 'app-key' already exists."
}

# --- Rotation Policy ---
$keyRotationPolicy = New-AzKeyVaultKeyRotationPolicy `
    -ExpiresIn "P90D" `
    -NotifyBeforeExpiry "P30D"

Set-AzKeyVaultKeyRotationPolicy -VaultName $KeyVaultName `
                                -Name "app-key" `
                                -RotationPolicy $keyRotationPolicy

Write-Host "Rotation policy applied for 'app-key'"

# VNet Creation
$vnetName = "${ResourceGroupName}-vnet"
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue

if (-not $vnet) {
    Write-Host "Creating VNet $vnetName..."
    $vnet = New-AzVirtualNetwork -Name $vnetName `
                                 -ResourceGroupName $ResourceGroupName `
                                 -Location $rg.Location `
                                 -AddressPrefix "10.0.0.0/16"
}

# Subnet
$subnetName = "pe-subnet"
$subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet -ErrorAction SilentlyContinue

if (-not $subnet) {
    Write-Host "Creating Subnet $subnetName..."
    Add-AzVirtualNetworkSubnetConfig -Name $subnetName `
                                     -AddressPrefix "10.0.1.0/24" `
                                     -VirtualNetwork $vnet | Set-AzVirtualNetwork
}

# Private Endpoint
$peName = "${KeyVaultName}-pe"
$existingPE = Get-AzPrivateEndpoint -Name $peName `
                                    -ResourceGroupName $ResourceGroupName `
                                    -ErrorAction SilentlyContinue

if (-not $existingPE) {
    Write-Host "Creating Private Endpoint $peName..."
   # $subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet
   # Write-Host "$subnet"
    $virtualNetwork = Get-AzVirtualNetwork -ResourceName $vnetName -ResourceGroupName  $ResourceGroupName
    $subnet = $virtualNetwork | Select-Object -ExpandProperty subnets | Where-Object Name -eq $subnetName

    Write-Host "$subnet"
    Write-Host "$virtualNetwork"
    New-AzPrivateEndpoint -Name $peName `
                          -ResourceGroupName $ResourceGroupName `
                          -Location $rg.Location `
                          -Subnet $subnet `
                          -PrivateLinkServiceConnection @(@{
                              Name = "kvprivatelink"
                              PrivateLinkServiceId = $kv.ResourceId
                              GroupIds = @("vault")
                              RequestMessage = "Auto-approved"
                          })
} else {
    Write-Host "Private Endpoint $peName already exists."
}

Write-Host "All provisioning steps completed successfully."
