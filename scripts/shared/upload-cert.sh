#!/bin/bash
# upload-cert.sh
# Upload a PFX certificate directly to an Azure Application Gateway HTTPS listener.
#
# Usage:
#   ./upload-cert.sh --resource-group <rg> --gateway-name <name> --pfx-path <path> --pfx-password <password>
#
# Example:
#   ./upload-cert.sh --resource-group "myRG" --gateway-name "myAppGW" --pfx-path "./appgw-cert.pfx" --pfx-password "MyP@ss"

set -euo pipefail

RESOURCE_GROUP=""
GATEWAY_NAME=""
PFX_PATH=""
PFX_PASSWORD=""
CERT_NAME="letsencrypt-cert"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group|-g)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        --gateway-name)
            GATEWAY_NAME="$2"
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
        --cert-name)
            CERT_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --resource-group <rg> --gateway-name <name> --pfx-path <path> --pfx-password <password>"
            echo ""
            echo "Options:"
            echo "  --resource-group, -g   Resource group (required)"
            echo "  --gateway-name         Application Gateway name (required)"
            echo "  --pfx-path             Path to PFX file (required)"
            echo "  --pfx-password         PFX password (required)"
            echo "  --cert-name            Certificate name in App GW (default: letsencrypt-cert)"
            echo "  -h, --help             Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ─── Validation ───────────────────────────────────────────────────

if [ -z "$RESOURCE_GROUP" ]; then echo "ERROR: --resource-group is required."; exit 1; fi
if [ -z "$GATEWAY_NAME" ];  then echo "ERROR: --gateway-name is required.";  exit 1; fi
if [ -z "$PFX_PATH" ];      then echo "ERROR: --pfx-path is required.";      exit 1; fi
if [ -z "$PFX_PASSWORD" ];  then echo "ERROR: --pfx-password is required.";  exit 1; fi

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

# ─── Upload certificate ──────────────────────────────────────────

echo ""
echo "Uploading certificate to Application Gateway..."
echo "  Resource Group:  $RESOURCE_GROUP"
echo "  App Gateway:     $GATEWAY_NAME"
echo "  Certificate:     $PFX_PATH"
echo "  Cert Name:       $CERT_NAME"
echo ""

# Verify App Gateway exists
echo "Retrieving Application Gateway configuration..."
if ! az network application-gateway show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$GATEWAY_NAME" \
    --output none 2>&1; then
    echo "ERROR: Failed to retrieve Application Gateway '$GATEWAY_NAME' in '$RESOURCE_GROUP'."
    exit 1
fi

# Upload SSL certificate
echo "Adding SSL certificate '$CERT_NAME'..."
az network application-gateway ssl-cert create \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$GATEWAY_NAME" \
    --name "$CERT_NAME" \
    --cert-file "$PFX_PATH" \
    --cert-password "$PFX_PASSWORD" \
    --output none

echo ""
echo "========================================="
echo " Certificate uploaded successfully!"
echo "========================================="
echo ""
echo " Certificate '$CERT_NAME' is now available in Application Gateway '$GATEWAY_NAME'."
echo ""
echo " Next steps:"
echo "   1. Create or update an HTTPS listener to use this certificate"
echo "   2. Configure routing rules for the HTTPS listener"
echo "   3. (Optional) Remove the temporary HTTP listener:"
echo "      ./scripts/option-a-public/cleanup-http-listener.sh \\"
echo "        --resource-group '$RESOURCE_GROUP' --gateway-name '$GATEWAY_NAME'"
echo ""
