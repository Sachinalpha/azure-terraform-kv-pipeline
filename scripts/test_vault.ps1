[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$SourceVault,

    [Parameter(Mandatory = $true)]
    [string]$TargetVault,

    [Parameter(Mandatory = $true)]
    [string]$AzureClientId,

    [Parameter(Mandatory = $true)]
    [string]$AzureClientSecret,

    [Parameter(Mandatory = $true)]
    [string]$AzureTenantId,

    [Parameter(Mandatory = $true)]
    [string]$AzureSubscriptionId
)

$ErrorActionPreference = "Stop"
$WarningPreference     = "SilentlyContinue"

Write-Host "Authenticating to Azure..."

$SecureSecret = ConvertTo-SecureString $AzureClientSecret -AsPlainText -Force
$Credential   = New-Object System.Management.Automation.PSCredential ($AzureClientId, $SecureSecret)

Connect-AzAccount -ServicePrincipal -Tenant $AzureTenantId -Credential $Credential | Out-Null
Set-AzContext -SubscriptionId $AzureSubscriptionId | Out-Null

Write-Host "Authentication successful."

# ====================== FIREWALL FUNCTIONS ======================

function Disable-KeyVaultFirewall($VaultName, $VaultRG) {
    Write-Host "Disabling firewall completely for: $VaultName"

    # Enable public access
    Update-AzKeyVault `
        -VaultName $VaultName `
        -ResourceGroupName $VaultRG `
        -PublicNetworkAccess Enabled | Out-Null

    # Allow all IPs
    Add-AzKeyVaultNetworkRule `
        -VaultName $VaultName `
        -ResourceGroupName $VaultRG `
        -IpAddressRange "10.188.16.33" | Out-Null
}

function Enable-KeyVaultFirewall($VaultName, $VaultRG) {
    Write-Host "Re-enabling firewall for: $VaultName"

    # Remove allow-all rule
    Remove-AzKeyVaultNetworkRule `
        -VaultName $VaultName `
        -ResourceGroupName $VaultRG `
        -IpAddressRange "0.0.0.0/0" `
        -ErrorAction SilentlyContinue | Out-Null

    # Disable public access
    Update-AzKeyVault `
        -VaultName $VaultName `
        -ResourceGroupName $VaultRG `
        -PublicNetworkAccess Disabled | Out-Null
}

# ====================== TEMP DIRECTORIES ======================

$TempDir   = Join-Path $env:RUNNER_TEMP "kv-backup"
$CertDir   = Join-Path $env:RUNNER_TEMP "kv-certs"
$KeyDir    = Join-Path $env:RUNNER_TEMP "kv-keys"
$SecretDir = Join-Path $env:RUNNER_TEMP "kv-secrets"

foreach ($dir in @($TempDir, $CertDir, $KeyDir, $SecretDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

# ====================== MAIN PROCESS ======================

# Get vault objects and RGs upfront
$SourceKV = Get-AzKeyVault -VaultName $SourceVault
$TargetKV = Get-AzKeyVault -VaultName $TargetVault

$SourceVaultRG = $SourceKV.ResourceGroupName
$TargetVaultRG = $TargetKV.ResourceGroupName

try {
    # -------------------- Disable Firewalls --------------------
    Disable-KeyVaultFirewall $SourceVault $SourceVaultRG
    Disable-KeyVaultFirewall $TargetVault $TargetVaultRG
    Start-Sleep 10

    # -------------------- Tags --------------------
    Write-Host "Processing tags..."
    if ($SourceKV.Tags -and $SourceKV.Tags.Count -gt 0) {
        Update-AzKeyVault -VaultName $TargetVault -ResourceGroupName $TargetVaultRG -Tag $SourceKV.Tags | Out-Null
        Write-Host "Tags copied successfully."
    } else {
        Write-Host "No tags present, skipped."
    }

    # -------------------- Access Policies --------------------
    Write-Host "Processing access policies..."
    if ($SourceKV.AccessPolicies.Count -eq 0) {
        Write-Host "No access policies present, skipped."
    } else {
        foreach ($Policy in $SourceKV.AccessPolicies) {
            try {
                $existing = $TargetKV.AccessPolicies | Where-Object { $_.ObjectId -eq $Policy.ObjectId }
                if ($existing) {
                    Write-Host "Access policy skipped (already exists): $($Policy.ObjectId)"
                    continue
                }

                Set-AzKeyVaultAccessPolicy `
                    -VaultName $TargetVault `
                    -ObjectId $Policy.ObjectId `
                    -PermissionsToKeys $Policy.PermissionsToKeys `
                    -PermissionsToSecrets $Policy.PermissionsToSecrets `
                    -PermissionsToCertificates $Policy.PermissionsToCertificates `
                    -PermissionsToStorage $Policy.PermissionsToStorage | Out-Null

                Write-Host "Access policy copied: $($Policy.ObjectId)"
            } catch {
                Write-Host ("Failed to copy access policy {0}: {1}" -f $Policy.ObjectId, $_.Exception.Message)
            }
        }
    }

    # -------------------- Certificates --------------------
    Write-Host "Processing certificates..."
    $Certs = Get-AzKeyVaultCertificate -VaultName $SourceVault
    $CertNames = $Certs.Name

    foreach ($Cert in $Certs) {
        $certName = $Cert.Name
        $backupFile = Join-Path $CertDir "$certName.backup"

        Write-Host "Processing certificate: $certName"

        $exists = Get-AzKeyVaultCertificate -VaultName $TargetVault -Name $certName -ErrorAction SilentlyContinue
        if ($exists) {
            Write-Host "Certificate $certName already exists in target vault. Skipping."
            continue
        }

        try {
            Backup-AzKeyVaultCertificate -VaultName $SourceVault -Name $certName -OutputFile $backupFile
            Restore-AzKeyVaultCertificate -VaultName $TargetVault -InputFile $backupFile
            Write-Host "Copied certificate: $certName"
        } catch {
            Write-Host ("Failed to copy certificate {0}: {1}" -f $certName, $_.Exception.Message)
        }
    }

    # -------------------- Keys --------------------
    Write-Host "Processing keys..."
    $Keys = Get-AzKeyVaultKey -VaultName $SourceVault | Where-Object { $CertNames -notcontains $_.Name }

    foreach ($Key in $Keys) {
        $keyName = $Key.Name
        $file = Join-Path $KeyDir "$keyName.key"

        $exists = Get-AzKeyVaultKey -VaultName $TargetVault -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -eq $keyName }
        if ($exists) {
            Write-Host "Key skipped (already exists): $keyName"
            continue
        }

        try {
            Backup-AzKeyVaultKey -VaultName $SourceVault -Name $keyName -OutputFile $file
            Restore-AzKeyVaultKey -VaultName $TargetVault -InputFile $file
            Write-Host "Key copied: $keyName"
        } catch {
            Write-Host ("Failed to copy key {0}: {1}" -f $keyName, $_.Exception.Message)
        }
    }

    # -------------------- Secrets --------------------
    Write-Host "Processing secrets..."
    $Secrets = Get-AzKeyVaultSecret -VaultName $SourceVault | Where-Object { $CertNames -notcontains $_.Name }

    foreach ($Secret in $Secrets) {
        $secretName = $Secret.Name

        $exists = Get-AzKeyVaultSecret -VaultName $TargetVault -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -eq $secretName }
        if ($exists) {
            Write-Host "Secret skipped (already exists): $secretName"
            continue
        }

        try {
            $value = (Get-AzKeyVaultSecret -VaultName $SourceVault -Name $secretName).SecretValue
            Set-AzKeyVaultSecret -VaultName $TargetVault -Name $secretName -SecretValue $value | Out-Null
            Write-Host "Secret copied: $secretName"
        } catch {
            Write-Host ("Failed to copy secret {0}: {1}" -f $secretName, $_.Exception.Message)
        }
    }

} finally {
    # -------------------- Re-enable Firewalls --------------------
    Enable-KeyVaultFirewall $SourceVault $SourceVaultRG
    Enable-KeyVaultFirewall $TargetVault $TargetVaultRG

    # Clean temp directories
    foreach ($dir in @($TempDir, $CertDir, $KeyDir, $SecretDir)) {
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Key Vault cloning completed."
