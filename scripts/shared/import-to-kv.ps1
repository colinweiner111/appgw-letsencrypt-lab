<#
.SYNOPSIS
    Imports a PFX certificate into Azure Key Vault for Application Gateway.

.DESCRIPTION
    After obtaining a Let's Encrypt certificate and converting it to PFX,
    this script imports it into Key Vault and outputs the secret URI needed
    for the Application Gateway Bicep deployment.

    App Gateway uses the KEY VAULT SECRET URI (not the certificate URI).

.PARAMETER KeyVaultName
    Name of the Azure Key Vault.

.PARAMETER CertName
    Name for the certificate in Key Vault. Defaults to "appgw-cert".

.PARAMETER PfxPath
    Path to the PFX certificate file.

.PARAMETER PfxPassword
    Password for the PFX file.

.EXAMPLE
    ./import-to-kv.ps1 -KeyVaultName "kv-appgw-abc123" -PfxPath "./appgw-cert.pfx" -PfxPassword "MyP@ss"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$KeyVaultName,

    [Parameter(Mandatory = $false)]
    [string]$CertName = "appgw-cert",

    [Parameter(Mandatory = $true)]
    [string]$PfxPath,

    [Parameter(Mandatory = $true)]
    [string]$PfxPassword
)

$ErrorActionPreference = "Stop"

# ─── Validation ───────────────────────────────────────────────────

if (-not (Test-Path $PfxPath)) {
    Write-Error "PFX file not found: $PfxPath"
    exit 1
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI is not installed. Install from: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

$null = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not logged into Azure CLI. Run: az login"
    exit 1
}

# ─── Import certificate ──────────────────────────────────────────

Write-Host ""
Write-Host "Importing certificate to Key Vault..." -ForegroundColor Cyan
Write-Host "  Key Vault: $KeyVaultName"
Write-Host "  Cert Name: $CertName"
Write-Host "  PFX File:  $PfxPath"
Write-Host ""

$result = az keyvault certificate import `
    --vault-name $KeyVaultName `
    --name $CertName `
    --file $PfxPath `
    --password $PfxPassword `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to import certificate: $result"
    exit 1
}

$certObj = $result | ConvertFrom-Json

# ─── Get the secret URI (this is what App Gateway needs) ─────────

# App Gateway references certs via the secret URI, not the certificate URI
# Format: https://<vault>.vault.azure.net/secrets/<name>/<version>
$secretId = $certObj.sid

if ([string]::IsNullOrEmpty($secretId)) {
    # Fallback: construct from certificate ID
    $certId = $certObj.id
    $secretId = $certId -replace '/certificates/', '/secrets/'
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " Certificate imported to Key Vault successfully!"         -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host " Key Vault Secret URI (use this in App Gateway):"
Write-Host ""
Write-Host "   $secretId" -ForegroundColor Yellow
Write-Host ""
Write-Host " Next step: Re-deploy with HTTPS enabled:"
Write-Host ""
Write-Host "   az deployment group create \" -ForegroundColor DarkGray
Write-Host "     --resource-group rg-appgw-lab \" -ForegroundColor DarkGray
Write-Host "     --template-file bicep/main.bicep \" -ForegroundColor DarkGray
Write-Host "     --parameters \" -ForegroundColor DarkGray
Write-Host "       sshPublicKey=`"``$(cat ~/.ssh/id_rsa.pub)`" \" -ForegroundColor DarkGray
Write-Host "       enableHttps=true \" -ForegroundColor DarkGray
Write-Host "       keyVaultSecretId=`"$secretId`"" -ForegroundColor DarkGray
Write-Host ""
Write-Host " IMPORTANT: App Gateway uses the SECRET URI, not the certificate URI." -ForegroundColor Yellow
Write-Host ""

# Output for pipeline use
Write-Output $secretId
