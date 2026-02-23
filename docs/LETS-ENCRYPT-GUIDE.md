# Let's Encrypt Certificate Guide

Issue, convert, and upload TLS certificates for Azure Application Gateway using Let's Encrypt. This guide covers both DNS-01 and HTTP-01 challenge types, PFX conversion, the TLS trust chain, and renewal strategies.

> **New to Let's Encrypt?** Read [How Let's Encrypt Works](HOW-LETS-ENCRYPT-WORKS.md) first — it explains certificates, ACME challenges, certbot, PFX conversion, and the trust chain in plain language.
>
> **First time doing this?** Follow the [Step-by-Step Walkthrough](STEP-BY-STEP-GUIDE.md) — every command with expected outputs, troubleshooting, and DNS provider examples.

---

## Table of Contents

- [Which Option Do I Need?](#which-option-do-i-need)
- [Prerequisites](#prerequisites)
- [Option B — DNS-01 Challenge (Recommended)](#option-b--dns-01-challenge-recommended)
- [Option A — HTTP-01 Challenge](#option-a--http-01-challenge)
- [Understanding the TLS Trust Chain](#understanding-the-tls-trust-chain)
- [Certificate Renewal](#certificate-renewal)
- [Scripts Reference](#scripts-reference)
- [Troubleshooting](#troubleshooting)

---

## Which Option Do I Need?

| App Gateway Config | Challenge Type | Option |
|---|---|---|
| Public IP (internet testable) | DNS-01 | **[Option B](#option-b--dns-01-challenge-recommended) (Recommended)** |
| Public IP | HTTP-01 | [Option A](#option-a--http-01-challenge) |
| Wildcard certificate (`*.yourdomain.com`) | DNS-01 only | [Option B](#option-b--dns-01-challenge-recommended) |

> This lab deploys an App Gateway with both public and private IPs, so both options work.
> **Option B (DNS-01) is recommended** — no temporary port 80 listener required, and supports wildcard certs.

---

## Prerequisites

| Requirement | Details |
|---|---|
| **Public DNS domain** | You must own a real domain (e.g., `yourdomain.com`). Let's Encrypt cannot issue certs for raw IPs or `*.azurewebsites.net`. Cheap domains are ~$10/year from Namecheap, Cloudflare, or GoDaddy. |
| **Certbot** | Installed on any machine with internet access (laptop, Azure VM, Cloud Shell) |
| **OpenSSL** | For PFX conversion |
| **Azure CLI** | For uploading the certificate to App Gateway |

> **Important:** Your DNS zone must be **publicly resolvable** — even for private-only App Gateway deployments. Let's Encrypt validates against public DNS resolvers. Azure Private DNS zones or on-prem internal-only DNS will **not** work for DNS-01 validation.

### Install Certbot

All scripts in this repo are bash. Run them from **Azure Cloud Shell** (easiest — `az` + `openssl` pre-installed) or **WSL**.

```bash
# Cloud Shell — install certbot (one-time setup)
pip install --user certbot
export PATH="$HOME/.local/bin:$PATH"
export CERTBOT_DIR="$HOME/letsencrypt"

# All certbot commands below use these flags to avoid /etc permission errors:
#   --config-dir ~/letsencrypt --work-dir ~/letsencrypt/work --logs-dir ~/letsencrypt/logs

# WSL / Linux
sudo apt update && sudo apt install certbot -y

# macOS
brew install certbot
```

---

## Option B — DNS-01 Challenge (Recommended)

**Recommended for labs and enterprise deployments.**

DNS-01 validates domain ownership via a DNS TXT record — no port 80 listener required, no temporary infrastructure. Works with any App Gateway configuration (public or private).

### Architecture

```
┌────────────────────┐
│  Let's Encrypt      │
│  ACME Server        │
└──────────┬─────────┘
           │ Verifies TXT record
           ▼
┌────────────────────┐
│  DNS Provider       │
│  (Azure DNS, etc.)  │
│                     │
│  _acme-challenge.   │
│  acme.com            │
│  → "<validation>"   │
└──────────┬─────────┘
           │
           ▼
┌────────────────────┐       ┌─────────────────────────┐
│  Your Machine       │──────►│  App Gateway v2           │
│  (certbot + az cli) │  PFX  │  Public + Private IP      │
└────────────────────┘ upload│  HTTPS Listener (443)     │
                             └─────────────────────────┘
```

**Key advantages:**
- No port 80 listener required
- No temporary infrastructure
- Works with wildcard certs
- Enterprise-ready pattern
- Works with any App Gateway frontend (public or private)

> **Enterprise Note:** For production workloads, consider storing certificates in [Azure Key Vault](https://learn.microsoft.com/azure/key-vault/certificates/about-certificates) and referencing them from Application Gateway via Key Vault integration, rather than uploading PFX manually. This enables automated rotation and centralized certificate management.

### Quick Start (Manual DNS-01)

#### Step 1 — DNS Setup

Create A records so clients can resolve your App Gateway:

```
acme.com      →  <App Gateway Public IP>
www.acme.com  →  <App Gateway Public IP>
api.acme.com  →  <App Gateway Public IP>
app.acme.com  →  <App Gateway Public IP>
```

These A records are for **client resolution only** — they are NOT required for DNS-01 validation. Let's Encrypt only checks the `_acme-challenge` TXT records.

#### Step 2 — Request Certificate with DNS-01

```bash
certbot certonly \
  --manual \
  --preferred-challenges dns \
  --config-dir ~/letsencrypt --work-dir ~/letsencrypt/work --logs-dir ~/letsencrypt/logs \
  -d acme.com \
  -d www.acme.com \
  -d api.acme.com \
  -d app.acme.com
```

Certbot will prompt you once per domain to deploy a TXT record:

```
Please deploy a DNS TXT record under the name:
  _acme-challenge.acme.com
with the following value:
  <random-validation-string>
```

#### Step 3 — Add the TXT Record

Add the TXT record to your DNS provider.

**Azure DNS:**

```bash
az network dns record-set txt add-record \
  --resource-group "dns-rg" \
  --zone-name "acme.com" \
  --record-set-name "_acme-challenge" \
  --value "<validation-string>"
```

> **Note:** The `--record-set-name` is the **relative** name within the zone. For subdomains, use `_acme-challenge.www`, `_acme-challenge.api`, etc.

**Other providers:** Add `_acme-challenge.acme.com` as a TXT record in their portal.

Wait for DNS propagation (typically 30-60 seconds for Azure DNS), then press Enter in certbot.

#### Step 4 — Convert to PFX and Upload

```bash
# Convert PEM → PFX
openssl pkcs12 -export \
  -out appgw-cert.pfx \
  -inkey ~/letsencrypt/live/acme.com/privkey.pem \
  -in ~/letsencrypt/live/acme.com/fullchain.pem
```

```bash
# Upload to App Gateway
./scripts/shared/upload-cert.sh \
  --resource-group "myRG" \
  --gateway-name "myAppGW" \
  --pfx-path "./appgw-cert.pfx" \
  --pfx-password "yourpassword"
```

#### Step 5 — Clean Up TXT Record

```bash
az network dns record-set txt delete \
  --resource-group "dns-rg" \
  --zone-name "acme.com" \
  --name "_acme-challenge" --yes
# Repeat for _acme-challenge.www, _acme-challenge.api, _acme-challenge.app
```

### Fully Automated (Azure DNS)

For a production-grade, one-command experience:

```bash
./scripts/option-b-private/azure-dns-certbot.sh \
  -d acme.com \
  -d www.acme.com \
  --dns-zone acme.com \
  --dns-rg dns-rg \
  --appgw-name myAppGW \
  --appgw-rg appgw-rg
```

This script:
1. Creates the ACME TXT record in Azure DNS automatically
2. Waits for DNS propagation
3. Completes the certbot challenge
4. Converts to PFX
5. Uploads to App Gateway
6. Cleans up the TXT record

Add `--staging` for testing without hitting rate limits.

### Using the Bash Script

```bash
./scripts/option-b-private/get-certificate-dns01.sh -d acme.com
```

This runs certbot in interactive DNS-01 mode — you'll manually add the TXT record when prompted.

---

## Option A — HTTP-01 Challenge

Use this if your App Gateway has a **public IP address**. Let's Encrypt validates ownership by connecting to `http://yourdomain/.well-known/acme-challenge/` over the public internet.

### Architecture

```
┌─────────────────┐         ┌──────────────────┐        ┌────────────────────┐
│  Let's Encrypt   │◄───────►│   Your Machine    │───────►│  App Gateway       │
│  ACME Server     │  HTTP-01│   (certbot)       │  PFX   │  (Public IP)       │
│                  │ challenge│                   │ upload │  HTTPS Listener    │
└─────────────────┘         └──────────────────┘        └────────────────────┘
                                     ▲
                                     │
                              DNS A Record
                          acme.com
                                → App GW Public IP
```

> **Limitation:** HTTP-01 requires a public IP on the App Gateway (this lab includes one). For environments
> without a public IP, use [Option B](#option-b--dns-01-challenge-recommended) instead.

### Quick Start

#### Step 1 — Create Public DNS Record

```
acme.com  →  <App Gateway Public IP>
```

Verify: `nslookup acme.com`

#### Step 2 — Temporarily Open HTTP on App Gateway

Let's Encrypt must reach port 80 on your domain.

```bash
./scripts/option-a-public/setup-http-listener.sh \
  --resource-group "myRG" --gateway-name "myAppGW"
```

#### Step 3 — Obtain the Certificate

```bash
# Standalone mode
certbot certonly --standalone \
  --config-dir ~/letsencrypt --work-dir ~/letsencrypt/work --logs-dir ~/letsencrypt/logs \
  -d acme.com

# Or use the included script
./scripts/option-a-public/get-certificate.sh -d acme.com
```

Certificate files:

```
~/letsencrypt/live/acme.com/
├── fullchain.pem
└── privkey.pem
```

#### Step 4 — Convert to PFX

```bash
openssl pkcs12 -export \
  -out appgw-cert.pfx \
  -inkey ~/letsencrypt/live/acme.com/privkey.pem \
  -in ~/letsencrypt/live/acme.com/fullchain.pem
```

Or: `./scripts/shared/convert-to-pfx.sh -d acme.com`

#### Step 5 — Upload to Application Gateway

**Portal:**
1. Application Gateway → **Listeners** → HTTPS → Upload PFX

**CLI:**
```bash
./scripts/shared/upload-cert.sh \
  --resource-group "myRG" \
  --gateway-name "myAppGW" \
  --pfx-path "./appgw-cert.pfx" \
  --pfx-password "yourpassword"
```

#### Step 6 — Clean Up HTTP Listener

```bash
./scripts/option-a-public/cleanup-http-listener.sh \
  --resource-group "myRG" --gateway-name "myAppGW"
```

---

## Understanding the TLS Trust Chain

When you use Let's Encrypt, your certificate is part of a **chain of trust** that browsers and clients use to verify authenticity. Understanding this chain helps troubleshoot upload issues and browser warnings.

### How the Chain Works

```
┌──────────────────────────────────────────────────────────────────┐
│  ISRG Root X1  (Root CA)                                         │
│  ├── Built into all major browsers and OS trust stores           │
│  └── Self-signed — the ultimate trust anchor                     │
│                                                                  │
│       ▼  signs                                                   │
│                                                                  │
│  R3 or R10/R11  (Intermediate CA)                                │
│  ├── Signed by ISRG Root X1                                      │
│  └── This is what actually signs your certificate                │
│                                                                  │
│       ▼  signs                                                   │
│                                                                  │
│  acme.com  (Your Leaf Certificate)                               │
│  ├── Signed by the intermediate CA                               │
│  └── Contains your domain name and public key                    │
└──────────────────────────────────────────────────────────────────┘
```

### What Certbot Gives You

Certbot outputs two key files:

| File | Contents |
|---|---|
| `privkey.pem` | Your private key (never shared) |
| `fullchain.pem` | Your leaf cert **+** the intermediate cert (bundled) |

The `fullchain.pem` is critical — it includes the intermediate CA so clients can build the full trust path. If you only upload the leaf cert without the intermediate, browsers will show **"certificate not trusted"** warnings.

### Why This Matters for App Gateway

Azure Application Gateway requires a **PFX file** that contains:

1. Your private key
2. Your leaf certificate
3. The intermediate certificate(s)

The `openssl pkcs12 -export` command in this lab bundles all three from `fullchain.pem` + `privkey.pem` into a single `.pfx` file — which is exactly what App Gateway expects.

### Common Trust Chain Issues

| Symptom | Cause | Fix |
|---|---|---|
| Browser shows "Not Secure" despite valid cert | Uploaded `cert.pem` instead of `fullchain.pem` | Regenerate PFX using `fullchain.pem` |
| PFX upload succeeds but clients get errors | Missing intermediate in the chain | Ensure `openssl` uses `-in fullchain.pem`, not `-in cert.pem` |
| Staging certs show as untrusted | Expected — staging uses a fake root CA | Remove `--staging` flag and re-issue for a trusted cert |
| Old clients fail, new ones work | Legacy devices may not have ISRG Root X1 | Rare; Let's Encrypt cross-signs to cover older trust stores |

> **Tip:** Verify your chain is correct before uploading:
> ```bash
> openssl pkcs12 -in appgw-cert.pfx -nokeys -clcerts | openssl x509 -subject -issuer -noout
> openssl pkcs12 -in appgw-cert.pfx -nokeys -cacerts | openssl x509 -subject -issuer -noout
> ```
> The first command shows your leaf cert. The second shows the intermediate. Both should be present.

---

## Certificate Renewal

Let's Encrypt certificates are valid for **90 days**.

| Approach | Best For |
|---|---|
| **Manual** (re-run certbot) | Labs and short-lived demos |
| **Azure DNS automation script** (Option B) | Repeatable, scriptable renewal |
| **Azure Key Vault + Automation** | Longer-running demos and customer-facing PoCs |
| **GitHub Actions** | CI/CD-integrated renewal |

---

## Scripts Reference

### Shared (both options)

| Script | Purpose |
|---|---|
| `scripts/shared/convert-to-pfx.sh` | Convert PEM to PFX format |
| `scripts/shared/upload-cert.sh` | Upload PFX cert to Application Gateway (direct PFX method) |
| `scripts/shared/import-to-kv.sh` | Import PFX into Key Vault and output the secret URI |

### Option A — Public (HTTP-01)

| Script | Purpose |
|---|---|
| `scripts/option-a-public/get-certificate.sh` | Obtain cert via certbot standalone (HTTP-01) |
| `scripts/option-a-public/setup-http-listener.sh` | Add temporary HTTP listener for ACME challenge |
| `scripts/option-a-public/cleanup-http-listener.sh` | Remove temporary HTTP listener |

### Option B — Private (DNS-01)

| Script | Purpose |
|---|---|
| `scripts/option-b-private/get-certificate-dns01.sh` | Obtain cert via interactive DNS-01 challenge |
| `scripts/option-b-private/azure-dns-certbot.sh` | **Fully automated:** Azure DNS + certbot + PFX + upload |

---

## Troubleshooting

| Issue | Fix |
|---|---|
| **DNS-01:** TXT record not found | Wait longer for propagation. Verify: `nslookup -type=TXT _acme-challenge.yourdomain.com` |
| **DNS-01:** Azure DNS permission error | Ensure your `az` identity has `DNS Zone Contributor` on the zone |
| **HTTP-01:** "Connection refused" | Ensure port 80 is open on App Gateway and NSG allows inbound HTTP |
| DNS not resolving | Wait for propagation. Verify with `nslookup`. |
| PFX upload fails | Ensure the password matches and PFX includes the full chain |
| Let's Encrypt rate limit | Use `--staging` flag for testing without rate limits |
| Wildcard cert needed | Must use DNS-01 (Option B). HTTP-01 cannot issue wildcards. |
| **Namecheap multi-level TXT records** | Namecheap cannot create dotted host names like `_acme-challenge.appgw-lab`. Use the root domain or a single-level subdomain instead |
| **Cloud Shell: certbot not found** | Install via `pip install --user certbot` and add `$HOME/.local/bin` to PATH |
| **Cloud Shell: SSH key needed** | Generate with `ssh-keygen -t rsa -b 4096` before deploying |
