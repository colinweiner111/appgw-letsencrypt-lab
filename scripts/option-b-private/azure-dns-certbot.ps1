<#
.SYNOPSIS
    Automates Let's Encrypt DNS-01 challenge using Azure DNS for private Application Gateway.

.DESCRIPTION
    This script fully automates certificate issuance for a private App Gateway:
    1. Creates the ACME TXT record in Azure DNS
    2. Waits for DNS propagation
    3. Completes the certbot DNS-01 challenge
    4. Converts the cert to PFX
    5. Optionally uploads to App Gateway

    No public IP or inbound HTTP access is required.

.PARAMETER Domain
    The FQDN to obtain a certificate for (e.g., appgw-lab.yourdomain.com).

.PARAMETER DnsZoneName
    The Azure DNS zone name (e.g., yourdomain.com).

.PARAMETER DnsResourceGroupName
    Resource group containing the Azure DNS zone.

.PARAMETER AppGatewayName
    (Optional) Application Gateway name — if provided, the cert is uploaded automatically.

.PARAMETER AppGatewayResourceGroupName
    (Optional) Resource group for the Application Gateway.

.PARAMETER OutputPfx
    Path for the output PFX file. Defaults to ./appgw-cert.pfx.

.PARAMETER Staging
    Use Let's Encrypt staging environment (no rate limits, untrusted certs).

.EXAMPLE
    # Just get the cert (manual upload later)
    ./azure-dns-certbot.ps1 -Domain "appgw-lab.contoso.com" -DnsZoneName "contoso.com" -DnsResourceGroupName "dns-rg"

.EXAMPLE
    # Full automation: cert + upload to App Gateway
    ./azure-dns-certbot.ps1 `
        -Domain "appgw-lab.contoso.com" `
        -DnsZoneName "contoso.com" `
        -DnsResourceGroupName "dns-rg" `
        -AppGatewayName "myAppGW" `
        -AppGatewayResourceGroupName "appgw-rg"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Domain,

    [Parameter(Mandatory = $true)]
    [string]$DnsZoneName,

    [Parameter(Mandatory = $true)]
    [string]$DnsResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$AppGatewayName = "",

    [Parameter(Mandatory = $false)]
    [string]$AppGatewayResourceGroupName = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputPfx = "./appgw-cert.pfx",

    [Parameter(Mandatory = $false)]
    [switch]$Staging
)

$ErrorActionPreference = "Stop"

# ─── Validation ───────────────────────────────────────────────────

# Check Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI is not installed. Install from: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

# Check logged in
$null = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Not logged into Azure CLI. Run: az login"
    exit 1
}

# Check certbot
if (-not (Get-Command certbot -ErrorAction SilentlyContinue)) {
    Write-Error @"
Certbot is not installed.

Install it with:
  Windows (Chocolatey):  choco install certbot -y
  Linux:                 sudo apt install certbot -y
  macOS:                 brew install certbot
"@
    exit 1
}

# Check openssl
if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    Write-Error "OpenSSL is not installed or not in PATH."
    exit 1
}

# ─── Derive record name ──────────────────────────────────────────

# For domain "appgw-lab.contoso.com" and zone "contoso.com",
# the TXT record name is "_acme-challenge.appgw-lab"
$recordName = "_acme-challenge"
$subdomain = $Domain.Replace(".$DnsZoneName", "")
if ($subdomain -ne $Domain) {
    $recordName = "_acme-challenge.$subdomain"
}

Write-Host ""
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " Azure DNS + Let's Encrypt DNS-01 Automation"          -ForegroundColor Cyan
Write-Host " Private App Gateway — No Public IP Required"          -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Domain:       $Domain"
Write-Host "  DNS Zone:     $DnsZoneName"
Write-Host "  DNS RG:       $DnsResourceGroupName"
Write-Host "  TXT Record:   $recordName.$DnsZoneName"
if ($AppGatewayName) {
    Write-Host "  App Gateway:  $AppGatewayName ($AppGatewayResourceGroupName)"
}
if ($Staging) {
    Write-Host "  Environment:  STAGING (certs will not be trusted)" -ForegroundColor Yellow
}
Write-Host ""

# ─── Step 1: Create authenticator hook scripts ───────────────────

# certbot --manual uses hook scripts to create/clean up DNS records
$hookDir = Join-Path $env:TEMP "certbot-azure-hooks"
New-Item -ItemType Directory -Path $hookDir -Force | Out-Null

# Auth hook — creates the TXT record
$authHookContent = @"
#!/bin/bash
az network dns record-set txt add-record \
    --resource-group "$DnsResourceGroupName" \
    --zone-name "$DnsZoneName" \
    --record-set-name "$recordName" \
    --value "`$CERTBOT_VALIDATION" \
    --output none 2>/dev/null

# Wait for DNS propagation
echo "Waiting 30 seconds for DNS propagation..."
sleep 30
"@

# Cleanup hook — removes the TXT record
$cleanupHookContent = @"
#!/bin/bash
az network dns record-set txt remove-record \
    --resource-group "$DnsResourceGroupName" \
    --zone-name "$DnsZoneName" \
    --record-set-name "$recordName" \
    --value "`$CERTBOT_VALIDATION" \
    --output none 2>/dev/null
"@

# PowerShell-native auth hook (Windows)
$authHookPs1 = @"
`$validation = `$env:CERTBOT_VALIDATION
Write-Host "Creating TXT record: $recordName = `$validation"
az network dns record-set txt add-record ``
    --resource-group "$DnsResourceGroupName" ``
    --zone-name "$DnsZoneName" ``
    --record-set-name "$recordName" ``
    --value `$validation ``
    --output none
Write-Host "Waiting 30 seconds for DNS propagation..."
Start-Sleep -Seconds 30
"@

$cleanupHookPs1 = @"
`$validation = `$env:CERTBOT_VALIDATION
Write-Host "Removing TXT record: $recordName = `$validation"
az network dns record-set txt remove-record ``
    --resource-group "$DnsResourceGroupName" ``
    --zone-name "$DnsZoneName" ``
    --record-set-name "$recordName" ``
    --value `$validation ``
    --output none 2>`$null
"@

$authHookPath = Join-Path $hookDir "auth-hook.ps1"
$cleanupHookPath = Join-Path $hookDir "cleanup-hook.ps1"

Set-Content -Path $authHookPath -Value $authHookPs1
Set-Content -Path $cleanupHookPath -Value $cleanupHookPs1

# Also write bash versions for Linux/WSL
Set-Content -Path (Join-Path $hookDir "auth-hook.sh") -Value $authHookContent
Set-Content -Path (Join-Path $hookDir "cleanup-hook.sh") -Value $cleanupHookContent

Write-Host "Step 1/4: Hook scripts created" -ForegroundColor Green

# ─── Step 2: Run certbot with DNS-01 ─────────────────────────────

Write-Host "Step 2/4: Requesting certificate via DNS-01 challenge..." -ForegroundColor Yellow

$certbotArgs = @(
    "certonly"
    "--manual"
    "--preferred-challenges", "dns"
    "-d", $Domain
    "--manual-auth-hook", "pwsh -File `"$authHookPath`""
    "--manual-cleanup-hook", "pwsh -File `"$cleanupHookPath`""
    "--agree-tos"
    "--non-interactive"
    "--register-unsafely-without-email"
)

if ($Staging) {
    $certbotArgs += "--staging"
}

& certbot @certbotArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "Certbot failed. Check the output above for details."
    exit 1
}

Write-Host "Step 2/4: Certificate obtained!" -ForegroundColor Green

# ─── Step 3: Convert to PFX ──────────────────────────────────────

Write-Host "Step 3/4: Converting to PFX format..." -ForegroundColor Yellow

# Determine cert path
$certDir = "/etc/letsencrypt/live/$Domain"
if ($IsWindows -or (-not $IsLinux -and -not $IsMacOS)) {
    $certDir = "C:\Certbot\live\$Domain"
}

$fullchain = Join-Path $certDir "fullchain.pem"
$privkey   = Join-Path $certDir "privkey.pem"

if (-not (Test-Path $fullchain)) {
    Write-Error "Certificate not found at $fullchain"
    exit 1
}

# Generate random PFX password
$pfxPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 24 | ForEach-Object { [char]$_ })

& openssl pkcs12 -export -out $OutputPfx -inkey $privkey -in $fullchain -password "pass:$pfxPassword"

if ($LASTEXITCODE -ne 0) {
    Write-Error "PFX conversion failed."
    exit 1
}

Write-Host "Step 3/4: PFX created at $OutputPfx" -ForegroundColor Green

# ─── Step 4: Upload to App Gateway (optional) ────────────────────

if ($AppGatewayName -and $AppGatewayResourceGroupName) {
    Write-Host "Step 4/4: Uploading to Application Gateway..." -ForegroundColor Yellow

    az network application-gateway ssl-cert create `
        --resource-group $AppGatewayResourceGroupName `
        --gateway-name $AppGatewayName `
        --name "letsencrypt-cert" `
        --cert-file $OutputPfx `
        --cert-password $pfxPassword `
        --output none

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to upload certificate to Application Gateway."
        exit 1
    }

    Write-Host "Step 4/4: Certificate uploaded to App Gateway!" -ForegroundColor Green
} else {
    Write-Host "Step 4/4: Skipped (no App Gateway specified)" -ForegroundColor DarkGray
}

# ─── Summary ─────────────────────────────────────────────────────

Write-Host ""
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " Done! Certificate issued and ready."              -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  PFX file:      $OutputPfx"
Write-Host "  PFX password:  $pfxPassword"
Write-Host ""
if ($AppGatewayName) {
    Write-Host "  Certificate uploaded to: $AppGatewayName" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Next: Configure an HTTPS listener to use 'letsencrypt-cert'"
} else {
    Write-Host "  Next: Upload to App Gateway with:"
    Write-Host "    ./scripts/shared/upload-cert.ps1 ``"
    Write-Host "      -ResourceGroupName '<rg>' ``"
    Write-Host "      -AppGatewayName '<appgw>' ``"
    Write-Host "      -PfxPath '$OutputPfx' ``"
    Write-Host "      -PfxPassword '$pfxPassword'"
}
Write-Host ""
Write-Host "  IMPORTANT: Save the PFX password above — you'll need it for renewal."
Write-Host ""

# Clean up hook scripts
Remove-Item -Path $hookDir -Recurse -Force -ErrorAction SilentlyContinue
