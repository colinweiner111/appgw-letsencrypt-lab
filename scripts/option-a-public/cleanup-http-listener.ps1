<#
.SYNOPSIS
    Removes the temporary HTTP listener and port used for the ACME challenge.

.DESCRIPTION
    After obtaining the Let's Encrypt certificate, this script removes the
    temporary HTTP listener that was created for the ACME HTTP-01 challenge.

.PARAMETER ResourceGroupName
    The Azure resource group containing the Application Gateway.

.PARAMETER AppGatewayName
    The name of the Application Gateway.

.PARAMETER ListenerName
    Name of the HTTP listener to remove. Defaults to "acme-http-listener".

.EXAMPLE
    ./cleanup-http-listener.ps1 -ResourceGroupName "myRG" -AppGatewayName "myAppGW"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$AppGatewayName,

    [Parameter(Mandatory = $false)]
    [string]$ListenerName = "acme-http-listener"
)

$ErrorActionPreference = "Stop"

# Check Azure CLI
$azCmd = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCmd) {
    Write-Error "Azure CLI is not installed. Install from: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

Write-Host ""
Write-Host "Cleaning up temporary ACME challenge resources..." -ForegroundColor Cyan
Write-Host "  Resource Group:  $ResourceGroupName"
Write-Host "  App Gateway:     $AppGatewayName"
Write-Host "  Listener:        $ListenerName"
Write-Host ""

# Remove HTTP listener
Write-Host "Removing HTTP listener '$ListenerName'..." -ForegroundColor Yellow
az network application-gateway http-listener delete `
    --resource-group $ResourceGroupName `
    --gateway-name $AppGatewayName `
    --name $ListenerName `
    --output none 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not remove listener '$ListenerName'. It may not exist or may have routing rules attached."
    Write-Host "  If rules are attached, remove them first in the Azure Portal."
} else {
    Write-Host "  Listener removed." -ForegroundColor Green
}

# Optionally remove the frontend port (only if we created it)
$portName = "http-port-80"
$portExists = az network application-gateway frontend-port show `
    --resource-group $ResourceGroupName `
    --gateway-name $AppGatewayName `
    --name $portName `
    --query "name" -o tsv 2>&1

if ($LASTEXITCODE -eq 0 -and $portExists -eq $portName) {
    Write-Host "Removing frontend port '$portName'..." -ForegroundColor Yellow
    az network application-gateway frontend-port delete `
        --resource-group $ResourceGroupName `
        --gateway-name $AppGatewayName `
        --name $portName `
        --output none 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Frontend port removed." -ForegroundColor Green
    } else {
        Write-Warning "Could not remove frontend port '$portName'. It may be in use by another listener."
    }
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host " Cleanup complete!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host " The temporary HTTP resources for the ACME challenge have been removed."
Write-Host " Your HTTPS listener and certificate remain active."
Write-Host ""
