#!/bin/bash
# setup-http-listener.sh
# Add a temporary HTTP listener on port 80 to Application Gateway for the ACME HTTP-01 challenge.
#
# Let's Encrypt needs to reach http://<domain>/.well-known/acme-challenge/ to validate
# domain ownership. This script creates a temporary HTTP listener and frontend port
# on the Application Gateway to allow the challenge to complete.
#
# Usage:
#   ./setup-http-listener.sh --resource-group <rg> --gateway-name <name>
#
# Example:
#   ./setup-http-listener.sh --resource-group "myRG" --gateway-name "myAppGW"

set -euo pipefail

RESOURCE_GROUP=""
GATEWAY_NAME=""

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
        -h|--help)
            echo "Usage: $0 --resource-group <rg> --gateway-name <name>"
            echo ""
            echo "Options:"
            echo "  --resource-group, -g   Resource group (required)"
            echo "  --gateway-name         Application Gateway name (required)"
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

if ! command -v az &> /dev/null; then
    echo "ERROR: Azure CLI is not installed."
    echo "Install from: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi

# ─── Setup ────────────────────────────────────────────────────────

echo ""
echo "Setting up temporary HTTP listener for ACME challenge..."
echo "  Resource Group:  $RESOURCE_GROUP"
echo "  App Gateway:     $GATEWAY_NAME"
echo ""

# Get the frontend IP configuration name
FRONTEND_IP=$(az network application-gateway frontend-ip list \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$GATEWAY_NAME" \
    --query "[0].name" -o tsv)

if [ -z "$FRONTEND_IP" ]; then
    echo "ERROR: Failed to get frontend IP configuration."
    exit 1
fi

# Check if port 80 frontend port already exists
EXISTING_PORT=$(az network application-gateway frontend-port list \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$GATEWAY_NAME" \
    --query "[?port==\`80\`].name" -o tsv)

FRONTEND_PORT_NAME="http-port-80"
if [ -z "$EXISTING_PORT" ]; then
    echo "Creating frontend port for HTTP (80)..."
    az network application-gateway frontend-port create \
        --resource-group "$RESOURCE_GROUP" \
        --gateway-name "$GATEWAY_NAME" \
        --name "$FRONTEND_PORT_NAME" \
        --port 80 \
        --output none
else
    FRONTEND_PORT_NAME="$EXISTING_PORT"
    echo "Frontend port 80 already exists: $FRONTEND_PORT_NAME"
fi

# Create HTTP listener
echo "Creating HTTP listener 'acme-http-listener'..."
az network application-gateway http-listener create \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$GATEWAY_NAME" \
    --name "acme-http-listener" \
    --frontend-ip "$FRONTEND_IP" \
    --frontend-port "$FRONTEND_PORT_NAME" \
    --output none

echo ""
echo "========================================="
echo " HTTP listener created successfully!"
echo "========================================="
echo ""
echo " Listener 'acme-http-listener' is active on port 80."
echo " You may also need to configure a routing rule pointing to a backend pool."
echo ""
echo " You can now run certbot to obtain the certificate."
echo ""
echo " After obtaining the cert, clean up with:"
echo "   ./scripts/option-a-public/cleanup-http-listener.sh \\"
echo "     --resource-group '$RESOURCE_GROUP' --gateway-name '$GATEWAY_NAME'"
echo ""
