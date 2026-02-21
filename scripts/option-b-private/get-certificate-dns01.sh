#!/bin/bash
# get-certificate-dns01.sh
# Obtain a Let's Encrypt TLS certificate using DNS-01 challenge.
# Works with private Application Gateway — no public IP required.
#
# Usage:
#   ./get-certificate-dns01.sh -d <domain> [-e <email>] [--staging]
#
# The DNS-01 challenge proves domain ownership via a TXT record, not HTTP.
# This means no inbound port 80 or public endpoint is needed.
#
# Examples:
#   ./get-certificate-dns01.sh -d appgw-lab.yourdomain.com
#   ./get-certificate-dns01.sh -d appgw-lab.yourdomain.com --staging

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
            echo ""
            echo "This uses DNS-01 challenge — no public IP or HTTP access required."
            echo "You will be prompted to create a DNS TXT record during the process."
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

# Build certbot command for DNS-01
CERTBOT_DIR="${CERTBOT_DIR:-$HOME/letsencrypt}"
CERTBOT_CMD="certbot certonly --manual --preferred-challenges dns --config-dir $CERTBOT_DIR --work-dir $CERTBOT_DIR/work --logs-dir $CERTBOT_DIR/logs -d $DOMAIN"

if [ -n "$EMAIL" ]; then
    CERTBOT_CMD="$CERTBOT_CMD --email $EMAIL --no-eff-email"
else
    CERTBOT_CMD="$CERTBOT_CMD --register-unsafely-without-email"
fi

if [ -n "$STAGING" ]; then
    CERTBOT_CMD="$CERTBOT_CMD --staging"
    echo "Using Let's Encrypt STAGING environment (certs will not be trusted by browsers)."
fi

CERTBOT_CMD="$CERTBOT_CMD --agree-tos"

echo ""
echo "============================================"
echo " DNS-01 Challenge — No Public IP Required"
echo "============================================"
echo ""
echo " Domain: $DOMAIN"
echo ""
echo " How this works:"
echo "   1. Certbot will ask you to create a DNS TXT record"
echo "   2. Record name:  _acme-challenge.$DOMAIN"
echo "   3. Add it to your DNS provider (Azure DNS, Cloudflare, etc.)"
echo "   4. Wait for DNS propagation"
echo "   5. Press Enter in certbot to continue"
echo "   6. Certificate is issued"
echo ""
echo " No port 80, no public IP, no temporary listener needed."
echo ""
echo "Running: $CERTBOT_CMD"
echo ""

eval "$CERTBOT_CMD"

CERT_DIR="$CERTBOT_DIR/live/$DOMAIN"

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
echo "   ./scripts/shared/convert-to-pfx.ps1 -Domain \"$DOMAIN\""
echo "   -- or --"
echo "   openssl pkcs12 -export -out appgw-cert.pfx \\"
echo "     -inkey $CERT_DIR/privkey.pem \\"
echo "     -in $CERT_DIR/fullchain.pem"
echo ""
echo " Tip: You can now remove the _acme-challenge TXT record from DNS."
echo ""
