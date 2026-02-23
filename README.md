# Azure Application Gateway v2 TLS Lab
## End-to-End TLS, Multi-Site Hosting & F5 Migration Demo

Full-featured Azure Application Gateway v2 lab with Let's Encrypt certificates, multi-site listeners, SSL Profiles, response header rewrite rules, and end-to-end TLS — designed as a hands-on walkthrough for teams migrating from F5 BIG-IP.

Includes complete Bicep IaC (VNet, App Gateway, Key Vault, backend VMs), automated certificate issuance via DNS-01 or HTTP-01, and a self-documenting landing page that shows every App Gateway feature live.

> **New to Let's Encrypt?** Read [How Let's Encrypt Works](docs/HOW-LETS-ENCRYPT-WORKS.md) first — it explains certificates, ACME challenges, certbot, PFX conversion, and the trust chain in plain language before you dive into the lab steps.
>
> **First time doing this?** Follow the [Step-by-Step Walkthrough](docs/STEP-BY-STEP-GUIDE.md) — it walks through every command with expected outputs, troubleshooting, and DNS provider examples (Azure DNS, Cloudflare, GoDaddy).
>
> **Prefer the portal?** Follow the [End-to-End Portal Walkthrough](docs/PORTAL-WALKTHROUGH.md) — build the entire environment from scratch using only the Azure portal (VNet, VM, Key Vault, Managed Identity, App Gateway, backend pool, TLS everywhere).

---

## Table of Contents

- [What This Repo Deploys](#what-this-repo-deploys)
- [Quick Start — Deploy Everything](#quick-start--deploy-everything)
- [Feature Demo Guide](docs/FEATURE-DEMOS.md) — rewrite rules, F5 comparisons, how-to-demo scripts
- [Portal Walkthrough](docs/PORTAL-WALKTHROUGH.md) — build App Gateway + Key Vault from scratch in the portal
- [App Gateway → Key Vault via Managed Identity](#app-gateway--key-vault-via-managed-identity)
- [Deployment Parameters](#deployment-parameters)
- [Getting a TLS Certificate (Let's Encrypt)](#getting-a-tls-certificate-lets-encrypt)
- [Let's Encrypt Certificate Guide](docs/LETS-ENCRYPT-GUIDE.md) — DNS-01, HTTP-01, trust chain, scripts, troubleshooting
- [Bicep Modules](#bicep-modules)
- [Troubleshooting](#troubleshooting)
- [Useful Links](#useful-links)

---

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
│  │  │  App Gateway v2     │──►│  VM 1 (NGINX+SNI) ◄─ no pub │   │  │
│  │  │  Public + Private IP│   │  VM 2 (NGINX+SNI) ◄─ no pub │   │  │
│  │  │                     │   │                              │   │  │
│  │  │  Listeners:         │   │  Server blocks:              │   │  │
│  │  │  ├ app1.contoso.com │   │  ├ app1.contoso.com:443      │   │  │
│  │  │  └ app2.contoso.com │   │  └ app2.contoso.com:443      │   │  │
│  │  │                     │   │                              │   │  │
│  │  │  SSL Profiles:      │   │  Let's Encrypt certs         │   │  │
│  │  │  ├ (gateway default)│   │  (E2E TLS re-encryption)     │   │  │
│  │  │  └ sslprof-app2     │   └──────────────────────────────┘   │  │
│  │  │                     │                                      │  │
│  │  │  Rewrite Rules:     │                                      │  │
│  │  │  └ rwset-security-  │                                      │  │
│  │  │    headers           │                                      │  │
│  │  └──────────┬──────────┘                                      │  │
│  │             │                                                  │  │
│  └─────────────┼──────────────────────────────────────────────────┘  │
│                │ Key Vault                                           │
│  ┌─────────────▼──────────────────┐   ┌────────────────────────┐    │
│  │  kv-appgw-xxx                  │   │  id-appgw-lab          │    │
│  │  cert-app1 (secret)            │◄──│  User-Assigned MI      │    │
│  │  cert-app2 (secret)            │   │  Attached to App GW    │    │
│  │  RBAC: Key Vault Secrets User  │   │                        │    │
│  └────────────────────────────────┘   └────────────────────────┘    │
└──────────────────────────────────────────────────────────────────────┘
```

### Components

| Resource | Purpose |
|---|---|
| **User-Assigned Managed Identity** | App Gateway → Key Vault access (enterprise-preferred over system-assigned) |
| **VNet** with dedicated subnets | App GW subnet (required isolation), backend subnet, optional Bastion |
| **Application Gateway v2** | Standard_v2 or WAF_v2, public + private IP, autoscale |
| **Multi-site HTTPS listeners** | Separate listeners per hostname (e.g., `app1.contoso.com`, `app2.contoso.com`) with HTTP→HTTPS redirect |
| **SSL Profiles** | Per-listener TLS policy override — equivalent of F5 Client SSL Profiles |
| **Rewrite Rules** | Response header manipulation (HSTS, strip Server, X-Content-Type-Options) — equivalent of F5 iRules |
| **End-to-End TLS** | App Gateway re-encrypts traffic to NGINX backends over HTTPS:443 |
| **Azure Key Vault** | RBAC-based, stores TLS certs (one per site), referenced via secret URI |
| **Backend VMs** (Linux + NGINX) | 2 VMs, no public IPs, NGINX SNI server blocks per site, Let's Encrypt certs |
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
| CAF naming convention for sub-resources | `lstn-`, `be-htst-`, `hp-`, `rr-`, `rdrcfg-`, `bp-`, `cert-`, `sslprof-`, `rwset-` prefixes for clarity |
| Multi-site listeners (not Basic) | Each hostname gets its own listener, enabling per-site SSL Profiles and routing |
| Differentiated SSL Profiles | `app1.contoso.com` inherits gateway default policy; `app2.contoso.com` uses a strict custom SSL Profile — demonstrates F5-style per-VIP TLS control |
| Rewrite rules on HTTPS routing rules only | Security headers only apply to HTTPS responses; HTTP requests are redirected before reaching a backend |
| Backend hostname override (not `pickHostNameFromBackendTarget`) | Explicit SNI hostname in backend HTTP settings for VM/IaaS backends per Microsoft guidance |

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

## Feature Demo Guide

Rewrite rules, F5 comparisons, and step-by-step demo scripts are in the **[Feature Demo Guide](docs/FEATURE-DEMOS.md)**.

---

## App Gateway → Key Vault via Managed Identity

App Gateway uses a **User-Assigned Managed Identity** to retrieve TLS certificates from Key Vault. The chain is: **create identity → attach to gateway → authorize in Key Vault (Secrets User role) → reference cert in listener**.

> ⚠️ **Portal limitation:** The Azure portal [does not support](https://learn.microsoft.com/en-us/azure/application-gateway/key-vault-certs#key-vault-azure-role-based-access-control-permission-model) adding Key Vault cert references when the Key Vault uses RBAC. Use CLI/Bicep for the initial listener setup — after that, it can be managed in the portal.

For the full step-by-step walkthrough (every portal click + the CLI commands for the HTTPS listener), see the **[Portal Walkthrough](docs/PORTAL-WALKTHROUGH.md)**.

**Key concepts:**

- **Why Secrets User?** App Gateway reads certs from the Key Vault **secrets** endpoint (not certificates) to get the private key. The role must be **Key Vault Secrets User**, not Certificates Officer.
- **Why User-Assigned MI?** Survives gateway deletion, reusable across resources, explicit audit trail. Enterprise-preferred over system-assigned.
- **Certificate Rotation:** App Gateway polls Key Vault every ~4 hours. Import a renewed cert to the same KV name → auto-rotates with zero downtime.
- **Cert source check:** The portal doesn't show whether a cert is from Key Vault or uploaded. Use CLI:

```bash
az network application-gateway ssl-cert show \
  --gateway-name <appgw-name> \
  --resource-group <resource-group> \
  --name <ssl-cert-name>

# keyVaultSecretId in output → Key Vault
# publicCertData in output  → uploaded directly
```

| Symptom | Cause | Fix |
|---|---|---|
| "Key Vault is not accessible" | MI not authorized in Key Vault | Add **Key Vault Secrets User** role to the MI |
| "User-assigned identity not found" | MI not attached to App Gateway | App Gateway → Identity → User assigned → Add |
| App Gateway enters **Failed** state | RBAC propagation delay (~1-2 min) | Wait 2 min, then stop/start the App Gateway |
| **ForbiddenByRbac** in Activity Log | Wrong role (e.g., Key Vault Reader) | Reassign: **Key Vault Secrets User** |
| Cert breaks after KV network rules change | KV firewall blocks App Gateway | Add App GW subnet to KV network rules or use Private Endpoint |

> **F5 comparison:** On F5 BIG-IP, certs are uploaded directly to `/config/ssl/` — no external secret store, no identity-based access. Whoever has admin access can view/export everything. The Azure pattern (MI → RBAC → Key Vault) provides separation of duties with auditable, least-privilege access.

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

## Getting a TLS Certificate (Let's Encrypt)

This lab uses **Let's Encrypt** to issue free, trusted TLS certificates. Two challenge methods are supported:

| Method | When to Use |
|---|---|
| **DNS-01** (Recommended) | Works with any App Gateway (public or private). No port 80 required. Supports wildcards. |
| **HTTP-01** | Requires public IP. Simpler if you don't have DNS API access. |

**Full guide:** [Let's Encrypt Certificate Guide](docs/LETS-ENCRYPT-GUIDE.md) — challenge walkthroughs, PFX conversion, trust chain explained, automation scripts, and troubleshooting.

**Supporting docs:**
- [How Let's Encrypt Works](docs/HOW-LETS-ENCRYPT-WORKS.md) — concepts and terminology
- [Step-by-Step Walkthrough](docs/STEP-BY-STEP-GUIDE.md) — every command with expected outputs

---

## Bicep Modules

| Module | Purpose |
|---|---|
| `bicep/main.bicep` | Orchestrator — deploys all modules in correct order |
| `bicep/identity.bicep` | User-assigned managed identity for App GW → Key Vault |
| `bicep/network.bicep` | VNet with App GW, backend, and optional Bastion subnets + NSGs |
| `bicep/keyvault.bicep` | Key Vault with RBAC role assignment for managed identity |
| `bicep/backend.bicep` | Linux VMs with NGINX (no public IPs, cloud-init provisioned) |
| `bicep/appgw.bicep` | App Gateway v2 — multi-site listeners, SSL Profiles, rewrite rules, E2E TLS, Key Vault certs, health probes |

## Troubleshooting

| Issue | Fix |
|---|---|
| **Phase 2 redeploy fails** (customData conflict) | Set `deployBackend=false` and pass `existingBackendIps='["10.0.1.4","10.0.1.5"]'` to skip VM redeployment |
| **App Gateway stuck in Failed state** | Run `az network application-gateway stop -g rg-appgw-lab -n appgw-lab` then `az network application-gateway start -g rg-appgw-lab -n appgw-lab` to reset |
| **Key Vault ForbiddenByRbac** (for your user) | Your user needs `Key Vault Certificates Officer` to import certs: `az role assignment create --role "Key Vault Certificates Officer" --assignee <your-oid> --scope <kv-resource-id>` |
| **Cloud Shell: SSH key needed** | Generate with `ssh-keygen -t rsa -b 4096` before deploying |

> **Certificate troubleshooting** (DNS-01, HTTP-01, PFX, rate limits, Namecheap, certbot): see [Let's Encrypt Certificate Guide — Troubleshooting](docs/LETS-ENCRYPT-GUIDE.md#troubleshooting).

## Useful Links

- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
- [ACME DNS-01 Challenge](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge)
- [Azure App Gateway TLS Overview](https://learn.microsoft.com/azure/application-gateway/ssl-overview)
- [App Gateway Key Vault Integration](https://learn.microsoft.com/azure/application-gateway/key-vault-certs)
- [Azure Key Vault RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide)
