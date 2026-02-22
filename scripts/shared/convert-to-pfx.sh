#!/bin/bash
# convert-to-pfx.sh
# Convert Let's Encrypt PEM certificate files to PFX format for Azure Application Gateway.
#
# Usage:
#   ./convert-to-pfx.sh -d <domain> [-c <cert-dir>] [-o <output-path>] [-p <password>]
#
# Examples:
#   ./convert-to-pfx.sh -d acme.com
#   ./convert-to-pfx.sh -d acme.com -o ./mycert.pfx -p "MyP@ss123"

set -euo pipefail

DOMAIN=""
CERT_DIR=""
OUTPUT_PATH="./appgw-cert.pfx"
PFX_PASSWORD=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)
            DOMAIN="$2"
            shift 2
            ;;
        -c|--cert-dir)
            CERT_DIR="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_PATH="$2"
            shift 2
            ;;
        -p|--password)
            PFX_PASSWORD="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 -d <domain> [-c <cert-dir>] [-o <output-path>] [-p <password>]"
            echo ""
            echo "Options:"
            echo "  -d, --domain     Domain name (required)"
            echo "  -c, --cert-dir   Path to PEM files (default: ~/letsencrypt/live/<domain>)"
            echo "  -o, --output     Output PFX path (default: ./appgw-cert.pfx)"
            echo "  -p, --password   PFX password (prompted if omitted)"
            echo "  -h, --help       Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -z "$DOMAIN" ]; then
    echo "ERROR: Domain is required. Use -d <domain>"
    echo "Example: $0 -d acme.com"
    exit 1
fi

# Default cert directory
if [ -z "$CERT_DIR" ]; then
    CERT_DIR="${CERTBOT_DIR:-$HOME/letsencrypt}/live/$DOMAIN"
fi

FULLCHAIN_PATH="$CERT_DIR/fullchain.pem"
PRIVKEY_PATH="$CERT_DIR/privkey.pem"

# Validate input files
if [ ! -f "$FULLCHAIN_PATH" ]; then
    echo "ERROR: Certificate file not found: $FULLCHAIN_PATH"
    exit 1
fi
if [ ! -f "$PRIVKEY_PATH" ]; then
    echo "ERROR: Private key file not found: $PRIVKEY_PATH"
    exit 1
fi

# Check for openssl
if ! command -v openssl &> /dev/null; then
    echo "ERROR: OpenSSL is not installed or not in PATH."
    echo ""
    echo "Install it with:"
    echo "  Ubuntu/Debian:  sudo apt install openssl -y"
    echo "  macOS:          brew install openssl"
    echo "  RHEL/CentOS:    sudo yum install openssl -y"
    exit 1
fi

# Prompt for password if not provided
if [ -z "$PFX_PASSWORD" ]; then
    read -sp "Enter PFX password: " PFX_PASSWORD
    echo ""
    if [ -z "$PFX_PASSWORD" ]; then
        echo "ERROR: PFX password cannot be empty."
        exit 1
    fi
fi

echo ""
echo "Converting certificate to PFX format..."
echo "  Full chain: $FULLCHAIN_PATH"
echo "  Private key: $PRIVKEY_PATH"
echo "  Output:      $OUTPUT_PATH"
echo ""

# Run openssl conversion
openssl pkcs12 -export \
    -out "$OUTPUT_PATH" \
    -inkey "$PRIVKEY_PATH" \
    -in "$FULLCHAIN_PATH" \
    -password "pass:$PFX_PASSWORD"

PFX_SIZE=$(stat -c%s "$OUTPUT_PATH" 2>/dev/null || stat -f%z "$OUTPUT_PATH" 2>/dev/null)

echo ""
echo "========================================="
echo " PFX certificate created successfully!"
echo "========================================="
echo ""
echo " File:     $(realpath "$OUTPUT_PATH")"
echo " Size:     $PFX_SIZE bytes"
echo ""
echo " Next step: Import to Key Vault"
echo "   ./scripts/shared/import-to-kv.sh \\"
echo "     --vault-name 'kv-appgw-xxx' \\"
echo "     --pfx-path '$OUTPUT_PATH' \\"
echo "     --pfx-password '<your-password>'"
echo ""
