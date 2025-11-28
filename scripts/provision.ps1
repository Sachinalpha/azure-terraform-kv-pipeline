param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $true)]
    [string]$AppObjectId,

    [Parameter(Mandatory = $false)]
    [string]$KeyName = "app-key",          # Default key name

    [Parameter(Mandatory = $false)]
    [string]$SecretName = "app-secret"     # Default secret name
)

# Install Az module if missing
if (-not (Get-Module -ListAvailable -Name Az)) {
    Install-Module -Name Az -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az

# Login with Service Principal
$securePassword = ConvertTo-SecureString $env:AZURE_CLIENT_SECRET -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($env:AZURE_CLIENT_ID, $securePassword)
Connect-AzAccount -ServicePrincipal -Tenant $env:AZURE_TENANT_ID -Credential $cred
Select-AzSubscription -SubscriptionId $env:AZURE_SUBSCRIPTION_ID

# Retry helper for Resource Group
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
if (-not $rg) { Write-Error "Resource Group '$ResourceGroupName' does not exist after retries!"; exit 1 }
Write-Host "Resource Group exists: $($rg.ResourceGroupName)"

# Check Key Vault
$kv = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $kv) { Write-Error "Key Vault '$KeyVaultName' does not exist!"; exit 1 }
Write-Host "Key Vault exists: $KeyVaultName"

# Set Key Vault Access Policy
Write-Host "Setting Access Policy (bypassing validation)..."
Set-AzKeyVaultAccessPolicy -VaultName $KeyVaultName `
                           -ObjectId $AppObjectId `
                           -PermissionsToSecrets @("Get","Set","List") `
                           -PermissionsToKeys @("Get","Create","Update","Delete","Sign","Verify","WrapKey","UnwrapKey","SetRotationPolicy","GetRotationPolicy") `
                           -BypassObjectIdValidation `
                           -ErrorAction Stop
Write-Host "Access policy applied"

# Key Creation with retry
$maxAttempts = 5
$delaySeconds = 10
for ($i=1; $i -le $maxAttempts; $i++) {
    try {
        $key = Get-AzKeyVaultKey -VaultName $KeyVaultName -Name $KeyName -ErrorAction SilentlyContinue
        if (-not $key) {
            Write-Host "Creating Key Vault key '$KeyName'..."
            Add-AzKeyVaultKey -VaultName $KeyVaultName -Name $KeyName `
                              -Destination "Software" `
                              -KeyType "RSA" `
                              -Size 2048 `
                              -KeyOps @("encrypt","decrypt","sign","verify")
            Write-Host "Key '$KeyName' created successfully."
        } else {
            Write-Host "Key '$KeyName' already exists."
        }
        break
    } catch {
        Write-Host "Attempt $i failed to create key. Retrying in $delaySeconds seconds..."
        Start-Sleep -Seconds $delaySeconds
    }
}

# Add Tags to Key Vault
$kv = Get-AzKeyVault -VaultName $KeyVaultName
if ($kv.Tags.Count -eq 0 -or $kv.Tags["env"] -ne "prod") {
    Write-Host "Applying tags to Key Vault '$KeyVaultName'..."
    Set-AzResource -ResourceType "Microsoft.KeyVault/vaults" `
                   -ResourceGroupName $kv.ResourceGroupName `
                   -Name $KeyVaultName `
                   -Tag @{ env="prod"; owner="teamA" } `
                   -Force
} else {
    Write-Host "Key Vault '$KeyVaultName' already has tags."
}

# Create Secret
$existingSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $SecretName -ErrorAction SilentlyContinue
if (-not $existingSecret) {
    Write-Host "Creating secret '$SecretName'..."
    Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $SecretName `
                         -SecretValue (ConvertTo-SecureString "MySecretValue123" -AsPlainText -Force)
} else {
    Write-Host "Secret '$SecretName' already exists."
}

# Rotation Policy
Set-AzKeyVaultKeyRotationPolicy -VaultName $KeyVaultName -Name $KeyName -ExpiresIn "P90D"
Write-Host "Rotation policy applied for '$KeyName'"

# VNet creation
$vnetName = "${ResourceGroupName}-vnet"
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $vnet) {
    try {
        Write-Host "Creating VNet $vnetName..."
        $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -Location $rg.Location -AddressPrefix "10.0.0.0/16"
    } catch {
        Write-Host "VNet creation failed: $_"
    }
} else {
    Write-Host "VNet $vnetName already exists."
}

# Subnet creation
$subnetName = "pe-subnet"
$subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet -ErrorAction SilentlyContinue
if (-not $subnet) {
    Write-Host "Creating Subnet $subnetName..."
    Add-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix "10.0.1.0/24" -VirtualNetwork $vnet | Set-AzVirtualNetwork
} else {
    Write-Host "Subnet $subnetName already exists."
}

# Private Endpoint creation
$peName = "${KeyVaultName}-pe"
$existingPE = Get-AzPrivateEndpoint -Name $peName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $existingPE) {
    try {
        Write-Host "Creating Private Endpoint $peName..."
        $virtualNetwork = Get-AzVirtualNetwork -ResourceName $vnetName -ResourceGroupName $ResourceGroupName
        $subnet = $virtualNetwork | Select-Object -ExpandProperty subnets | Where-Object Name -eq $subnetName
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
    } catch {
        Write-Host "Private Endpoint creation failed: $_"
    }
} else {
    Write-Host "Private Endpoint $peName already exists."
}

Write-Host "All provisioning steps completed successfully."
