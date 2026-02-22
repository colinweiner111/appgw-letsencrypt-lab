# Step-by-Step Walkthrough: TLS Certificate for App Gateway

A complete, first-timer-friendly guide to issuing a Let's Encrypt certificate and configuring it on your Azure Application Gateway v2. Follow each step in order.

> **Already deployed?** This guide assumes you've completed the Bicep deployment from the README (Step 1). If not, go back to the [Quick Start](../README.md#quick-start--deploy-everything) and deploy first.

---

## Table of Contents

1. [Before You Start — Checklist](#1-before-you-start--checklist)
2. [Install Certbot](#2-install-certbot)
3. [Request the Certificate](#3-request-the-certificate)
4. [Create the DNS TXT Record](#4-create-the-dns-txt-record)
5. [Verify DNS Propagation](#5-verify-dns-propagation)
6. [Complete the Challenge](#6-complete-the-challenge)
7. [Convert PEM to PFX](#7-convert-pem-to-pfx)
8. [Import PFX to Key Vault](#8-import-pfx-to-key-vault)
9. [Re-deploy with HTTPS Enabled](#9-re-deploy-with-https-enabled)
10. [Verify HTTPS Is Working](#10-verify-https-is-working)
11. [Clean Up the TXT Record](#11-clean-up-the-txt-record)

---

## 1. Before You Start — Checklist

Make sure you have all of these before continuing:

| # | Requirement | How to check | Don't have it? |
|---|---|---|---|
| 1 | **Azure subscription** (logged in) | `az account show` | Run `az login` |
| 2 | **Infrastructure deployed** (Step 1 from README) | `az group show -n rg-appgw-lab` | Go back to [Quick Start](../README.md#quick-start--deploy-everything) |
| 3 | **A domain name you own** | You have login access to the DNS provider | Buy one (~$10/yr) from [Namecheap](https://namecheap.com), [Cloudflare](https://cloudflare.com), or [GoDaddy](https://godaddy.com) |
| 4 | **Ability to create DNS records** | You can log into your DNS provider and add TXT records | Ask your DNS admin for access |
| 5 | **Certbot installed** | `certbot --version` | See [Step 2](#2-install-certbot) below |
| 6 | **OpenSSL installed** | `openssl version` | See [Step 2](#2-install-certbot) below |
| 7 | **SSH key pair** (for backend VMs) | `ls ~/.ssh/id_rsa.pub` | Generate: `ssh-keygen -t rsa -b 4096` |

### Grab your deployment outputs

You'll need these values throughout. Run this and save the output:

```bash
az deployment group show \
  --resource-group rg-appgw-lab \
  --name main \
  --query properties.outputs \
  -o json
```

You should see something like:

```json
{
  "appGatewayPublicIp": { "value": "<public-ip-address>" },
  "appGatewayPrivateIp": { "value": "10.0.0.10" },
  "backendVmIps": { "value": ["10.0.1.5", "10.0.1.4"] },
  "keyVaultName": { "value": "kv-appgw-xxxxxxxxxx" },
  "keyVaultUri": { "value": "https://kv-appgw-xxxxxxxxxx.vault.azure.net/" }
}
```

Write down your **Key Vault name** and **public IP** — you'll need them later.

### Pick your domain name

Throughout this guide, we'll use `acme.com` as an example domain with a **multi-domain SAN certificate** covering:

- `acme.com` (root domain)
- `www.acme.com`
- `api.acme.com`
- `app.acme.com`

Replace these with your actual domain and subdomains. A SAN (Subject Alternative Name) certificate covers multiple domain names in a single cert — perfect for serving a root domain and its subdomains from the same App Gateway.

---

## 2. Install Certbot

Certbot is the tool that talks to Let's Encrypt and gets your certificate. You only need to install it once.

All scripts in this repo are bash, so run them from **Azure Cloud Shell** or **WSL**.

### Option A — Azure Cloud Shell (Easiest)

Open [Cloud Shell](https://shell.azure.com) in bash mode. `az` and `openssl` are pre-installed and `az` is already logged in. Install certbot with:

```bash
pip install --user certbot
export PATH="$HOME/.local/bin:$PATH"
certbot --version
```

> **Cloud Shell note:** Since Cloud Shell blocks `sudo`, certbot can't write to `/etc/letsencrypt/`. All commands in this guide use `--config-dir ~/letsencrypt` so certs are saved to `~/letsencrypt/live/` instead.

### Option B — WSL

If you prefer to work locally:

```bash
# Open a WSL terminal (e.g., Ubuntu)
sudo apt update
sudo apt install certbot -y

# Verify
certbot --version
# Expected: certbot 2.x.x
```

### Verify OpenSSL

OpenSSL is needed to convert the certificate to PFX format. It's pre-installed on WSL/Linux and comes with Git for Windows.

```bash
openssl version
# Expected: OpenSSL 3.x.x (or similar)
```

If you don't have it:
- **Windows:** Install [Git for Windows](https://git-scm.com/download/win) — it includes OpenSSL
- **WSL/Linux:** `sudo apt install openssl`

---

## 3. Request the Certificate

Now we ask Let's Encrypt for a certificate. This uses **DNS-01 challenge** — meaning you'll prove you own the domain by creating DNS records (no public IP needed).

This example requests a **multi-domain SAN certificate** covering four domains in a single cert. You can use fewer `-d` flags if you only need one domain.

> **Staging tip:** If this is your first time, add `--staging` to the command below. This uses Let's Encrypt's test server (no rate limits, but the cert won't be trusted by browsers). Remove `--staging` when you're ready for a real cert.

Open a **bash terminal** (WSL, Cloud Shell, or Linux):

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

Replace the `-d` values with your actual domains. You can use as many `-d` flags as you need — each one adds a SAN entry to the certificate.

> **Single domain?** Just use one `-d` flag: `-d acme.com`

> **No signup required:** On first run, Certbot automatically creates and registers an ACME account with Let's Encrypt. You don't need to create an account anywhere.

### What you'll see

Certbot will ask for your email (for renewal notices):

```
Enter email address (used for urgent renewal and security notices)
 (Enter 'c' to cancel): you@example.com
```

Then agree to the terms:

```
Please read the Terms of Service at https://letsencrypt.org/documents/LE-SA-v1.4...
(A)gree/(C)ancel: A
```

Then **this is the critical part** — certbot will prompt you **once per domain**. For a 4-domain SAN cert, you'll see 4 prompts like this:

```
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
Please deploy a DNS TXT record under the name:

  _acme-challenge.acme.com

with the following value:

  A3f7k9xB2mQ4pR8tY1wZ6vN0cD5eH3jL

Before continuing, verify the TXT record has been deployed. Depending on the
DNS provider, this may take a while.

- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
Press Enter to Continue
```

Then after you press Enter, it will ask for the next domain:

```
Please deploy a DNS TXT record under the name:

  _acme-challenge.www.acme.com

with the following value:

  B7h2j4mN9pQ1rT3uW5xY8zA0bC6dE4fG
```

...and so on for `api.acme.com` and `app.acme.com`.

**⚠️ DO NOT press Enter yet!** Create each TXT record as certbot requests it, verify propagation, then press Enter to get the next prompt. See Step 4.

---

## 4. Create the DNS TXT Record

Certbot is waiting. You now need to create a TXT record in your DNS provider for **each domain** in the SAN cert. Certbot prompts you one at a time, so you'll create each record, verify it, then press Enter for the next one.

You'll need two values from the certbot output:

- **Record name:** `_acme-challenge` (for the root domain) or `_acme-challenge.www` (for subdomains)
- **Record value:** The random string certbot displayed (different for each domain)

> **Key concept:** All TXT records go in the same DNS zone (e.g., `acme.com`). For subdomains like `www.acme.com`, the TXT record name is `_acme-challenge.www` within the `acme.com` zone.

### If your DNS is in Azure DNS

Open a **new terminal** (leave certbot running in the other one). Create a TXT record for each domain as certbot requests it:

```bash
# For acme.com (root domain)
az network dns record-set txt add-record \
  --resource-group "your-dns-resource-group" \
  --zone-name "acme.com" \
  --record-set-name "_acme-challenge" \
  --value "A3f7k9xB2mQ4pR8tY1wZ6vN0cD5eH3jL"

# For www.acme.com
az network dns record-set txt add-record \
  --resource-group "your-dns-resource-group" \
  --zone-name "acme.com" \
  --record-set-name "_acme-challenge.www" \
  --value "B7h2j4mN9pQ1rT3uW5xY8zA0bC6dE4fG"

# For api.acme.com
az network dns record-set txt add-record \
  --resource-group "your-dns-resource-group" \
  --zone-name "acme.com" \
  --record-set-name "_acme-challenge.api" \
  --value "<value-from-certbot>"

# For app.acme.com
az network dns record-set txt add-record \
  --resource-group "your-dns-resource-group" \
  --zone-name "acme.com" \
  --record-set-name "_acme-challenge.app" \
  --value "<value-from-certbot>"
```

Replace:
- `your-dns-resource-group` → the resource group containing your Azure DNS zone
- `acme.com` → your actual domain
- Each `--value` → the exact string certbot gave you for that domain

> **Common mistake:** Don't include the zone name in `--record-set-name`. Azure DNS appends it automatically. Use `_acme-challenge.www`, not `_acme-challenge.www.acme.com`.

### Other DNS Providers

The process is the same regardless of provider (Cloudflare, GoDaddy, Namecheap, etc.):
1. Log into your DNS management panel
2. Add a **TXT** record for each domain certbot requests
3. For the root domain: Name/Host = `_acme-challenge`
4. For subdomains: Name/Host = `_acme-challenge.www`, `_acme-challenge.api`, etc.
5. Value: the exact string certbot displayed for that domain
6. Save and wait for propagation (typically 30 seconds to 30 minutes depending on provider)

> **⚠️ Namecheap users:** Namecheap cannot create dotted host names like `_acme-challenge.www`.
> You may need to use a different DNS provider, or issue each subdomain certificate separately.

---

## 5. Verify DNS Propagation

Before pressing Enter in certbot, **verify each TXT record is live**. If you press Enter before the record propagates, the challenge will fail and you'll have to start over.

Run this from any terminal:

```bash
# Check each domain's TXT record
nslookup -type=TXT _acme-challenge.acme.com
nslookup -type=TXT _acme-challenge.www.acme.com
nslookup -type=TXT _acme-challenge.api.acme.com
nslookup -type=TXT _acme-challenge.app.acme.com
```

Or:

```bash
dig TXT _acme-challenge.acme.com +short
dig TXT _acme-challenge.www.acme.com +short
```

### What you should see (success)

```
"A3f7k9xB2mQ4pR8tY1wZ6vN0cD5eH3jL"
```

The random string from certbot should appear. If you see this, you're ready to press Enter for that domain.

### What you might see (not ready yet)

```
** server can't find _acme-challenge.acme.com: NXDOMAIN
```

This means the record hasn't propagated yet. Wait 30-60 seconds and try again.

### Using a web tool

You can also check at [https://toolbox.googleapps.com/apps/dig/#TXT/](https://toolbox.googleapps.com/apps/dig/) — enter `_acme-challenge.acme.com` and look for your TXT value.

---

## 6. Complete the Challenge

Once you've confirmed the TXT record is live (Step 5), go back to the **certbot terminal** and **press Enter**.

For a multi-domain SAN cert, certbot will repeat this cycle for each domain:
1. You press Enter
2. Let's Encrypt verifies the TXT record
3. Certbot shows the next domain's challenge
4. You create that TXT record, verify it, then press Enter again

After all domains are verified, Let's Encrypt issues a single certificate covering all of them.

### What you should see (success)

```
Successfully received certificate.
Certificate is saved at: ~/letsencrypt/live/acme.com/fullchain.pem
Key is saved at:         ~/letsencrypt/live/acme.com/privkey.pem
This certificate expires on 2026-05-21.
```

🎉 **You now have a valid multi-domain TLS certificate!**

The cert directory is named after the **first** `-d` domain (e.g., `acme.com`). The certificate inside covers all 4 domains.

The important files:

| File | What it is |
|---|---|
| `fullchain.pem` | Your certificate + the intermediate CA (use this one) |
| `privkey.pem` | Your private key (never share this) |

### What if it failed?

| Error | Cause | Fix |
|---|---|---|
| `DNS problem: NXDOMAIN` | TXT record doesn't exist or hasn't propagated | Wait longer, re-check with `nslookup` |
| `DNS problem: query timed out` | DNS server not responding | Try again in a few minutes |
| `too many certificates already issued` | Let's Encrypt rate limit (50/week) | Use `--staging` flag for testing |
| `Timeout during connect` | Network issue | Check your internet connection |

If it fails, just run the certbot command again (Step 3). You may need to update the TXT record with a new value.

---

## 7. Convert PEM to PFX

Azure Application Gateway doesn't accept PEM files directly. You need to convert them to **PFX** format (a single file containing your certificate + private key).

```bash
openssl pkcs12 -export \
  -out appgw-cert.pfx \
  -inkey ~/letsencrypt/live/acme.com/privkey.pem \
  -in ~/letsencrypt/live/acme.com/fullchain.pem
```

> **Multi-domain note:** The directory is named after the first `-d` domain. All SAN domains are embedded in the single `fullchain.pem` file.

### What happens

OpenSSL will ask you for a password:

```
Enter Export Password:
Verifying - Enter Export Password:
```

**Pick a password and remember it** — you'll need it in the next step when importing to Key Vault. Even a simple password like `LabCert123!` is fine for a lab.

> **⚠️ Use `fullchain.pem`, not `cert.pem`!** If you use `cert.pem`, the certificate will be missing the intermediate CA and browsers will show trust errors. See [the trust chain explanation](HOW-LETS-ENCRYPT-WORKS.md#the-trust-chain) for why.

### Verify the PFX was created

```bash
ls -la appgw-cert.pfx
# Should show a file of a few KB

# Optional: verify the contents
openssl pkcs12 -in appgw-cert.pfx -nokeys -clcerts | openssl x509 -subject -issuer -noout
```

You should see your domain in the `subject` and Let's Encrypt's intermediate CA in the `issuer`:

```
subject=CN = acme.com
issuer=C = US, O = Let's Encrypt, CN = R10
```

### Copy the PFX to your Windows machine (if using WSL)

If you ran certbot in WSL, you don't need to copy anything — just run `import-to-kv.sh` from the same WSL session. But if you want the file on your desktop:

```bash
cp appgw-cert.pfx /mnt/c/Users/$USER/Desktop/appgw-cert.pfx
```

---

## 8. Import PFX to Key Vault

Now import the PFX into Azure Key Vault. The App Gateway will pull the certificate from Key Vault using its managed identity.

### Using the included script

```bash
./scripts/shared/import-to-kv.sh \
  --vault-name "kv-appgw-xxxxxxxxxx" \
  --pfx-path "./appgw-cert.pfx" \
  --pfx-password "LabCert123!"
```

Replace:
- `kv-appgw-xxxxxxxxxx` → your actual Key Vault name (from Step 1 outputs)
- The PFX path → wherever the file is (it’s in your current directory if you followed Step 7)
- The password → whatever you set in Step 7

### Using Azure CLI directly

```bash
az keyvault certificate import \
  --vault-name "kv-appgw-xxxxxxxxxx" \
  --name "appgw-cert" \
  --file "./appgw-cert.pfx" \
  --password "LabCert123!"
```

### What you should see (success)

```json
{
  "id": "https://kv-appgw-xxxxxxxxxx.vault.azure.net/certificates/appgw-cert/abc123...",
  "sid": "https://kv-appgw-xxxxxxxxxx.vault.azure.net/secrets/appgw-cert/abc123..."
}
```

### Save the Secret URI

You need the **secret URI** (the `sid` field), not the certificate URI. Copy it — you'll use it in the next step.

It looks like this:
```
https://kv-appgw-xxxxxxxxxx.vault.azure.net/secrets/appgw-cert/abc123def456...
```

> **Why the secret URI?** Azure App Gateway reads certificates from Key Vault's **secrets** API, not the certificates API. This is an Azure-specific quirk — the Bicep template already handles this correctly.

### Troubleshooting import

| Error | Cause | Fix |
|---|---|---|
| `Forbidden` / `403` | Your user doesn't have Key Vault access | Assign yourself `Key Vault Certificates Officer`: `az role assignment create --role "Key Vault Certificates Officer" --assignee $(az ad signed-in-user show --query id -o tsv) --scope $(az keyvault show -n <kv-name> --query id -o tsv)` |
| `ForbiddenByRbac` | RBAC not configured for your identity | Same fix — you need `Key Vault Certificates Officer` (not just `Key Vault Secrets User`) to **import** certs |
| `The password is incorrect` | Wrong PFX password | Re-run the openssl export (Step 7) with a password you remember |
| `The specified PFX file is invalid` | Corrupted PFX file | Re-run the openssl export (Step 7) |

---

## 9. Re-deploy with HTTPS Enabled

Now re-run the Bicep deployment with HTTPS turned on and the Key Vault secret URI.

> **Important:** Set `deployBackend=false` on Phase 2 to avoid recreating the VMs.
> The cloud-init `customData` property cannot be changed on existing VMs, so ARM will
> reject the deployment if you try to redeploy them. Pass your existing backend IPs instead.

```bash
# First, get your existing backend IPs
az vm list-ip-addresses -g rg-appgw-lab \
  --query "[].virtualMachine.network.privateIpAddresses[0]" -o tsv

# Then redeploy with HTTPS enabled
az deployment group create \
  --resource-group rg-appgw-lab \
  --template-file bicep/main.bicep \
  --parameters \
    sshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
    enableHttps=true \
    deployBackend=false \
    existingBackendIps='["10.0.1.4","10.0.1.5"]' \
    keyVaultSecretId="https://kv-appgw-xxxxxxxxxx.vault.azure.net/secrets/appgw-cert/abc123def456..."
```

Replace the `keyVaultSecretId` with the actual secret URI from Step 8, and update
`existingBackendIps` with the IPs from the first command.

### What this does

The Bicep template will update the App Gateway to:
- Add an HTTPS listener on port 443 using the Key Vault certificate
- Add an HTTP→HTTPS redirect rule
- App Gateway terminates TLS at the frontend and forwards HTTP to backend VMs

This takes 5-10 minutes.

### What you should see (success)

```
Name    State      Timestamp                         Mode         ResourceGroup
------  ---------  --------------------------------  -----------  --------------
main    Succeeded  2026-02-21T...                    Incremental  rg-appgw-lab
```

### Troubleshooting Phase 2 redeploy

| Issue | Fix |
|---|---|
| **customData conflict** (VM deployment fails) | Add `deployBackend=false` and `existingBackendIps` parameters |
| **App Gateway stuck in Failed state** | Run `az network application-gateway stop -g rg-appgw-lab -n appgw-lab` then `az network application-gateway start -g rg-appgw-lab -n appgw-lab` to reset |
| **RBAC propagation delay** (App GW can't read Key Vault) | Wait 5 minutes for RBAC to propagate, then retry. Or use the CLI alternative below |

### Alternative — CLI-based HTTPS config

If the Bicep redeploy fails (e.g., App Gateway enters a Failed state due to RBAC propagation
delays), you can configure HTTPS entirely via CLI commands:

```bash
# 1. Add the SSL certificate from Key Vault
KV_SECRET_ID="https://kv-appgw-xxxxxxxxxx.vault.azure.net/secrets/appgw-cert/abc123..."
az network application-gateway ssl-cert create \
  -g rg-appgw-lab --gateway-name appgw-lab \
  --name appgw-cert --key-vault-secret-id "$KV_SECRET_ID"

# 2. Create the HTTPS frontend port
az network application-gateway frontend-port create \
  -g rg-appgw-lab --gateway-name appgw-lab \
  --name port-https --port 443

# 3. Create the HTTPS listener
az network application-gateway http-listener create \
  -g rg-appgw-lab --gateway-name appgw-lab \
  --name https-listener --frontend-port port-https \
  --frontend-ip appGatewayPublicFrontendIP --ssl-cert appgw-cert

# 4. Create the routing rule
az network application-gateway rule create \
  -g rg-appgw-lab --gateway-name appgw-lab \
  --name https-rule --http-listener https-listener \
  --address-pool appGatewayBackendPool \
  --http-settings appGatewayBackendHttpSettings --priority 100
```

---

## 10. Verify HTTPS Is Working

### From anywhere (public IP)

```bash
# Get the public IP
PUBLIC_IP=$(az network public-ip show -g rg-appgw-lab -n appgw-lab-pip --query ipAddress -o tsv)
echo "Public IP: $PUBLIC_IP"

# Test via public IP — the -k flag skips certificate verification because we're
# connecting by IP address, not by domain name. The cert is valid for your domain,
# not for the raw IP.
curl -k https://$PUBLIC_IP/

# You should see:
# <h1>Hello from Backend VM 1 (10.0.1.5)</h1>
# or
# <h1>Hello from Backend VM 2 (10.0.1.4)</h1>
```

### Verify the certificate details

```bash
# Connect and show the cert info
openssl s_client -connect $PUBLIC_IP:443 -servername acme.com < /dev/null 2>/dev/null | openssl x509 -subject -issuer -dates -noout
```

You should see:

```
subject=CN = acme.com
issuer=C = US, O = Let's Encrypt, CN = R10
notBefore=Feb 21 01:23:45 2026 GMT
notAfter=May 22 01:23:45 2026 GMT
```

### Test HTTP→HTTPS redirect

```bash
curl -I http://$PUBLIC_IP/
# Should show: HTTP/1.1 301 Moved Permanently
# Location: https://$PUBLIC_IP/
```

### Browse with your domain name

Create a DNS A record pointing your domain to the public IP:

```
acme.com      →  <public IP>
www.acme.com  →  <public IP>
api.acme.com  →  <public IP>
app.acme.com  →  <public IP>
```

Then browse to `https://acme.com` in your browser — the certificate should
show as valid (green lock) because it matches the domain name.

---

## 11. Clean Up the TXT Record

The ACME challenge TXT record is no longer needed. Clean it up:

### Azure DNS

```bash
# Clean up all TXT records
az network dns record-set txt delete \
  --resource-group "your-dns-resource-group" \
  --zone-name "acme.com" \
  --name "_acme-challenge" --yes

az network dns record-set txt delete \
  --resource-group "your-dns-resource-group" \
  --zone-name "acme.com" \
  --name "_acme-challenge.www" --yes

az network dns record-set txt delete \
  --resource-group "your-dns-resource-group" \
  --zone-name "acme.com" \
  --name "_acme-challenge.api" --yes

az network dns record-set txt delete \
  --resource-group "your-dns-resource-group" \
  --zone-name "acme.com" \
  --name "_acme-challenge.app" --yes
```

### Other providers

Delete all `_acme-challenge` TXT records from your DNS management panel.

---

## What You Just Did

Here's the complete flow you just completed:

```
┌─────────────┐    ┌─────────────┐    ┌──────────────┐    ┌─────────────┐
│  1. Certbot  │───►│  2. DNS TXT  │───►│  3. LE issues│───►│  4. PEM     │
│  requests    │    │  record      │    │  certificate │    │  files      │
│  challenge   │    │  created     │    │  (PEM)       │    │  on disk    │
└─────────────┘    └─────────────┘    └──────────────┘    └──────┬──────┘
                                                                 │
                    ┌─────────────┐    ┌──────────────┐    ┌─────▼───────┐
                    │  7. App GW   │◄──│  6. Re-deploy│◄──│  5. Import  │
                    │  serves      │    │  Bicep with  │    │  PFX to     │
                    │  HTTPS  🔒  │    │  HTTPS=true  │    │  Key Vault  │
                    └─────────────┘    └──────────────┘    └─────────────┘
```

Your App Gateway is now serving HTTPS with a free Let's Encrypt certificate, pulled from Key Vault via managed identity. No certificate purchase, no manual upload to the gateway. The public IP lets you test from any browser.

---

## What's Next?

- **Certificate renewal:** The cert expires in 90 days. For this lab, re-run Steps 3-9 to renew. For production, automate renewal using the script below.
- **Automate renewal:** See [azure-dns-certbot.sh](../scripts/option-b-private/azure-dns-certbot.sh) for a one-command automated flow.
- **Clean up lab resources:** `az group delete --name rg-appgw-lab --yes --no-wait`
- **Learn more:** Read [How Let's Encrypt Works](HOW-LETS-ENCRYPT-WORKS.md) for the concepts behind what you just did.

---

← Back to [README](../README.md)
