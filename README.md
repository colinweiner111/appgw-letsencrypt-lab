# Azure Application Gateway v2 TLS Lab
## Public & Private Deployments Using Let's Encrypt (HTTP-01 & DNS-01)

Free TLS certificates for Azure Application Gateway v2 using Let's Encrypt. Includes full Bicep infrastructure (VNet, App Gateway, Key Vault, backend VMs) and automated certificate issuance via DNS-01 or HTTP-01.

No certificate purchase required. Public App Gateway with Key Vault TLS integration.

> **New to Let's Encrypt?** Read [How Let's Encrypt Works](docs/HOW-LETS-ENCRYPT-WORKS.md) first — it explains certificates, ACME challenges, certbot, PFX conversion, and the trust chain in plain language before you dive into the lab steps.
>
> **First time doing this?** Follow the [Step-by-Step Walkthrough](docs/STEP-BY-STEP-GUIDE.md) — it walks through every command with expected outputs, troubleshooting, and DNS provider examples (Azure DNS, Cloudflare, GoDaddy).

## What This Repo Deploys

```
┌──────────────────────────────────────────────────────────────────────┐
│  Resource Group: rg-appgw-lab                                        │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │  VNet: vnet-appgw-lab (10.0.0.0/16)                           │  │
│  │                                                                │  │
│  │  ┌─────────────────────┐   ┌──────────────────────────────┐   │  │
│  │  │ subnet-appgw        │   │ subnet-backend               │   │  │
│  │  │ 10.0.0.0/24         │   │ 10.0.1.0/24                  │   │  │
│  │  │                     │   │                              │   │  │
│  │  │  App Gateway v2     │──►│  VM 1 (NGINX)  ◄── no pub IP│   │  │
│  │  │  Public + Private IP│   │  VM 2 (NGINX)  ◄── no pub IP│   │  │
│  │  │  HTTPS (443)        │   │                              │   │  │
│  │  │                     │   └──────────────────────────────┘   │  │
│  │  └──────────┬──────────┘                                      │  │
│  │             │                                                  │  │
│  └─────────────┼──────────────────────────────────────────────────┘  │
│                │ Key Vault                                           │
│  ┌─────────────▼──────────────────┐   ┌────────────────────────┐    │
│  │  kv-appgw-xxx                  │   │  id-appgw-lab          │    │
│  │  TLS cert (secret URI)         │◄──│  User-Assigned MI      │    │
│  │  RBAC: Key Vault Secrets User  │   │  Attached to App GW    │    │
│  └────────────────────────────────┘   └────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

### Components

| Resource | Purpose |
|---|---|
| **User-Assigned Managed Identity** | App Gateway → Key Vault access (enterprise-preferred over system-assigned) |
| **VNet** with dedicated subnets | App GW subnet (required isolation), backend subnet, optional Bastion |
| **Application Gateway v2** | Standard_v2 or WAF_v2, public + private IP, autoscale, HTTPS listener |
| **Azure Key Vault** | RBAC-based, stores TLS cert, referenced via secret URI |
| **Backend VMs** (Linux + NGINX) | 2 VMs, no public IPs, unique page per VM for LB demo |
| **NSGs** | App GW subnet allows GatewayManager + HTTP + HTTPS; backend allows only App GW traffic |

### Design Decisions

| Decision | Rationale |
|---|---|
| Public + private frontend on App Gateway | Public IP enables internet/browser testing; private IP for VNet-internal access |
| User-assigned managed identity | Reusable, explicit RBAC, cleaner than system-assigned |
| Key Vault with Azure RBAC (not access policies) | Modern best practice, granular control |
| Key Vault Secrets User role (not Contributor) | Minimum required: `secrets/get` |
| App GW references Key Vault **secret** URI | App Gateway reads certs from secrets, not the certificate object |
| Explicit health probe definition | Never rely on defaults — define protocol, path, thresholds |
| No public IPs on backend VMs | Traffic only via App Gateway, management via Bastion |
| cloud-init for NGINX install | Lightweight, no custom images needed |

---

## Quick Start — Deploy Everything

### Step 1 — Deploy Infrastructure

```bash
# Create resource group
az group create --name rg-appgw-lab --location eastus2

# Deploy (initial — HTTP only, no cert yet)
az deployment group create \
  --resource-group rg-appgw-lab \
  --template-file bicep/main.bicep \
  --parameters sshPublicKey="$(cat ~/.ssh/id_rsa.pub)"
```

Note the outputs — you'll need `keyVaultName` for the cert import.

### Step 2 — Issue Certificate (DNS-01)

> **Need the full walkthrough?** See the [Step-by-Step Guide](docs/STEP-BY-STEP-GUIDE.md) for detailed instructions with expected outputs, DNS provider examples, and troubleshooting.

```bash
# Automated (Azure DNS)
./scripts/option-b-private/azure-dns-certbot.sh \
  -d acme.com \
  -d www.acme.com \
  -d api.acme.com \
  -d app.acme.com \
  --dns-zone acme.com \
  --dns-rg dns-rg

# Or manual (multi-domain SAN cert)
certbot certonly --manual --preferred-challenges dns \
  --config-dir ~/letsencrypt --work-dir ~/letsencrypt/work --logs-dir ~/letsencrypt/logs \
  -d acme.com \
  -d www.acme.com \
  -d api.acme.com \
  -d app.acme.com
```

### Step 3 — Convert to PFX

```bash
openssl pkcs12 -export \
  -out appgw-cert.pfx \
  -inkey ~/letsencrypt/live/acme.com/privkey.pem \
  -in ~/letsencrypt/live/acme.com/fullchain.pem
```

### Step 4 — Import to Key Vault

```bash
./scripts/shared/import-to-kv.sh \
  --vault-name "kv-appgw-xxx" \
  --pfx-path "./appgw-cert.pfx" \
  --pfx-password "yourpassword"
```

Save the **secret URI** from the output.

### Step 5 — Re-deploy with HTTPS

> **Important:** On Phase 2 redeploy, set `deployBackend=false` to avoid recreating VMs
> (the cloud-init `customData` cannot be changed on existing VMs). Pass the existing
> backend IPs so App Gateway keeps its backend pool.

```bash
# Get your existing backend IPs first
az vm list-ip-addresses -g rg-appgw-lab --query "[].virtualMachine.network.privateIpAddresses[0]" -o tsv

az deployment group create \
  --resource-group rg-appgw-lab \
  --template-file bicep/main.bicep \
  --parameters \
    sshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
    enableHttps=true \
    deployBackend=false \
    existingBackendIps='["10.0.1.4","10.0.1.5"]' \
    keyVaultSecretId="https://kv-appgw-xxx.vault.azure.net/secrets/appgw-cert/<version>"
```

App Gateway now serves HTTPS with a Let's Encrypt cert from Key Vault.

> **Alternative — CLI-based HTTPS config:** If the Bicep redeploy fails (e.g., App Gateway enters
> a Failed state due to RBAC propagation delays), you can configure HTTPS via CLI:
> ```bash
> KV_SECRET_ID="https://kv-appgw-xxx.vault.azure.net/secrets/appgw-cert/<version>"
> az network application-gateway ssl-cert create -g rg-appgw-lab --gateway-name appgw-lab \
>   --name appgw-cert --key-vault-secret-id "$KV_SECRET_ID"
> az network application-gateway frontend-port create -g rg-appgw-lab --gateway-name appgw-lab \
>   --name port-https --port 443
> az network application-gateway http-listener create -g rg-appgw-lab --gateway-name appgw-lab \
>   --name https-listener --frontend-port port-https --frontend-ip appGatewayPublicFrontendIP \
>   --ssl-cert appgw-cert
> az network application-gateway rule create -g rg-appgw-lab --gateway-name appgw-lab \
>   --name https-rule --http-listener https-listener --address-pool appGatewayBackendPool \
>   --http-settings appGatewayBackendHttpSettings --priority 100
> ```

### Step 6 — Verify

```bash
# Get the public IP
az network public-ip show -g rg-appgw-lab -n appgw-lab-pip --query ipAddress -o tsv

# Test via public IP
curl -k https://<App-Gateway-Public-IP>/
# Should return "Backend VM 1" or "Backend VM 2" (round-robin)

# Or create a DNS A record (e.g., yourdomain.com → public IP) and browse:
curl -k https://yourdomain.com/
```

---

## Deployment Parameters

| Parameter | Default | Description |
|---|---|---|
| `location` | Resource group location | Azure region |
| `sshPublicKey` | *(required)* | SSH public key for backend VMs |
| `keyVaultName` | Auto-generated | Globally unique Key Vault name |
| `enableHttps` | `false` | Enable HTTPS listener (requires cert in Key Vault) |
| `keyVaultSecretId` | `""` | Key Vault secret URI for the TLS cert |
| `skuName` | `Standard_v2` | `Standard_v2` or `WAF_v2` |
| `vmCount` | `2` | Number of backend VMs (1-4) |
| `deployBastion` | `false` | Deploy Azure Bastion for VM management |
| `deployBackend` | `true` | Deploy backend VMs (set `false` on Phase 2 redeploy to avoid customData conflict) |
| `existingBackendIps` | `[]` | Existing backend VM IPs (required when `deployBackend=false`) |

---

## Which Option Do I Need?

| App Gateway Config | Challenge Type | Option |
|---|---|---|
| Public IP (internet testable) | DNS-01 | **[Option B](#option-b--dns-01-challenge-recommended) (Recommended)** |
| Public IP | HTTP-01 | [Option A](#option-a--http-01-challenge) |
| Wildcard certificate (`*.yourdomain.com`) | DNS-01 only | [Option B](#option-b--dns-01-challenge-recommended) |

> This lab deploys an App Gateway with both public and private IPs, so both options work.
> **Option B (DNS-01) is recommended** — no temporary port 80 listener required, and supports wildcard certs.

## Prerequisites (Both Options)

| Requirement | Details |
|---|---|
| **Public DNS domain** | You must own a real domain (e.g., `yourdomain.com`). Let's Encrypt cannot issue certs for raw IPs or `*.azurewebsites.net`. Cheap domains are ~$10/year from Namecheap, Cloudflare, or GoDaddy. |

> **Important:** Your DNS zone must be **publicly resolvable** — even for private-only App Gateway deployments. Let's Encrypt validates against public DNS resolvers. Azure Private DNS zones or on-prem internal-only DNS will **not** work for DNS-01 validation.
| **Certbot** | Installed on any machine with internet access (laptop, Azure VM, Cloud Shell) |
| **OpenSSL** | For PFX conversion |
| **Azure CLI** | For uploading the certificate to App Gateway |

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

### Bicep Modules

| Module | Purpose |
|---|---|
| `bicep/main.bicep` | Orchestrator — deploys all modules in correct order |
| `bicep/identity.bicep` | User-assigned managed identity for App GW → Key Vault |
| `bicep/network.bicep` | VNet with App GW, backend, and optional Bastion subnets + NSGs |
| `bicep/keyvault.bicep` | Key Vault with RBAC role assignment for managed identity |
| `bicep/backend.bicep` | Linux VMs with NGINX (no public IPs, cloud-init provisioned) |
| `bicep/appgw.bicep` | App Gateway v2 — public + private IP, Key Vault TLS, autoscale, health probes |

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
| **Phase 2 redeploy fails** (customData conflict) | Set `deployBackend=false` and pass `existingBackendIps='["10.0.1.4","10.0.1.5"]'` to skip VM redeployment |
| **App Gateway stuck in Failed state** | Run `az network application-gateway stop -g rg-appgw-lab -n appgw-lab` then `az network application-gateway start -g rg-appgw-lab -n appgw-lab` to reset |
| **Key Vault ForbiddenByRbac** (for your user) | Your user needs `Key Vault Certificates Officer` to import certs: `az role assignment create --role "Key Vault Certificates Officer" --assignee <your-oid> --scope <kv-resource-id>` |
| **Namecheap multi-level TXT records** | Namecheap cannot create dotted host names like `_acme-challenge.appgw-lab`. Use the root domain or a single-level subdomain instead |
| **Cloud Shell: certbot not found** | Install via `pip install --user certbot` and add `$HOME/.local/bin` to PATH |
| **Cloud Shell: SSH key needed** | Generate with `ssh-keygen -t rsa -b 4096` before deploying |

## Useful Links

- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
- [ACME DNS-01 Challenge](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge)
- [Azure App Gateway TLS Overview](https://learn.microsoft.com/azure/application-gateway/ssl-overview)
- [App Gateway Key Vault Integration](https://learn.microsoft.com/azure/application-gateway/key-vault-certs)
- [Azure Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
