<#
.SYNOPSIS
    Adds a temporary HTTP listener on port 80 to Application Gateway for the ACME HTTP-01 challenge.

.DESCRIPTION
    Let's Encrypt needs to reach http://<domain>/.well-known/acme-challenge/ to validate
    domain ownership. This script creates a temporary HTTP listener and dummy routing rule
    on the Application Gateway to allow the challenge to complete.

.PARAMETER ResourceGroupName
    The Azure resource group containing the Application Gateway.

.PARAMETER AppGatewayName
    The name of the Application Gateway.

.EXAMPLE
    ./setup-http-listener.ps1 -ResourceGroupName "myRG" -AppGatewayName "myAppGW"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AppGatewayName
)

$ErrorActionPreference = "Stop"

# Check Azure CLI
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) {
    Write-Error "Azure CLI is not installed. Install from: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

Write-Host ""
Write-Host "Setting up temporary HTTP listener for ACME challenge..." -ForegroundColor Cyan
Write-Host "  Resource Group:  $ResourceGroupName"
Write-Host "  App Gateway:     $AppGatewayName"
Write-Host ""

# Get the frontend IP configuration name
$frontendIp = az network application-gateway frontend-ip list `
    --resource-group $ResourceGroupName `
    --gateway-name $AppGatewayName `
    --query "[0].name" -o tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($frontendIp)) {
    Write-Error "Failed to get frontend IP configuration."
    exit 1
}

# Check if port 80 frontend port already exists
$existingPort = az network application-gateway frontend-port list `
    --resource-group $ResourceGroupName `
    --gateway-name $AppGatewayName `
    --query "[?port==``80``].name" -o tsv

$frontendPortName = "http-port-80"
if ([string]::IsNullOrEmpty($existingPort)) {
    Write-Host "Creating frontend port for HTTP (80)..." -ForegroundColor Yellow
    az network application-gateway frontend-port create `
        --resource-group $ResourceGroupName `
        --gateway-name $AppGatewayName `
        --name $frontendPortName `
        --port 80 `
        --output none
} else {
    $frontendPortName = $existingPort
    Write-Host "Frontend port 80 already exists: $frontendPortName" -ForegroundColor Yellow
}

# Create HTTP listener
Write-Host "Creating HTTP listener 'acme-http-listener'..." -ForegroundColor Yellow
az network application-gateway http-listener create `
    --resource-group $ResourceGroupName `
    --gateway-name $AppGatewayName `
    --name "acme-http-listener" `
    --frontend-ip $frontendIp `
    --frontend-port $frontendPortName `
    --output none

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create HTTP listener."
    exit 1
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host " HTTP listener created successfully!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host " Listener 'acme-http-listener' is active on port 80."
Write-Host " You may also need to configure a routing rule pointing to a backend pool."
Write-Host ""
Write-Host " You can now run certbot to obtain the certificate."
Write-Host ""
Write-Host " After obtaining the cert, clean up with:"
Write-Host "   ./scripts/cleanup-http-listener.ps1 -ResourceGroupName '$ResourceGroupName' -AppGatewayName '$AppGatewayName'"
Write-Host ""
