# Azure Application Gateway v2 TLS Lab
## Public & Private Deployments Using Let's Encrypt (HTTP-01 & DNS-01)

Free TLS certificates for Azure Application Gateway v2 using Let's Encrypt. Includes full Bicep infrastructure (VNet, App Gateway, Key Vault, backend VMs) and automated certificate issuance via DNS-01 or HTTP-01.

No certificate purchase required. No public IP required (for DNS-01).

> **New to Let's Encrypt?** Read [How Let's Encrypt Works](docs/HOW-LETS-ENCRYPT-WORKS.md) first — it explains certificates, ACME challenges, certbot, PFX conversion, and the trust chain in plain language before you dive into the lab steps.

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
│  │  │  Private IP only    │   │  VM 2 (NGINX)  ◄── no pub IP│   │  │
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
| **Application Gateway v2** | Standard_v2 or WAF_v2, private IP only, autoscale, HTTPS listener |
| **Azure Key Vault** | RBAC-based, stores TLS cert, referenced via secret URI |
| **Backend VMs** (Linux + NGINX) | 2 VMs, no public IPs, unique page per VM for LB demo |
| **NSGs** | App GW subnet allows GatewayManager + HTTPS; backend allows only App GW traffic |

### Design Decisions

| Decision | Rationale |
|---|---|
| Private IP only on App Gateway | Enterprise pattern, zero public exposure |
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

```bash
# Automated (Azure DNS)
./scripts/option-b-private/azure-dns-certbot.ps1 \
  -Domain "appgw-lab.yourdomain.com" \
  -DnsZoneName "yourdomain.com" \
  -DnsResourceGroupName "dns-rg"

# Or manual
sudo certbot certonly --manual --preferred-challenges dns -d appgw-lab.yourdomain.com
```

### Step 3 — Convert to PFX

```bash
openssl pkcs12 -export \
  -out appgw-cert.pfx \
  -inkey /etc/letsencrypt/live/appgw-lab.yourdomain.com/privkey.pem \
  -in /etc/letsencrypt/live/appgw-lab.yourdomain.com/fullchain.pem
```

### Step 4 — Import to Key Vault

```powershell
./scripts/shared/import-to-kv.ps1 \
  -KeyVaultName "kv-appgw-xxx" \
  -PfxPath "./appgw-cert.pfx" \
  -PfxPassword "yourpassword"
```

Save the **secret URI** from the output.

### Step 5 — Re-deploy with HTTPS

```bash
az deployment group create \
  --resource-group rg-appgw-lab \
  --template-file bicep/main.bicep \
  --parameters \
    sshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
    enableHttps=true \
    keyVaultSecretId="https://kv-appgw-xxx.vault.azure.net/secrets/appgw-cert/<version>"
```

App Gateway now serves HTTPS with a Let's Encrypt cert from Key Vault.

### Step 6 — Verify

```bash
# From a machine that can reach the private IP
curl -k https://10.0.0.10/
# Should return "Backend VM 1" or "Backend VM 2" (round-robin)
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

---

## Which Option Do I Need?

| App Gateway Config | Challenge Type | Option |
|---|---|---|
| **Private IP only** (no public endpoint) | DNS-01 | **[Option B](#option-b--private-app-gateway-dns-01-challenge) (Recommended)** |
| Public IP | HTTP-01 | [Option A](#option-a--public-app-gateway-http-01-challenge) |
| Wildcard certificate (`*.yourdomain.com`) | DNS-01 only | [Option B](#option-b--private-app-gateway-dns-01-challenge) |

> **If your App Gateway uses a private IP only, skip straight to Option B.**
> HTTP-01 requires Let's Encrypt to reach your domain over the public internet on port 80 — that's impossible with a private-only gateway.

## Prerequisites (Both Options)

| Requirement | Details |
|---|---|
| **Public DNS domain** | You must own a real domain (e.g., `yourdomain.com`). Let's Encrypt cannot issue certs for raw IPs or `*.azurewebsites.net`. Cheap domains are ~$10/year from Namecheap, Cloudflare, or GoDaddy. |

> **Important:** Your DNS zone must be **publicly resolvable** — even for private App Gateway deployments (Option B). Let's Encrypt validates against public DNS resolvers. Azure Private DNS zones or on-prem internal-only DNS will **not** work for DNS-01 validation.
| **Certbot** | Installed on any machine with internet access (laptop, Azure VM, Cloud Shell) |
| **OpenSSL** | For PFX conversion |
| **Azure CLI** | For uploading the certificate to App Gateway |

### Install Certbot

```bash
# Linux / WSL
sudo apt update && sudo apt install certbot -y

# macOS
brew install certbot

# Windows (Chocolatey)
choco install certbot -y
```

---

## Option B — Private App Gateway (DNS-01 Challenge)

**Recommended for labs and enterprise patterns.**

DNS-01 validates domain ownership via a DNS TXT record — no public IP, no port 80, no temporary listeners. This is the architecturally correct pattern for private Application Gateways.

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
│  appgw-lab.domain   │
│  → "<validation>"   │
└──────────┬─────────┘
           │
           ▼
┌────────────────────┐       ┌─────────────────────────┐
│  Your Machine       │──────►│  Private App Gateway     │
│  (certbot + az cli) │  PFX  │  VNet-internal only      │
│                     │ upload│  No public IP             │
└────────────────────┘       │  HTTPS Listener (443)     │
                             └─────────────────────────┘
```

**Key advantages:**
- No public IP required
- No port 80 listener required
- No temporary infrastructure
- Works with wildcard certs
- Enterprise-ready pattern
- More secure — zero public exposure during issuance

> **Enterprise Note:** For production workloads, consider storing certificates in [Azure Key Vault](https://learn.microsoft.com/azure/key-vault/certificates/about-certificates) and referencing them from Application Gateway via Key Vault integration, rather than uploading PFX manually. This enables automated rotation and centralized certificate management.

### Quick Start (Manual DNS-01)

#### Step 1 — DNS Setup

Create an A record so clients can resolve your App Gateway:

```
appgw-lab.yourdomain.com  →  <App Gateway Private IP>
```

This A record is for **client resolution only** — it is NOT required for DNS-01 validation. Let's Encrypt only checks the `_acme-challenge` TXT record (Step 3). You could issue the certificate even before the A record exists.

> For internal clients, you can alternatively use Azure Private DNS for the A record. But the parent zone hosting the `_acme-challenge` TXT record must be **public**.

#### Step 2 — Request Certificate with DNS-01

```bash
sudo certbot certonly \
  --manual \
  --preferred-challenges dns \
  -d appgw-lab.yourdomain.com
```

Certbot will display:

```
Please deploy a DNS TXT record under the name:
  _acme-challenge.appgw-lab.yourdomain.com
with the following value:
  <random-validation-string>
```

#### Step 3 — Add the TXT Record

Add the TXT record to your DNS provider.

**Azure DNS:**

```bash
az network dns record-set txt add-record \
  --resource-group "dns-rg" \
  --zone-name "yourdomain.com" \
  --record-set-name "_acme-challenge.appgw-lab" \
  --value "<validation-string>"
```

> **Note:** The `--record-set-name` is the **relative** name within the zone. Do NOT include the zone name. For example, use `_acme-challenge.appgw-lab`, not `_acme-challenge.appgw-lab.yourdomain.com`.

**Other providers:** Add `_acme-challenge.appgw-lab.yourdomain.com` as a TXT record in their portal.

Wait for DNS propagation (typically 30-60 seconds for Azure DNS), then press Enter in certbot.

#### Step 4 — Convert to PFX and Upload

```bash
# Convert PEM → PFX
openssl pkcs12 -export \
  -out appgw-cert.pfx \
  -inkey /etc/letsencrypt/live/appgw-lab.yourdomain.com/privkey.pem \
  -in /etc/letsencrypt/live/appgw-lab.yourdomain.com/fullchain.pem
```

```powershell
# Upload to App Gateway
./scripts/shared/upload-cert.ps1 `
  -ResourceGroupName "myRG" `
  -AppGatewayName "myAppGW" `
  -PfxPath "./appgw-cert.pfx" `
  -PfxPassword "yourpassword"
```

#### Step 5 — Clean Up TXT Record

```bash
az network dns record-set txt remove-record \
  --resource-group "dns-rg" \
  --zone-name "yourdomain.com" \
  --record-set-name "_acme-challenge.appgw-lab" \
  --value "<validation-string>"
```

### Fully Automated (Azure DNS)

For a production-grade, one-command experience:

```powershell
./scripts/option-b-private/azure-dns-certbot.ps1 `
  -Domain "appgw-lab.contoso.com" `
  -DnsZoneName "contoso.com" `
  -DnsResourceGroupName "dns-rg" `
  -AppGatewayName "myAppGW" `
  -AppGatewayResourceGroupName "appgw-rg"
```

This script:
1. Creates the ACME TXT record in Azure DNS automatically
2. Waits for DNS propagation
3. Completes the certbot challenge
4. Converts to PFX
5. Uploads to App Gateway
6. Cleans up the TXT record

Add `--Staging` for testing without hitting rate limits.

### Using the Bash Script

```bash
./scripts/option-b-private/get-certificate-dns01.sh -d appgw-lab.yourdomain.com
```

This runs certbot in interactive DNS-01 mode — you'll manually add the TXT record when prompted.

---

## Option A — Public App Gateway (HTTP-01 Challenge)

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
                          appgw-lab.yourdomain.com
                                → App GW Public IP
```

> **Limitation:** This does NOT work for private-only App Gateways. Use [Option B](#option-b--private-app-gateway-dns-01-challenge) instead.

### Quick Start

#### Step 1 — Create Public DNS Record

```
appgw-lab.yourdomain.com  →  <App Gateway Public IP>
```

Verify: `nslookup appgw-lab.yourdomain.com`

#### Step 2 — Temporarily Open HTTP on App Gateway

Let's Encrypt must reach port 80 on your domain.

```powershell
./scripts/option-a-public/setup-http-listener.ps1 -ResourceGroupName "myRG" -AppGatewayName "myAppGW"
```

#### Step 3 — Obtain the Certificate

```bash
# Standalone mode
sudo certbot certonly --standalone -d appgw-lab.yourdomain.com

# Or use the included script
./scripts/option-a-public/get-certificate.sh -d appgw-lab.yourdomain.com
```

Certificate files:

```
/etc/letsencrypt/live/appgw-lab.yourdomain.com/
├── fullchain.pem
└── privkey.pem
```

#### Step 4 — Convert to PFX

```bash
openssl pkcs12 -export \
  -out appgw-cert.pfx \
  -inkey /etc/letsencrypt/live/appgw-lab.yourdomain.com/privkey.pem \
  -in /etc/letsencrypt/live/appgw-lab.yourdomain.com/fullchain.pem
```

Or: `./scripts/shared/convert-to-pfx.ps1 -Domain "appgw-lab.yourdomain.com"`

#### Step 5 — Upload to Application Gateway

**Portal:**
1. Application Gateway → **Listeners** → HTTPS → Upload PFX

**CLI:**
```powershell
./scripts/shared/upload-cert.ps1 `
  -ResourceGroupName "myRG" `
  -AppGatewayName "myAppGW" `
  -PfxPath "./appgw-cert.pfx" `
  -PfxPassword "yourpassword"
```

#### Step 6 — Clean Up HTTP Listener

```powershell
./scripts/option-a-public/cleanup-http-listener.ps1 -ResourceGroupName "myRG" -AppGatewayName "myAppGW"
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
│  appgw-lab.yourdomain.com  (Your Leaf Certificate)               │
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
| `scripts/shared/convert-to-pfx.ps1` | Convert PEM to PFX format |
| `scripts/shared/upload-cert.ps1` | Upload PFX cert to Application Gateway (direct PFX method) |
| `scripts/shared/import-to-kv.ps1` | Import PFX into Key Vault and output the secret URI |

### Option A — Public (HTTP-01)

| Script | Purpose |
|---|---|
| `scripts/option-a-public/get-certificate.sh` | Obtain cert via certbot standalone (HTTP-01) |
| `scripts/option-a-public/setup-http-listener.ps1` | Add temporary HTTP listener for ACME challenge |
| `scripts/option-a-public/cleanup-http-listener.ps1` | Remove temporary HTTP listener |

### Option B — Private (DNS-01)

| Script | Purpose |
|---|---|
| `scripts/option-b-private/get-certificate-dns01.sh` | Obtain cert via interactive DNS-01 challenge |
| `scripts/option-b-private/azure-dns-certbot.ps1` | **Fully automated:** Azure DNS + certbot + PFX + upload |

### Bicep Modules

| Module | Purpose |
|---|---|
| `bicep/main.bicep` | Orchestrator — deploys all modules in correct order |
| `bicep/identity.bicep` | User-assigned managed identity for App GW → Key Vault |
| `bicep/network.bicep` | VNet with App GW, backend, and optional Bastion subnets + NSGs |
| `bicep/keyvault.bicep` | Key Vault with RBAC role assignment for managed identity |
| `bicep/backend.bicep` | Linux VMs with NGINX (no public IPs, cloud-init provisioned) |
| `bicep/appgw.bicep` | App Gateway v2 — private IP, Key Vault TLS, autoscale, health probes |

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

## Useful Links

- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
- [Certbot Instructions](https://certbot.eff.org/)
- [ACME DNS-01 Challenge](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge)
- [Azure App Gateway TLS Overview](https://learn.microsoft.com/azure/application-gateway/ssl-overview)
- [Azure DNS Quickstart](https://learn.microsoft.com/azure/dns/dns-getstarted-portal)
- [App Gateway Private IP Configuration](https://learn.microsoft.com/azure/application-gateway/application-gateway-private-deployment)
- [App Gateway Key Vault Integration](https://learn.microsoft.com/azure/application-gateway/key-vault-certs)
- [Azure Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
- [Bicep Documentation](https://learn.microsoft.com/azure/azure-resource-manager/bicep/overview)
