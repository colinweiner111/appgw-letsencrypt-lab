#!/bin/bash
# import-to-kv.sh
# Import a PFX certificate into Azure Key Vault for Application Gateway.
#
# After obtaining a Let's Encrypt certificate and converting it to PFX,
# this script imports it into Key Vault and outputs the secret URI needed
# for the Application Gateway Bicep deployment.
#
# App Gateway uses the KEY VAULT SECRET URI (not the certificate URI).
#
# Usage:
#   ./import-to-kv.sh --vault-name <name> --pfx-path <path> --pfx-password <password>
#
# Examples:
#   ./import-to-kv.sh --vault-name "kv-appgw-abc123" --pfx-path "./appgw-cert.pfx" --pfx-password "MyP@ss"

set -euo pipefail

VAULT_NAME=""
CERT_NAME="appgw-cert"
PFX_PATH=""
PFX_PASSWORD=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vault-name)
            VAULT_NAME="$2"
            shift 2
            ;;
        --cert-name)
            CERT_NAME="$2"
            shift 2
            ;;
        --pfx-path)
            PFX_PATH="$2"
            shift 2
            ;;
        --pfx-password)
            PFX_PASSWORD="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --vault-name <name> --pfx-path <path> --pfx-password <password>"
            echo ""
            echo "Options:"
            echo "  --vault-name    Azure Key Vault name (required)"
            echo "  --cert-name     Certificate name in Key Vault (default: appgw-cert)"
            echo "  --pfx-path      Path to PFX file (required)"
            echo "  --pfx-password  PFX password (required)"
            echo "  -h, --help      Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ─── Validation ───────────────────────────────────────────────────

if [ -z "$VAULT_NAME" ]; then
    echo "ERROR: --vault-name is required."
    exit 1
fi
if [ -z "$PFX_PATH" ]; then
    echo "ERROR: --pfx-path is required."
    exit 1
fi
if [ -z "$PFX_PASSWORD" ]; then
    echo "ERROR: --pfx-password is required."
    exit 1
fi

if [ ! -f "$PFX_PATH" ]; then
    echo "ERROR: PFX file not found: $PFX_PATH"
    exit 1
fi

if ! command -v az &> /dev/null; then
    echo "ERROR: Azure CLI is not installed."
    echo "Install from: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi

if ! az account show &> /dev/null; then
    echo "ERROR: Not logged into Azure CLI. Run: az login"
    exit 1
fi

# ─── Import certificate ──────────────────────────────────────────

echo ""
echo "Importing certificate to Key Vault..."
echo "  Key Vault: $VAULT_NAME"
echo "  Cert Name: $CERT_NAME"
echo "  PFX File:  $PFX_PATH"
echo ""

RESULT=$(az keyvault certificate import \
    --vault-name "$VAULT_NAME" \
    --name "$CERT_NAME" \
    --file "$PFX_PATH" \
    --password "$PFX_PASSWORD" \
    --output json 2>&1)

if [ $? -ne 0 ]; then
    echo "ERROR: Failed to import certificate: $RESULT"
    exit 1
fi

# ─── Get the secret URI (this is what App Gateway needs) ─────────

# App Gateway references certs via the secret URI, not the certificate URI
# Format: https://<vault>.vault.azure.net/secrets/<name>/<version>
SECRET_ID=$(echo "$RESULT" | jq -r '.sid // empty')

if [ -z "$SECRET_ID" ]; then
    # Fallback: construct from certificate ID
    CERT_ID=$(echo "$RESULT" | jq -r '.id // empty')
    SECRET_ID=$(echo "$CERT_ID" | sed 's|/certificates/|/secrets/|')
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Certificate imported to Key Vault successfully!"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo " Key Vault Secret URI (use this in App Gateway):"
echo ""
echo "   $SECRET_ID"
echo ""
echo " Next step: Re-deploy with HTTPS enabled:"
echo ""
echo "   az deployment group create \\"
echo "     --resource-group rg-appgw-lab \\"
echo "     --template-file bicep/main.bicep \\"
echo "     --parameters \\"
echo "       sshPublicKey=\"\$(cat ~/.ssh/id_rsa.pub)\" \\"
echo "       enableHttps=true \\"
echo "       keyVaultSecretId=\"$SECRET_ID\""
echo ""
echo " IMPORTANT: App Gateway uses the SECRET URI, not the certificate URI."
echo ""

# Output for pipeline use
echo "$SECRET_ID"
