param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string]$AppObjectId
)

# -----------------------------
# Install Az module if missing
# -----------------------------
if (-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az

# -----------------------------
# Login using service principal
# -----------------------------
$securePassword = ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($env:AZURE_CLIENT_ID, $securePassword)
Connect-AzAccount -ServicePrincipal -Tenant $env:AZURE_TENANT_ID -Credential $cred

# Select the subscription
Select-AzSubscription -SubscriptionId $env:AZURE_SUBSCRIPTION_ID

# -----------------------------
# Retry helper function
# -----------------------------
function Retry-AzGetResourceGroup {
    param([string]$Name, [int]$MaxAttempts=5, [int]$Delay=10)
    for ($i=0; $i -lt $MaxAttempts; $i++) {
        $rg = Get-AzResourceGroup -Name $Name -ErrorAction SilentlyContinue
        if ($rg) { return $rg }
        Write-Host "Resource Group '$Name' not found. Retrying in $Delay seconds..."
        Start-Sleep -Seconds $Delay
    }
    return $null
}

# -----------------------------
# Check Resource Group
# -----------------------------
$rg = Retry-AzGetResourceGroup -Name $ResourceGroupName
if (-not $rg) {
    Write-Host "Resource Group '$ResourceGroupName' does not exist after retries!"
    exit 1
}
Write-Host "Resource Group exists: $($rg.ResourceGroupName)"

# -----------------------------
# Check Key Vault
# -----------------------------
$kv = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $kv) {
    Write-Host "Key Vault '$KeyVaultName' does not exist!"
    exit 1
}

# -----------------------------
# Key Vault Access Policy
# -----------------------------
Set-AzKeyVaultAccessPolicy -VaultName $KeyVaultName `
                           -ObjectId $AppObjectId `
                           -PermissionsToSecrets @("Get","Set","List") `
                           -PermissionsToKeys @("Get","Create","Update","Delete","Sign","Verify","WrapKey","UnwrapKey","SetRotationPolicy","GetRotationPolicy")

# -----------------------------
# Key Vault Key Creation / Rotation
# -----------------------------
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

# -----------------------------
# Virtual Network
# -----------------------------
$vnetName = "${ResourceGroupName}-vnet"
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $vnet) {
    Write-Host "Creating Virtual Network $vnetName..."
    $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName `
                                 -Location $rg.Location -AddressPrefix "10.0.0.0/16"
}

# -----------------------------
# Subnet
# -----------------------------
$subnetName = "pe-subnet"
$subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet -ErrorAction SilentlyContinue
if (-not $subnet) {
    Write-Host "Creating Subnet $subnetName..."
    Add-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix "10.0.1.0/24" -VirtualNetwork $vnet | Set-AzVirtualNetwork
}

# -----------------------------
# Private Endpoint for Key Vault
# -----------------------------
$peName = "${KeyVaultName}-pe"
$existingPE = Get-AzPrivateEndpoint -Name $peName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $existingPE) {
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
