#!/bin/bash
# cleanup-http-listener.sh
# Remove the temporary HTTP listener and port used for the ACME HTTP-01 challenge.
#
# After obtaining the Let's Encrypt certificate, this script removes the
# temporary HTTP listener that was created for the ACME HTTP-01 challenge.
#
# Usage:
#   ./cleanup-http-listener.sh --resource-group <rg> --gateway-name <name>
#
# Example:
#   ./cleanup-http-listener.sh --resource-group "myRG" --gateway-name "myAppGW"

set -euo pipefail

RESOURCE_GROUP=""
GATEWAY_NAME=""
LISTENER_NAME="acme-http-listener"

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
        --listener-name)
            LISTENER_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --resource-group <rg> --gateway-name <name>"
            echo ""
            echo "Options:"
            echo "  --resource-group, -g   Resource group (required)"
            echo "  --gateway-name         Application Gateway name (required)"
            echo "  --listener-name        Listener to remove (default: acme-http-listener)"
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

# ─── Cleanup ──────────────────────────────────────────────────────

echo ""
echo "Cleaning up temporary ACME challenge resources..."
echo "  Resource Group:  $RESOURCE_GROUP"
echo "  App Gateway:     $GATEWAY_NAME"
echo "  Listener:        $LISTENER_NAME"
echo ""

# Remove HTTP listener
echo "Removing HTTP listener '$LISTENER_NAME'..."
if az network application-gateway http-listener delete \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$GATEWAY_NAME" \
    --name "$LISTENER_NAME" \
    --output none 2>&1; then
    echo "  Listener removed."
else
    echo "WARNING: Could not remove listener '$LISTENER_NAME'. It may not exist or may have routing rules attached."
    echo "  If rules are attached, remove them first in the Azure Portal."
fi

# Optionally remove the frontend port (only if we created it)
PORT_NAME="http-port-80"
if az network application-gateway frontend-port show \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$GATEWAY_NAME" \
    --name "$PORT_NAME" \
    --query "name" -o tsv &> /dev/null; then

    echo "Removing frontend port '$PORT_NAME'..."
    if az network application-gateway frontend-port delete \
        --resource-group "$RESOURCE_GROUP" \
        --gateway-name "$GATEWAY_NAME" \
        --name "$PORT_NAME" \
        --output none 2>&1; then
        echo "  Frontend port removed."
    else
        echo "WARNING: Could not remove frontend port '$PORT_NAME'. It may be in use by another listener."
    fi
fi

echo ""
echo "========================================="
echo " Cleanup complete!"
echo "========================================="
echo ""
echo " The temporary HTTP resources for the ACME challenge have been removed."
echo " Your HTTPS listener and certificate remain active."
echo ""
