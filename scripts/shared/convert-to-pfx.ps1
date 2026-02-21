<#
.SYNOPSIS
    Converts Let's Encrypt PEM certificate files to PFX format for Azure Application Gateway.

.DESCRIPTION
    Azure Application Gateway requires certificates in PFX format.
    This script converts the fullchain.pem and privkey.pem files from certbot
    into a single .pfx file with a password.

.PARAMETER Domain
    The domain name used when obtaining the certificate.

.PARAMETER CertDir
    Path to the directory containing the PEM files. Defaults to /etc/letsencrypt/live/<Domain>/.

.PARAMETER OutputPath
    Path for the output PFX file. Defaults to ./appgw-cert.pfx.

.PARAMETER PfxPassword
    Password to protect the PFX file. If not provided, you will be prompted.

.EXAMPLE
    ./convert-to-pfx.ps1 -Domain "appgw-lab.yourdomain.com"

.EXAMPLE
    ./convert-to-pfx.ps1 -Domain "appgw-lab.yourdomain.com" -OutputPath "./mycert.pfx" -PfxPassword "MyP@ss123"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Domain,

    [Parameter(Mandatory = $false)]
    [string]$CertDir = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "./appgw-cert.pfx",

    [Parameter(Mandatory = $false)]
    [string]$PfxPassword = ""
)

$ErrorActionPreference = "Stop"

# Default cert directory based on OS
if ([string]::IsNullOrEmpty($CertDir)) {
    if ($IsLinux -or $IsMacOS) {
        $CertDir = "/etc/letsencrypt/live/$Domain"
    } else {
        # Windows — certbot default or user-specified
        $CertDir = "C:\Certbot\live\$Domain"
        if (-not (Test-Path $CertDir)) {
            $CertDir = "$env:USERPROFILE\letsencrypt\live\$Domain"
        }
    }
}

$fullchainPath = Join-Path $CertDir "fullchain.pem"
$privkeyPath   = Join-Path $CertDir "privkey.pem"

# Validate input files
if (-not (Test-Path $fullchainPath)) {
    Write-Error "Certificate file not found: $fullchainPath"
    exit 1
}
if (-not (Test-Path $privkeyPath)) {
    Write-Error "Private key file not found: $privkeyPath"
    exit 1
}

# Check for openssl
$opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
if (-not $opensslCmd) {
    Write-Error @"
OpenSSL is not installed or not in PATH.

Install it with:
  Windows (Chocolatey):  choco install openssl -y
  Windows (winget):      winget install ShiningLight.OpenSSL
  Linux:                 sudo apt install openssl -y
  macOS:                 brew install openssl
"@
    exit 1
}

# Prompt for password if not provided
if ([string]::IsNullOrEmpty($PfxPassword)) {
    $securePass = Read-Host "Enter PFX password" -AsSecureString
    $PfxPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
    )
}

if ([string]::IsNullOrEmpty($PfxPassword)) {
    Write-Error "PFX password cannot be empty."
    exit 1
}

Write-Host ""
Write-Host "Converting certificate to PFX format..." -ForegroundColor Cyan
Write-Host "  Full chain: $fullchainPath"
Write-Host "  Private key: $privkeyPath"
Write-Host "  Output:      $OutputPath"
Write-Host ""

# Run openssl conversion
$opensslArgs = @(
    "pkcs12", "-export",
    "-out", $OutputPath,
    "-inkey", $privkeyPath,
    "-in", $fullchainPath,
    "-password", "pass:$PfxPassword"
)

& openssl @opensslArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "OpenSSL conversion failed with exit code $LASTEXITCODE"
    exit 1
}

$pfxFile = Get-Item $OutputPath
Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host " PFX certificate created successfully!" -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host " File:     $($pfxFile.FullName)"
Write-Host " Size:     $($pfxFile.Length) bytes"
Write-Host ""
Write-Host " Next step: Upload to Application Gateway"
Write-Host "   ./scripts/upload-cert.ps1 ``"
Write-Host "     -ResourceGroupName 'myRG' ``"
Write-Host "     -AppGatewayName 'myAppGW' ``"
Write-Host "     -PfxPath '$OutputPath' ``"
Write-Host "     -PfxPassword '<your-password>'"
Write-Host ""
