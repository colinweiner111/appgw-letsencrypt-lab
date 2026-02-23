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
- [Feature Demo Guide](#feature-demo-guide)
  - [Rewrite Rules — Response Headers](#rewrite-rules--response-headers)
- [Portal Walkthrough: App Gateway → Key Vault via Managed Identity](#portal-walkthrough-app-gateway--key-vault-via-managed-identity)
- [End-to-End Portal Walkthrough](docs/PORTAL-WALKTHROUGH.md) *(separate guide — build everything from scratch in the portal)*
  - [Certificate Rotation](#certificate-rotation)
  - [Common Issues](#common-issues)
- [Deployment Parameters](#deployment-parameters)
- [Which Option Do I Need?](#which-option-do-i-need)
- [Prerequisites (Both Options)](#prerequisites-both-options)
- [Option B — DNS-01 Challenge (Recommended)](#option-b--dns-01-challenge-recommended)
- [Option A — HTTP-01 Challenge](#option-a--http-01-challenge)
- [Understanding the TLS Trust Chain](#understanding-the-tls-trust-chain)
- [Certificate Renewal](#certificate-renewal)
- [Scripts Reference](#scripts-reference)
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

This lab deploys several App Gateway features beyond basic TLS termination. Each feature is documented on the **live landing page** (served by the backend VMs) with a dedicated card showing the configuration and its effect in real time.

### Rewrite Rules — Response Headers

App Gateway **Rewrite Rules** modify HTTP headers and URLs in-flight — the equivalent of **F5 iRules** or **LTM Policies**. They are defined in a **Rewrite Rule Set** (`rwset-security-headers`) and attached to HTTPS routing rules, so every response flowing through those rules is automatically modified.

#### What's Deployed

| Rule Name | Sequence | Action | Header | Value |
|---|---|---|---|---|
| `rw-add-hsts` | 100 | **Set** response header | `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` |
| `rw-strip-server` | 200 | **Delete** response header | `Server` | *(empty — removes the header entirely)* |
| `rw-add-xcto` | 300 | **Set** response header | `X-Content-Type-Options` | `nosniff` |

#### What Each Rule Does

**`rw-add-hsts`** — Injects `Strict-Transport-Security: max-age=31536000; includeSubDomains` into every response. Tells browsers "never connect to this domain over HTTP again for 1 year." Once a browser sees this header, it automatically upgrades any `http://` request to `https://` locally — the request never leaves the browser as plaintext. Prevents SSL-stripping attacks (e.g., a rogue Wi-Fi intercepting the initial HTTP request before the 301 redirect fires).

**`rw-strip-server`** — Deletes the `Server` response header entirely. Without this rule, every response includes `Server: nginx/1.x.x`, which tells attackers exactly what software and version the backend runs. That's the first thing a scanner looks for — known CVEs for that specific version. Setting the header value to an empty string causes App Gateway to strip it completely.

**`rw-add-xcto`** — Adds `X-Content-Type-Options: nosniff` to every response. Prevents browsers from "MIME-type sniffing" — where the browser ignores the declared `Content-Type` and guesses based on content. Without this, an attacker could upload a file that looks like HTML but is served as `text/plain`, and the browser might execute it as HTML/JavaScript anyway. `nosniff` forces the browser to trust the server's declared type.

All three are **response header** rewrites — they modify what the client receives, not what the backend sees.

#### How to Demo

**1. Show the "Before" (raw backend response without App Gateway):**

```bash
# Curl directly to a backend VM — bypasses App Gateway entirely
curl -skI --resolve app1.contoso.com:443:10.0.1.4 https://app1.contoso.com
```

You'll see:
- `Server: nginx/1.x.x` — **exposed** (technology disclosure)
- No `Strict-Transport-Security` header
- No `X-Content-Type-Options` header

**2. Show the "After" (through App Gateway with rewrite rules):**

```bash
# Curl through App Gateway — rewrite rules are applied
curl -skI --resolve app1.contoso.com:443:<App-Gateway-Public-IP> https://app1.contoso.com
```

You'll see:
- **No** `Server` header — stripped by `rw-strip-server`
- `Strict-Transport-Security: max-age=31536000; includeSubDomains` — injected by `rw-add-hsts`
- `X-Content-Type-Options: nosniff` — injected by `rw-add-xcto`

**3. Browser DevTools (visual proof for customers):**

1. Open **https://app1.contoso.com** in Edge or Chrome
2. Press **F12** → **Network** tab
3. Refresh the page (Ctrl+R)
4. Click the first request (the HTML document)
5. Click **Headers** → scroll to **Response Headers**
6. Point out: HSTS and X-Content-Type-Options present, Server absent

**4. Landing Page Card:**

Scroll to the **"Rewrite Rules — Response Headers"** card on the page. It documents all three rules inline — rule names, sequence numbers, actions, and F5 comparison — so the customer sees the config documented live alongside the proof in DevTools.

**5. Portal Walkthrough:**

1. Portal → **rg-appgw-lab** → **appgw-lab** → **Rewrites** (left nav)
2. Click **rwset-security-headers**
3. Show the three rules: `rw-add-hsts`, `rw-strip-server`, `rw-add-xcto`
4. Click into one to show the condition/action UI
5. Navigate to **Rules** → click `rr-app1-https` → show the rewrite set association

#### F5 Comparison

| F5 BIG-IP | Azure App Gateway |
|---|---|
| iRule: `HTTP::header insert` in `HTTP_RESPONSE` | Rewrite Rule → Set response header |
| iRule: `HTTP::header remove` in `HTTP_RESPONSE` | Rewrite Rule → Set header value to empty string |
| iRule attached to virtual server | Rewrite Rule Set attached to routing rule |
| iRule = Tcl scripting, requires developer skill | Rewrite Rule = declarative config, portal or Bicep IaC |
| iRule debugging: `log local0.` + tcpdump | Rewrite Rule verification: check response headers in browser DevTools |
| iRule error can crash a virtual server | Rewrite Rule misconfiguration is isolated, no crash risk |

> **Key talking point:** *"Everything you did with iRules for header manipulation is a declarative checkbox in App Gateway — no Tcl, no scripting, no risk of a syntax error taking down a VIP."*

---

## Portal Walkthrough: App Gateway → Key Vault via Managed Identity

Application Gateway uses a **User-Assigned Managed Identity** to retrieve the certificate secret from Key Vault. Not a system-assigned identity, not a service principal — a dedicated, explicitly-created managed identity that you attach to the gateway and authorize in Key Vault.

This is the part that trips people up. There is no "connect to Key Vault" button on the App Gateway. Instead, you build a chain: **create an identity → attach it to the gateway → authorize it in Key Vault → reference the cert in a listener**. Each step matters, and the portal doesn't guide you through them in order.

This section walks through that chain entirely in the Azure portal. It's the same configuration the Bicep templates deploy automatically, but understanding the portal steps is essential for troubleshooting, auditing, and customer demos.

### Why User-Assigned (Not System-Assigned)?

Application Gateway cannot access Key Vault directly. It needs an identity that Key Vault recognizes and trusts. Azure supports two types:

| Identity Type | How It Works | When to Use |
|---|---|---|
| **User-Assigned Managed Identity** | You create the identity explicitly, attach it to App Gateway, and authorize it in Key Vault | **Recommended.** Reusable across resources, survives App Gateway deletion, explicit audit trail |
| **System-Assigned Managed Identity** | Azure creates the identity automatically when you enable it on the resource | Simpler setup, but tied to the gateway lifecycle — identity and all its RBAC assignments are deleted if the gateway is deleted |

This lab uses **User-Assigned** because it's the enterprise-preferred pattern. The identity exists independently, can be pre-provisioned by a security team, and its RBAC assignments are visible in Key Vault without needing to know the App Gateway's resource ID. ([App Gateway Key Vault integration](https://learn.microsoft.com/en-us/azure/application-gateway/key-vault-certs) | [Managed identity best practices](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations))

> **Don't go hunting for a system identity toggle.** While App Gateway does support system-assigned identity, it's not the recommended path for Key Vault integration. The steps below use a user-assigned identity exclusively.

### Step 1 — Create a User-Assigned Managed Identity

1. In the Azure portal, search **"Managed Identities"** in the top search bar and select it
2. Click **+ Create**
3. Fill in:
   - **Subscription:** Your subscription
   - **Resource Group:** `rg-appgw-lab` (same as your App Gateway)
   - **Region:** `East US 2` (must match your App Gateway region)
   - **Name:** `id-appgw-lab`
4. Click **Review + create** → **Create**
5. Once deployed, open the identity and note the **Client ID** — you'll see it on the Overview blade

> **Why the same resource group and region?** While managed identities can technically live anywhere, keeping them co-located with the resources they serve simplifies lifecycle management and avoids cross-region dependency issues.

### Step 2 — Attach the Managed Identity to Application Gateway

Do this **before** setting up Key Vault permissions. The identity must be attached to the gateway first so it exists as a recognized principal when you assign RBAC in Key Vault.

1. Navigate to your Application Gateway (`appgw-lab`) → **Identity** in the left nav (under **Settings**)
2. Click the **User assigned** tab at the top
3. Click **+ Add**
4. In the flyout, select **id-appgw-lab** → click **Add**
5. Wait for the update to complete (you'll see the identity listed with its Client ID)

> **What this does:** Tells App Gateway "you can authenticate as this identity." Without it, the gateway has no credentials to present to Key Vault — even if the RBAC role is perfectly configured.

### Step 3 — Authorize the Identity in Key Vault

The managed identity needs the **Key Vault Secrets User** role on your Key Vault. This is the hidden detail most people miss: App Gateway reads certificates from the Key Vault **secrets** endpoint (not the certificates endpoint). That's why the role is **Secrets** User — the certificate's private key material is stored as a secret.

#### If Your Key Vault Uses Azure RBAC (Recommended)

1. Navigate to your Key Vault (`kv-appgw-xxx`) → **Access control (IAM)** in the left nav
2. Click **+ Add** → **Add role assignment**
3. In the **Role** tab, search for **"Key Vault Secrets User"** and select it → click **Next**
4. In the **Members** tab:
   - **Assign access to:** Managed identity
   - Click **+ Select members**
   - In the flyout, set **Managed identity** dropdown to **User-assigned managed identity**
   - Select **id-appgw-lab** from the list
   - Click **Select**
5. Click **Review + assign** → **Review + assign**

#### If Your Key Vault Uses Access Policies (Legacy)

1. Navigate to your Key Vault → **Access policies** in the left nav
2. Click **+ Add Access Policy**
3. Under **Secret permissions**, check **Get**
4. Under **Select principal**, search for **id-appgw-lab** and select it
5. Click **Add** → **Save**

> **Which model is my Key Vault using?** Go to Key Vault → **Access configuration** in the left nav. It will show either **"Azure role-based access control"** or **"Vault access policy"**. This lab uses RBAC (the modern best practice) via Bicep/CLI.

### Step 4 — Add a Key Vault Certificate to a Listener

Now that the identity chain is established (App Gateway → Managed Identity → Key Vault RBAC), you can reference certificates stored in Key Vault.

> ⚠️ **Portal limitation:** The Azure portal [does not support](https://learn.microsoft.com/en-us/azure/application-gateway/key-vault-certs#key-vault-azure-role-based-access-control-permission-model) adding Key Vault certificate references when the Key Vault uses RBAC. You must use **CLI, Bicep, or ARM** for the initial setup. Once the listener exists, you can manage it in the portal. For a portal-only approach, see the [Portal Walkthrough](docs/PORTAL-WALKTHROUGH.md) (which uses Vault Access Policy instead).

First, add the Key Vault certificate to App Gateway. Use the **unversioned** secret URI so the certificate auto-rotates when renewed in Key Vault:

```bash
# Get the unversioned secret URI (strips the version segment)
SECRET_ID=$(az keyvault secret show \
  --vault-name <key-vault-name> \
  --name <cert-name> \
  --query id --output tsv | sed 's|/[^/]*$||')

# Add the Key Vault SSL certificate to App Gateway
az network application-gateway ssl-cert create \
  --resource-group <resource-group> \
  --gateway-name <appgw-name> \
  --name <ssl-cert-name> \
  --key-vault-secret-id "$SECRET_ID"
```

Then create the HTTPS listener that uses it:

```bash
az network application-gateway http-listener create \
  --resource-group <resource-group> \
  --gateway-name <appgw-name> \
  --name <listener-name> \
  --frontend-port <https-port-name> \
  --ssl-cert <ssl-cert-name> \
  --host-name <your-domain.com>
```

Finally, create a routing rule to connect the listener to a backend:

```bash
az network application-gateway rule create \
  --resource-group <resource-group> \
  --gateway-name <appgw-name> \
  --name <rule-name> \
  --priority <priority> \
  --http-listener <listener-name> \
  --backend-pool <backend-pool-name> \
  --backend-http-settings <http-settings-name> \
  --rule-type Basic
```

> **After initial creation:** You can modify listener settings, swap certificates, and manage routing rules through the Azure portal normally.

### Step 5 — Verify the Configuration

After the update completes, confirm everything is wired correctly:

1. **App Gateway → Identity → User assigned**: `id-appgw-lab` should be listed
2. **App Gateway → Listeners**: HTTPS listeners should show the certificate name with a Key Vault icon
3. **Key Vault → Access control (IAM) → Role assignments**: Search for `id-appgw-lab` — it should have **Key Vault Secrets User**
4. **Browse to your site** (e.g., `https://app1.contoso.com`): The certificate should be valid with no browser warnings

```bash
# CLI verification — confirm the cert is being served correctly
curl -svI --resolve app1.contoso.com:443:<App-Gateway-Public-IP> https://app1.contoso.com 2>&1 | grep -E "subject:|issuer:|expire"
```

### How It All Connects

```
                  Client
                    │
                    ▼
        ┌───────────────────────┐
        │  Application Gateway  │
        │  (appgw-lab)          │
        └───────────┬───────────┘
                    │  authenticates as
                    ▼
        ┌───────────────────────┐
        │  User-Assigned MI     │
        │  (id-appgw-lab)       │
        └───────────┬───────────┘
                    │  presents token to
                    ▼
        ┌───────────────────────┐
        │  Azure AD / Entra ID  │
        │  validates identity   │
        └───────────┬───────────┘
                    │  authorized via
                    ▼
        ┌───────────────────────┐
        │  Key Vault RBAC       │
        │  Role: Secrets User   │
        └───────────┬───────────┘
                    │  GET /secrets/...
                    ▼
        ┌───────────────────────┐
        │  Secret (PFX)         │
        │  ├ cert-app1           │
        │  └ cert-app2           │
        └───────────────────────┘
```

This is why the role is **Key Vault Secrets User** and not Key Vault Certificates User — App Gateway retrieves the PFX from the **secrets** endpoint, where the private key material lives.

At runtime:
1. App Gateway needs the TLS cert for a listener handshake
2. It authenticates to Azure AD **as** `id-appgw-lab` (the user-assigned managed identity)
3. It calls `GET https://kv-appgw-xxx.vault.azure.net/secrets/appgw-cert/<version>`
4. Key Vault checks RBAC → `id-appgw-lab` has **Key Vault Secrets User** → **allowed**
5. Key Vault returns the PFX certificate data (the secret backing the certificate)
6. App Gateway uses the cert for the TLS handshake with the client

### Certificate Rotation

> **App Gateway polls Key Vault every ~4 hours for new certificate versions.** If you import a renewed certificate to the same Key Vault certificate name, App Gateway picks it up automatically — no redeployment, no restart, no downtime. You can also trigger an immediate refresh by saving any configuration change on the App Gateway (even a no-op update).

This is the answer to the inevitable question: *"How does rotation work?"* — it's automatic, polling-based, and requires zero intervention as long as the new cert version lands in the same Key Vault certificate name.

### Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| **"Key Vault is not accessible"** during listener save | Managed identity not authorized in Key Vault | Add **Key Vault Secrets User** role (Step 3) |
| **"User-assigned identity not found"** | Identity not attached to App Gateway | Attach via **Identity** blade (Step 2) |
| App Gateway deployment enters **Failed** state | RBAC propagation delay (can take 1-2 minutes after assignment) | Wait 2 minutes, then stop/start the App Gateway |
| Certificate shows in Key Vault but not in App Gateway dropdown | App Gateway reads **secrets**, not **certificates** | Ensure the role grants secret access, not just certificate access |
| **ForbiddenByRbac** in Activity Log | Wrong role assigned (e.g., Key Vault Reader instead of Key Vault Secrets User) | Reassign with the correct role: **Key Vault Secrets User** |
| Cert works initially but breaks after Key Vault network rules change | Key Vault firewall now blocks App Gateway | Add App Gateway's subnet to Key Vault network rules, or use Private Endpoint |

> **F5 comparison:** On F5 BIG-IP, certificates are uploaded directly to the device and stored in the local certificate store (`/config/ssl/`). There's no external secret store or identity-based access control — whoever has admin access to the F5 can view and export all certificates. The Azure pattern (Managed Identity → RBAC → Key Vault) provides separation of duties: the network team manages the App Gateway, the security team manages Key Vault, and the managed identity bridges them with auditable, least-privilege access.

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
| `bicep/appgw.bicep` | App Gateway v2 — multi-site listeners, SSL Profiles, rewrite rules, E2E TLS, Key Vault certs, health probes |

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
