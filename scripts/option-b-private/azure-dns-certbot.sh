#!/bin/bash
# azure-dns-certbot.sh
# Fully automated Let's Encrypt certificate issuance using DNS-01 via Azure DNS.
#
# This script:
#   1. Creates the ACME TXT record in Azure DNS automatically
#   2. Waits for DNS propagation
#   3. Completes the certbot DNS-01 challenge
#   4. Converts PEM to PFX
#   5. (Optional) Uploads to Application Gateway
#   6. Cleans up the TXT record
#
# No manual DNS record creation needed — everything is automated via Azure CLI.
#
# Usage:
#   ./azure-dns-certbot.sh -d <domain> --dns-zone <zone> --dns-rg <rg> [options]
#
# Examples:
#   # Issue cert only
#   ./azure-dns-certbot.sh -d appgw-lab.contoso.com --dns-zone contoso.com --dns-rg dns-rg
#
#   # Issue cert + upload to App Gateway
#   ./azure-dns-certbot.sh -d appgw-lab.contoso.com --dns-zone contoso.com --dns-rg dns-rg \
#     --appgw-name myAppGW --appgw-rg rg-appgw-lab
#
#   # Use staging (no rate limits)
#   ./azure-dns-certbot.sh -d appgw-lab.contoso.com --dns-zone contoso.com --dns-rg dns-rg --staging

set -euo pipefail

# ─── Arguments ────────────────────────────────────────────────────

DOMAIN=""
DNS_ZONE_NAME=""
DNS_RESOURCE_GROUP=""
EMAIL=""
STAGING=""
APPGW_NAME=""
APPGW_RESOURCE_GROUP=""
PFX_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)          DOMAIN="$2";              shift 2 ;;
        --dns-zone)           DNS_ZONE_NAME="$2";       shift 2 ;;
        --dns-rg)             DNS_RESOURCE_GROUP="$2";  shift 2 ;;
        -e|--email)           EMAIL="$2";               shift 2 ;;
        --staging)            STAGING="--staging";       shift   ;;
        --appgw-name)         APPGW_NAME="$2";          shift 2 ;;
        --appgw-rg)           APPGW_RESOURCE_GROUP="$2"; shift 2 ;;
        --pfx-password)       PFX_PASSWORD="$2";        shift 2 ;;
        -h|--help)
            echo "Usage: $0 -d <domain> --dns-zone <zone> --dns-rg <rg> [options]"
            echo ""
            echo "Required:"
            echo "  -d, --domain         Domain name for the certificate"
            echo "  --dns-zone           Azure DNS zone name (e.g., contoso.com)"
            echo "  --dns-rg             Resource group containing the DNS zone"
            echo ""
            echo "Optional:"
            echo "  -e, --email          Email for Let's Encrypt notifications"
            echo "  --staging            Use Let's Encrypt staging (no rate limits)"
            echo "  --appgw-name         App Gateway name (to auto-upload cert)"
            echo "  --appgw-rg           App Gateway resource group"
            echo "  --pfx-password       PFX password (auto-generated if omitted)"
            echo "  -h, --help           Show this help message"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── Validation ───────────────────────────────────────────────────

if [ -z "$DOMAIN" ];             then echo "ERROR: --domain is required.";   exit 1; fi
if [ -z "$DNS_ZONE_NAME" ];      then echo "ERROR: --dns-zone is required."; exit 1; fi
if [ -z "$DNS_RESOURCE_GROUP" ]; then echo "ERROR: --dns-rg is required.";   exit 1; fi

for cmd in az certbot openssl; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: '$cmd' is not installed or not in PATH."
        exit 1
    fi
done

if ! az account show &> /dev/null; then
    echo "ERROR: Not logged into Azure CLI. Run: az login"
    exit 1
fi

# ─── Derive TXT record name ──────────────────────────────────────

# Strip the zone suffix to get the relative record name
# e.g., appgw-lab.contoso.com with zone contoso.com → _acme-challenge.appgw-lab
RELATIVE_NAME="${DOMAIN%.$DNS_ZONE_NAME}"
if [ "$RELATIVE_NAME" = "$DOMAIN" ]; then
    # Domain equals the zone (bare domain)
    TXT_RECORD_NAME="_acme-challenge"
else
    TXT_RECORD_NAME="_acme-challenge.$RELATIVE_NAME"
fi

# Generate PFX password if not provided
if [ -z "$PFX_PASSWORD" ]; then
    PFX_PASSWORD=$(openssl rand -base64 16)
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Automated DNS-01 Certificate Issuance"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo " Domain:        $DOMAIN"
echo " DNS Zone:      $DNS_ZONE_NAME"
echo " DNS RG:        $DNS_RESOURCE_GROUP"
echo " TXT Record:    $TXT_RECORD_NAME.$DNS_ZONE_NAME"
[ -n "$STAGING" ] && echo " Mode:          STAGING (certs will not be trusted)"
[ -n "$APPGW_NAME" ] && echo " App Gateway:   $APPGW_NAME ($APPGW_RESOURCE_GROUP)"
echo ""

# ─── Create certbot hook scripts ─────────────────────────────────

HOOK_DIR=$(mktemp -d)
AUTH_HOOK="$HOOK_DIR/auth-hook.sh"
CLEANUP_HOOK="$HOOK_DIR/cleanup-hook.sh"

# Auth hook: creates the TXT record and waits for propagation
cat > "$AUTH_HOOK" << 'HOOK_EOF'
#!/bin/bash
set -euo pipefail

# These are set by certbot at runtime:
#   CERTBOT_VALIDATION — the value to put in the TXT record
#   CERTBOT_DOMAIN     — the domain being validated

az network dns record-set txt add-record \
    --resource-group "__DNS_RG__" \
    --zone-name "__DNS_ZONE__" \
    --record-set-name "__TXT_RECORD__" \
    --value "$CERTBOT_VALIDATION" \
    --output none

echo "TXT record created. Waiting 30 seconds for DNS propagation..."
sleep 30
HOOK_EOF

# Cleanup hook: removes the TXT record
cat > "$CLEANUP_HOOK" << 'HOOK_EOF'
#!/bin/bash
set -euo pipefail

az network dns record-set txt remove-record \
    --resource-group "__DNS_RG__" \
    --zone-name "__DNS_ZONE__" \
    --record-set-name "__TXT_RECORD__" \
    --value "$CERTBOT_VALIDATION" \
    --output none 2>/dev/null || true
HOOK_EOF

# Replace placeholders with actual values
sed -i "s|__DNS_RG__|$DNS_RESOURCE_GROUP|g" "$AUTH_HOOK" "$CLEANUP_HOOK"
sed -i "s|__DNS_ZONE__|$DNS_ZONE_NAME|g"    "$AUTH_HOOK" "$CLEANUP_HOOK"
sed -i "s|__TXT_RECORD__|$TXT_RECORD_NAME|g" "$AUTH_HOOK" "$CLEANUP_HOOK"

chmod +x "$AUTH_HOOK" "$CLEANUP_HOOK"

# ─── Run certbot ─────────────────────────────────────────────────

CERTBOT_DIR="${CERTBOT_DIR:-$HOME/letsencrypt}"
CERTBOT_CMD="certbot certonly --manual --preferred-challenges dns --config-dir $CERTBOT_DIR --work-dir $CERTBOT_DIR/work --logs-dir $CERTBOT_DIR/logs -d $DOMAIN"
CERTBOT_CMD="$CERTBOT_CMD --manual-auth-hook $AUTH_HOOK"
CERTBOT_CMD="$CERTBOT_CMD --manual-cleanup-hook $CLEANUP_HOOK"

if [ -n "$EMAIL" ]; then
    CERTBOT_CMD="$CERTBOT_CMD --email $EMAIL --no-eff-email"
else
    CERTBOT_CMD="$CERTBOT_CMD --register-unsafely-without-email"
fi

if [ -n "$STAGING" ]; then
    CERTBOT_CMD="$CERTBOT_CMD --staging"
fi

CERTBOT_CMD="$CERTBOT_CMD --agree-tos --non-interactive"

echo "Running certbot..."
echo ""
eval "$CERTBOT_CMD"

# ─── Convert to PFX ──────────────────────────────────────────────

CERT_DIR="$CERTBOT_DIR/live/$DOMAIN"
PFX_PATH="./appgw-cert.pfx"

echo ""
echo "Converting certificate to PFX..."

openssl pkcs12 -export \
    -out "$PFX_PATH" \
    -inkey "$CERT_DIR/privkey.pem" \
    -in "$CERT_DIR/fullchain.pem" \
    -password "pass:$PFX_PASSWORD"

echo "PFX created: $PFX_PATH"

# ─── Optional: Upload to App Gateway ─────────────────────────────

if [ -n "$APPGW_NAME" ] && [ -n "$APPGW_RESOURCE_GROUP" ]; then
    echo ""
    echo "Uploading certificate to Application Gateway '$APPGW_NAME'..."

    az network application-gateway ssl-cert create \
        --resource-group "$APPGW_RESOURCE_GROUP" \
        --gateway-name "$APPGW_NAME" \
        --name "letsencrypt-cert" \
        --cert-file "$PFX_PATH" \
        --cert-password "$PFX_PASSWORD" \
        --output none

    echo "Certificate uploaded to App Gateway."
fi

# ─── Cleanup temp files ──────────────────────────────────────────

rm -rf "$HOOK_DIR"

# ─── Summary ─────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Certificate issued successfully!"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo " Domain:       $DOMAIN"
echo " PFX file:     $PFX_PATH"
echo " PFX password: $PFX_PASSWORD"
echo " Cert files:   $CERT_DIR/"
echo ""

if [ -n "$APPGW_NAME" ]; then
    echo " Certificate uploaded to App Gateway '$APPGW_NAME'."
else
    echo " Next step: Import to Key Vault"
    echo "   ./scripts/shared/import-to-kv.sh \\"
    echo "     --vault-name 'kv-appgw-xxx' \\"
    echo "     --pfx-path '$PFX_PATH' \\"
    echo "     --pfx-password '$PFX_PASSWORD'"
fi
echo ""
