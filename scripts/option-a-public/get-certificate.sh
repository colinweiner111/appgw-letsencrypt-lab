#!/bin/bash
# get-certificate.sh
# Obtain a Let's Encrypt TLS certificate using certbot standalone mode.
#
# Usage:
#   ./get-certificate.sh -d <domain> [-e <email>] [--staging]
#
# Examples:
#   ./get-certificate.sh -d appgw-lab.yourdomain.com
#   ./get-certificate.sh -d appgw-lab.yourdomain.com -e admin@yourdomain.com
#   ./get-certificate.sh -d appgw-lab.yourdomain.com --staging   # Use LE staging (no rate limits)

set -euo pipefail

DOMAIN=""
EMAIL=""
STAGING=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)
            DOMAIN="$2"
            shift 2
            ;;
        -e|--email)
            EMAIL="$2"
            shift 2
            ;;
        --staging)
            STAGING="--staging"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 -d <domain> [-e <email>] [--staging]"
            echo ""
            echo "Options:"
            echo "  -d, --domain    Domain name (required)"
            echo "  -e, --email     Email for Let's Encrypt notifications (optional)"
            echo "  --staging       Use Let's Encrypt staging environment (no rate limits)"
            echo "  -h, --help      Show this help message"
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
    echo "Example: $0 -d appgw-lab.yourdomain.com"
    exit 1
fi

# Check certbot is installed
if ! command -v certbot &> /dev/null; then
    echo "ERROR: certbot is not installed."
    echo ""
    echo "Install it with:"
    echo "  Ubuntu/Debian:  sudo apt update && sudo apt install certbot -y"
    echo "  macOS:          brew install certbot"
    echo "  RHEL/CentOS:    sudo yum install certbot -y"
    exit 1
fi

# Verify DNS resolves
echo "Verifying DNS for $DOMAIN..."
if ! nslookup "$DOMAIN" > /dev/null 2>&1; then
    echo "WARNING: DNS lookup for $DOMAIN failed."
    echo "Make sure your A record is configured and has propagated."
    read -p "Continue anyway? (y/N): " CONTINUE
    if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
        exit 1
    fi
fi

# Build certbot command
CERTBOT_CMD="sudo certbot certonly --standalone -d $DOMAIN"

if [ -n "$EMAIL" ]; then
    CERTBOT_CMD="$CERTBOT_CMD --email $EMAIL --no-eff-email"
else
    CERTBOT_CMD="$CERTBOT_CMD --register-unsafely-without-email"
fi

if [ -n "$STAGING" ]; then
    CERTBOT_CMD="$CERTBOT_CMD --staging"
    echo "Using Let's Encrypt STAGING environment (certs will not be trusted by browsers)."
fi

CERTBOT_CMD="$CERTBOT_CMD --agree-tos --non-interactive"

echo ""
echo "Requesting certificate for: $DOMAIN"
echo "Running: $CERTBOT_CMD"
echo ""

eval "$CERTBOT_CMD"

CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

echo ""
echo "========================================="
echo " Certificate obtained successfully!"
echo "========================================="
echo ""
echo " Certificate files:"
echo "   Full chain:   $CERT_DIR/fullchain.pem"
echo "   Private key:  $CERT_DIR/privkey.pem"
echo ""
echo " Next step: Convert to PFX for Application Gateway"
echo "   ./scripts/convert-to-pfx.ps1 -Domain \"$DOMAIN\""
echo "   -- or --"
echo "   openssl pkcs12 -export -out appgw-cert.pfx \\"
echo "     -inkey $CERT_DIR/privkey.pem \\"
echo "     -in $CERT_DIR/fullchain.pem"
echo ""
