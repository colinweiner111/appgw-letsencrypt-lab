<#
.SYNOPSIS
    Uploads a PFX certificate to an Azure Application Gateway HTTPS listener.

.DESCRIPTION
    Configures an existing Application Gateway with:
    - An SSL certificate from the provided PFX file
    - An HTTPS listener on port 443

.PARAMETER ResourceGroupName
    The Azure resource group containing the Application Gateway.

.PARAMETER AppGatewayName
    The name of the Application Gateway.

.PARAMETER PfxPath
    Path to the PFX certificate file.

.PARAMETER PfxPassword
    Password for the PFX file.

.PARAMETER CertName
    Name for the certificate in Application Gateway. Defaults to "letsencrypt-cert".

.PARAMETER ListenerName
    Name for the HTTPS listener. Defaults to "https-listener".

.EXAMPLE
    ./upload-cert.ps1 -ResourceGroupName "myRG" -AppGatewayName "myAppGW" -PfxPath "./appgw-cert.pfx" -PfxPassword "MyP@ss"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AppGatewayName,

    [Parameter(Mandatory = $true)]
    [string]$PfxPath,

    [Parameter(Mandatory = $true)]
    [string]$PfxPassword,

    [Parameter(Mandatory = $false)]
    [string]$CertName = "letsencrypt-cert",

    [Parameter(Mandatory = $false)]
    [string]$ListenerName = "https-listener"
)

$ErrorActionPreference = "Stop"

# Validate PFX file exists
if (-not (Test-Path $PfxPath)) {
    Write-Error "PFX file not found: $PfxPath"
    exit 1
}

# Check Azure CLI is available
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) {
    Write-Error "Azure CLI is not installed. Install from: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

# Verify logged in
$account = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not logged into Azure CLI. Run: az login"
    exit 1
}

Write-Host ""
Write-Host "Uploading certificate to Application Gateway..." -ForegroundColor Cyan
Write-Host "  Resource Group:  $ResourceGroupName"
Write-Host "  App Gateway:     $AppGatewayName"
Write-Host "  Certificate:     $PfxPath"
Write-Host "  Cert Name:       $CertName"
Write-Host ""

# Get Application Gateway
Write-Host "Retrieving Application Gateway configuration..." -ForegroundColor Yellow
$appgw = az network application-gateway show `
    --resource-group $ResourceGroupName `
    --name $AppGatewayName `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to retrieve Application Gateway: $appgw"
    exit 1
}

# Upload SSL certificate
Write-Host "Adding SSL certificate '$CertName'..." -ForegroundColor Yellow
az network application-gateway ssl-cert create `
    --resource-group $ResourceGroupName `
    --gateway-name $AppGatewayName `
    --name $CertName `
    --cert-file $PfxPath `
    --cert-password $PfxPassword `
    --output none

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to upload SSL certificate."
    exit 1
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host " Certificate uploaded successfully!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host " Certificate '$CertName' is now available in Application Gateway '$AppGatewayName'."
Write-Host ""
Write-Host " Next steps:"
Write-Host "   1. Create or update an HTTPS listener to use this certificate"
Write-Host "   2. Configure routing rules for the HTTPS listener"
Write-Host "   3. (Optional) Remove the temporary HTTP listener:"
Write-Host "      ./scripts/cleanup-http-listener.ps1 -ResourceGroupName '$ResourceGroupName' -AppGatewayName '$AppGatewayName'"
Write-Host ""
