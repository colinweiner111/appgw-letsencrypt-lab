# End-to-End Portal Walkthrough: App Gateway v2 with Key Vault TLS

Build a complete Application Gateway v2 environment from scratch using only the Azure portal. This guide covers every resource in order — VNet, VM, Key Vault, Managed Identity, and App Gateway — with end-to-end TLS to a backend Windows Server running IIS.

When you're done, you'll have:
- A Windows VM running IIS with a TLS certificate
- A Key Vault storing that certificate
- A User-Assigned Managed Identity bridging App Gateway → Key Vault
- An App Gateway v2 terminating TLS on the frontend and re-encrypting to the backend

> **Scenario:** This mirrors an AVS or on-prem migration where backend servers sit on a private network, reachable only by IP, and App Gateway provides the public frontend with TLS termination and re-encryption.

> ⚠️ **Portal Limitation — Key Vault + RBAC Requires CLI for Initial HTTPS Listener**
>
> The Azure portal **does not support** creating App Gateway HTTPS listeners with Key Vault certificates when the Key Vault uses the **Azure RBAC permission model**. This is a [documented limitation](https://learn.microsoft.com/en-us/azure/application-gateway/key-vault-certs#key-vault-azure-role-based-access-control-permission-model):
>
> *"Specifying Azure Key Vault certificates that are subject to the role-based access control permission model is not supported via the portal. The first few steps to reference the Key Vault must be completed via ARM template, Bicep, CLI, or PowerShell."*
>
> **This walkthrough uses RBAC** (the recommended model). Everything is done in the portal except [Step 13](#step-13--add-the-key-vault-certificate-and-https-listener-cli), which uses a few CLI commands to wire up the Key Vault cert. Once created, the HTTPS listener appears in the portal and can be managed normally.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Step 1 — Create Resource Group](#step-1--create-resource-group)
- [Step 2 — Create VNet and Subnets](#step-2--create-vnet-and-subnets)
- [Step 3 — Deploy a Windows VM with IIS](#step-3--deploy-a-windows-vm-with-iis)
- [Step 4 — Install the TLS Certificate on the VM](#step-4--install-the-tls-certificate-on-the-vm)
- [Step 5 — Create a Key Vault](#step-5--create-a-key-vault)
- [Step 6 — Import the Certificate into Key Vault](#step-6--import-the-certificate-into-key-vault)
- [Step 7 — Create a User-Assigned Managed Identity](#step-7--create-a-user-assigned-managed-identity)
- [Step 8 — Authorize the Identity in Key Vault](#step-8--authorize-the-identity-in-key-vault)
- [Step 9 — Create the Application Gateway](#step-9--create-the-application-gateway)
- [Step 10 — Configure Backend Pool](#step-10--configure-backend-pool)
- [Step 11 — Configure Backend HTTP Settings](#step-11--configure-backend-http-settings)
- [Step 12 — Configure a Health Probe](#step-12--configure-a-health-probe)
- [Step 13 — Add the Key Vault Certificate and HTTPS Listener (CLI)](#step-13--add-the-key-vault-certificate-and-https-listener-cli)
- [Step 14 — Configure Custom Error Pages (Optional)](#step-14--configure-custom-error-pages-optional)
- [Step 15 — Update DNS](#step-15--update-dns)
- [Step 16 — Verify End-to-End](#step-16--verify-end-to-end)
- [Architecture Summary](#architecture-summary)
- [Common Mistakes](#common-mistakes)

---

## Prerequisites

- An Azure subscription
- A TLS certificate (PFX format) for your domain — e.g., from Let's Encrypt (see [HOW-LETS-ENCRYPT-WORKS.md](HOW-LETS-ENCRYPT-WORKS.md))
- A domain name you control (for DNS A record pointing to App Gateway)
- The certificate also installed on your backend server (for end-to-end TLS)

---

## Step 1 — Create Resource Group

1. Portal → **Resource groups** → **+ Create**
2. Fill in:
   - **Subscription:** Your subscription
   - **Resource group:** `rg-appgw-demo` (or your naming convention)
   - **Region:** `East US 2` (pick one region and keep everything in it)
3. **Review + create** → **Create**

---

## Step 2 — Create VNet and Subnets

App Gateway requires its own **dedicated subnet**. Backend VMs go in a separate subnet.

1. Portal → **Virtual networks** → **+ Create**
2. **Basics** tab:
   - **Resource group:** `rg-appgw-demo`
   - **Name:** `vnet-appgw-demo`
   - **Region:** `East US 2`
3. **IP Addresses** tab:
   - **Address space:** `10.0.0.0/16`
   - Add two subnets:

| Subnet Name | Address Range | Purpose |
|---|---|---|
| `subnet-appgw` | `10.0.0.0/24` | App Gateway (dedicated — no other resources) |
| `subnet-backend` | `10.0.1.0/24` | Backend VMs |

4. **Review + create** → **Create**

> **Important:** The App Gateway subnet must be dedicated. Don't place VMs, private endpoints, or other resources in it.

---

## Step 3 — Deploy a Windows VM with IIS

1. Portal → **Virtual machines** → **+ Create** → **Azure virtual machine**
2. **Basics** tab:
   - **Resource group:** `rg-appgw-demo`
   - **Name:** `vm-backend-1`
   - **Region:** `East US 2`
   - **Image:** `Windows Server 2022 Datacenter: Azure Edition`
   - **Size:** `Standard_B2s` (sufficient for a lab)
   - **Username / Password:** Set your admin credentials
3. **Networking** tab:
   - **Virtual network:** `vnet-appgw-demo`
   - **Subnet:** `subnet-backend`
   - **Public IP:** `None` (the VM only needs private connectivity)
4. **Review + create** → **Create**

### Install IIS on the VM

Once deployed, install IIS via the portal **Run command**:

1. Go to `vm-backend-1` → **Operations** → **Run command** → **RunPowerShellScript**
2. Paste:
   ```powershell
   Install-WindowsFeature -Name Web-Server -IncludeManagementTools
   Get-Service W3SVC | Select-Object Status, Name
   ```
3. Click **Run** — wait for output showing `Running W3SVC`

---

## Step 4 — Install the TLS Certificate on the VM

IIS needs the same certificate that App Gateway will use, so the backend connection is also TLS-encrypted (end-to-end TLS).

1. Go to `vm-backend-1` → **Operations** → **Run command** → **RunPowerShellScript**
2. Paste the following (replace `<BASE64_PFX>` with your PFX file's base64 content, and `<YOUR_PFX_PASSWORD>` with the password, or remove the password parameter if passwordless):

   ```powershell
   # Write the PFX to disk
   $pfxBytes = [System.Convert]::FromBase64String('<BASE64_PFX>')
   New-Item -Path 'C:\cert' -ItemType Directory -Force | Out-Null
   [System.IO.File]::WriteAllBytes('C:\cert\mycert.pfx', $pfxBytes)

   # Import into the machine certificate store
   $cert = Import-PfxCertificate -FilePath 'C:\cert\mycert.pfx' `
       -CertStoreLocation Cert:\LocalMachine\My -Exportable

   Write-Output "Imported: $($cert.Subject)  Thumbprint: $($cert.Thumbprint)"
   ```

3. Click **Run** — note the **thumbprint** from the output

### Bind the certificate in IIS

Run another command to create the HTTPS binding:

```powershell
Import-Module WebAdministration

# Create HTTPS binding with SNI
New-WebBinding -Name 'Default Web Site' -Protocol https -Port 443 `
    -HostHeader 'app1.contoso.com' -SslFlags 1

# Bind the certificate (replace THUMBPRINT with actual value)
netsh http add sslcert hostnameport=app1.contoso.com:443 `
    certhash=<THUMBPRINT> certstorename=MY `
    appid='{4dc3e181-e14b-4a21-b022-59fc669b0914}'

# Open firewall
New-NetFirewallRule -DisplayName 'IIS HTTPS' -Direction Inbound `
    -Protocol TCP -LocalPort 443 -Action Allow

iisreset /restart
```

> **Tip:** To base64-encode a PFX file on your local machine:
> ```powershell
> [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\path\to\cert.pfx'))
> ```

---

## Step 5 — Create a Key Vault

1. Portal → **Key vaults** → **+ Create**
2. **Basics** tab:
   - **Resource group:** `rg-appgw-demo`
   - **Key vault name:** `kv-appgw-demo` (must be globally unique — add a suffix if needed)
   - **Region:** `East US 2`
   - **Pricing tier:** `Standard`
3. **Access configuration** tab:
   - **Permission model:** `Azure role-based access control` (recommended)
4. **Review + create** → **Create**

### Grant yourself access to import certificates

1. Go to your new Key Vault → **Access control (IAM)** → **+ Add role assignment**
2. Role: **Key Vault Certificates Officer**
3. Members: Select your own user account
4. **Review + assign**

> **Also add Key Vault Secrets User to yourself.** The portal validates your permissions when selecting Key Vault certs during App Gateway configuration. Without this role on your own account, the portal may show a misleading error.
>
> Key Vault → Access control (IAM) → + Add role assignment → **Key Vault Secrets User** → select your user → Review + assign

---

## Step 6 — Import the Certificate into Key Vault

1. Go to your Key Vault → **Objects** → **Certificates** → **+ Generate/Import**
2. **Method:** `Import`
3. **Certificate name:** `cert-app1` (a friendly name — this is how App Gateway will reference it)
4. **Upload Certificate File:** Select your `.pfx` file
5. **Password:** Enter the PFX password (leave blank if passwordless)
6. Click **Create**

Verify: The certificate should appear with status **Enabled** and show the subject (e.g., `CN=app1.contoso.com`).

---

## Step 7 — Create a User-Assigned Managed Identity

This identity is what App Gateway uses to authenticate to Key Vault. It's created independently and can be pre-provisioned by a security team.

1. Portal → search **"Managed Identities"** → **+ Create**
2. Fill in:
   - **Subscription:** Your subscription
   - **Resource group:** `rg-appgw-demo`
   - **Region:** `East US 2`
   - **Name:** `id-appgw-demo`
3. **Review + create** → **Create**

> **Why User-Assigned?** The identity exists independently of the App Gateway. It can be pre-provisioned, its RBAC assignments are visible in Key Vault, and it survives if the App Gateway is deleted and recreated. ([App Gateway Key Vault integration](https://learn.microsoft.com/en-us/azure/application-gateway/key-vault-certs) | [Managed identity best practices](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations))

---

## Step 8 — Authorize the Identity in Key Vault

The managed identity needs permission to **read secrets** from Key Vault (App Gateway retrieves certs as secrets).

1. Go to your Key Vault → **Access control (IAM)** → **+ Add role assignment**
2. Role: **Key Vault Secrets User**
3. Members → **Managed identity** → Select `id-appgw-demo`
4. **Review + assign**

> **Why Secrets User, not Certificates Officer?** App Gateway retrieves the certificate's **secret** (which contains the private key + cert bundle as a PFX), not just the certificate object. `Key Vault Secrets User` grants `secrets/get` access. `Certificates Officer` is for managing certificates — the MI doesn't need that.

### Auth Chain Summary

```
App Gateway
  └── uses ──► id-appgw-demo (User-Assigned MI)
                   └── has role ──► Key Vault Secrets User
                                      └── on ──► kv-appgw-demo
                                                    └── stores ──► cert-app1 (as a secret)
```

---

## Step 9 — Create the Application Gateway

This is the most complex portal form. Take it tab by tab.

### Basics tab

| Field | Value |
|---|---|
| Resource group | `rg-appgw-demo` |
| Name | `appgw-demo` |
| Region | `East US 2` |
| Tier | `Standard V2` |
| Enable autoscaling | Yes (Min: 1, Max: 2 for a lab) |
| Virtual network | `vnet-appgw-demo` |
| Subnet | `subnet-appgw` |

### Frontends tab

| Field | Value |
|---|---|
| Frontend IP address type | `Public` |
| Public IP address | **Add new** → `pip-appgw-demo` |

### Backends tab

1. Click **+ Add a backend pool**
2. **Name:** `bp-backend-vms`
3. **Add target:**
   - Target type: **IP address or FQDN**
   - Target: Enter the VM's **private IP** (e.g., `10.0.1.4`)
4. Click **Add**

> **Why IP, not NIC?** In AVS/on-prem migration scenarios, backend servers aren't Azure VMs with NICs the portal can browse. They're reachable by IP over ExpressRoute or VNet peering. Using IP addresses here mirrors that pattern.

### Configuration tab

This is where you wire up the listener, rule, and backend settings together. Click **+ Add a routing rule**.

#### Routing rule — Listener subtab

| Field | Value |
|---|---|
| Rule name | `rr-app1-https` |
| Priority | `100` |
| Listener name | `lstn-app1-https` |
| Protocol | `HTTPS` |
| Port | `443` |
| **Choose a certificate** | **Choose a certificate from Key Vault** |
| Cert name | `cert-app1` |
| Managed identity | `id-appgw-demo` |
| Key vault | `kv-appgw-demo` |
| Certificate | `cert-app1` |
| Listener type | `Multi site` |
| Host type | `Single` |
| Host name | `app1.contoso.com` |

> **This is the moment** where the managed identity chain comes together. If any step was missed (identity not created, not attached, not authorized in Key Vault), this dropdown will fail or the certificate won't appear.

#### Routing rule — Backend targets subtab

| Field | Value |
|---|---|
| Target type | `Backend pool` |
| Backend target | `bp-backend-vms` |
| Backend settings | **Add new** (see next section) |

#### Backend settings (in the "Add new" flyout)

| Field | Value |
|---|---|
| Name | `be-htst-app1` |
| Backend protocol | `HTTPS` |
| Backend port | `443` |
| **Override with new host name** | `Yes` |
| Host name override | **Override with specific domain name** |
| Host name | `app1.contoso.com` |
| Trusted root certificate | Not required (if using a publicly-trusted cert like Let's Encrypt) |

> **Critical: Host name override.** App Gateway connects to the backend by IP address. Without this override, the Host header sent to IIS would be the IP, and IIS wouldn't know which SNI binding to use. Setting it to `app1.contoso.com` ensures IIS receives the correct hostname and serves the right certificate.

> **Trusted root certificate:** If your backend uses a **self-signed cert or a private CA**, you must upload the root CA cert here. For publicly-trusted certs (Let's Encrypt, DigiCert, etc.), leave this blank — App Gateway trusts them by default.

Click **Add** to close the backend settings flyout, then **Add** to close the routing rule.

### Tags tab (optional)

Add any tags per your organization's policy.

### Review + create

Review everything and click **Create**. Deployment takes 5-10 minutes.

---

## Step 10 — Configure Backend Pool

If you didn't add the backend pool during creation, or need to modify it:

1. Go to `appgw-demo` → **Settings** → **Backend pools**
2. Click `bp-backend-vms` (or **+ Add**)
3. Add the VM's private IP: `10.0.1.4`
4. Click **Save**

---

## Step 11 — Configure Backend HTTP Settings

If you need to modify or verify backend settings:

1. Go to `appgw-demo` → **Settings** → **Backend settings**
2. Click `be-htst-app1`
3. Verify:
   - **Protocol:** HTTPS
   - **Port:** 443
   - **Override hostname:** Yes → `app1.contoso.com`
4. Click **Save**

---

## Step 12 — Configure a Health Probe

App Gateway will create a default probe, but explicit probes are best practice.

1. Go to `appgw-demo` → **Settings** → **Health probes** → **+ Add**
2. Fill in:

| Field | Value |
|---|---|
| Name | `hp-app1` |
| Protocol | `HTTPS` |
| Host | `app1.contoso.com` |
| Path | `/` |
| Interval (seconds) | `30` |
| Timeout (seconds) | `30` |
| Unhealthy threshold | `3` |
| Backend settings | `be-htst-app1` |

3. Click **Test** to verify connectivity, then **Save**

> **If the test fails:** Check that the VM's NSG allows inbound 443 from `subnet-appgw` (10.0.0.0/24), and that IIS is running.

---

## Step 13 — Add the Key Vault Certificate and HTTPS Listener (CLI)

The Azure portal [does not support](https://learn.microsoft.com/en-us/azure/application-gateway/key-vault-certs#key-vault-azure-role-based-access-control-permission-model) configuring Key Vault cert references when the Key Vault uses RBAC. This is the **one step** that requires CLI. Once created, everything is visible and manageable in the portal.

Open **PowerShell** (or Azure Cloud Shell) and run these commands. Replace the variable values with your actual resource names.

### Set variables

```powershell
$RG           = "rg-appgw-demo"
$APPGW_NAME   = "appgw-demo"
$KV_NAME      = "kv-appgw-demo"
$CERT_NAME    = "cert-app1"           # Name of the cert in Key Vault
$MI_NAME      = "id-appgw-demo"
$HOSTNAME     = "app1.contoso.com"
```

### Step 13a — Assign the Managed Identity to the App Gateway

```powershell
# Get the MI resource ID
$miId = az identity show --name $MI_NAME --resource-group $RG --query id -o tsv

# Assign it to the App Gateway
az network application-gateway identity assign `
    --gateway-name $APPGW_NAME `
    --resource-group $RG `
    --identity $miId
```

### Step 13b — Add the Key Vault SSL certificate

```powershell
# Get the secret ID (unversioned, so App Gateway auto-rotates)
$secretId = az keyvault secret show --vault-name $KV_NAME --name $CERT_NAME `
    --query id -o tsv
$secretId = $secretId -replace '/[^/]+$', ''   # Strip version to get unversioned URI

# Add the cert to App Gateway
az network application-gateway ssl-cert create `
    --gateway-name $APPGW_NAME `
    --resource-group $RG `
    --name $CERT_NAME `
    --key-vault-secret-id $secretId
```

### Step 13c — Create the HTTPS listener

```powershell
# Get the frontend IP config name
$fipName = az network application-gateway frontend-ip list `
    --gateway-name $APPGW_NAME --resource-group $RG `
    --query "[?publicIPAddress!=null].name" -o tsv

# Create the HTTPS listener
az network application-gateway http-listener create `
    --gateway-name $APPGW_NAME `
    --resource-group $RG `
    --name lstn-app1-https `
    --frontend-ip $fipName `
    --frontend-port port_443 `
    --ssl-cert $CERT_NAME `
    --host-names $HOSTNAME
```

> **Note:** If port 443 doesn't exist yet, create it first:
> ```powershell
> az network application-gateway frontend-port create `
>     --gateway-name $APPGW_NAME --resource-group $RG `
>     --name port_443 --port 443
> ```

### Step 13d — Create the routing rule

```powershell
# Get the backend pool and settings IDs
$bpId = az network application-gateway address-pool show `
    --gateway-name $APPGW_NAME --resource-group $RG `
    --name bp-backend-vms --query id -o tsv

$beId = az network application-gateway http-settings show `
    --gateway-name $APPGW_NAME --resource-group $RG `
    --name be-htst-app1 --query id -o tsv

# Create the rule
az network application-gateway rule create `
    --gateway-name $APPGW_NAME `
    --resource-group $RG `
    --name rr-app1-https `
    --priority 100 `
    --http-listener lstn-app1-https `
    --address-pool bp-backend-vms `
    --http-settings be-htst-app1
```

### Step 13e — Clean up the temporary HTTP listener (optional)

Now that the HTTPS rule is in place, remove the temporary HTTP listener and rule created during Step 9:

```powershell
# Delete the temp rule first (rules reference listeners, so rule must go first)
az network application-gateway rule delete `
    --gateway-name $APPGW_NAME --resource-group $RG --name rr-app1-temp

# Delete the temp listener
az network application-gateway http-listener delete `
    --gateway-name $APPGW_NAME --resource-group $RG --name lstn-app1-http
```

### Verify in the portal

Go to `appgw-demo` → **Listeners** — you should now see `lstn-app1-https` with protocol HTTPS and the Key Vault certificate. From here, you can manage it normally in the portal (edit host names, add custom error pages, etc.).

---

## Step 14 — Configure Custom Error Pages (Optional)

Now that the HTTPS listener exists, you can add custom error pages in the portal:

1. Go to `appgw-demo` → **Listeners** → click `lstn-app1-https`
2. Scroll down to **Custom error pages**:
   - **Bad Gateway - 502:** Enter the URL to your custom 502 page (e.g., hosted on Azure Blob Storage static website)
   - **Forbidden - 403:** Enter the URL to your custom 403 page
3. Click **Save**

These show a branded error page instead of the default App Gateway error when backends are down.

---

## Step 15 — Update DNS

1. Get the App Gateway's public IP:
   - Go to `appgw-demo` → **Overview** → copy the **Frontend public IP address**
2. In your DNS provider (Azure DNS, Cloudflare, GoDaddy, etc.):
   - Create an **A record**: `app1.contoso.com` → `<App-Gateway-Public-IP>`
   - Set TTL to 300 (5 minutes) for testing

---

## Step 16 — Verify End-to-End

### From your browser

Navigate to `https://app1.contoso.com` — you should see the IIS default page (or your custom site).

### Check the certificate chain

Click the padlock icon in the browser:
- The **frontend certificate** is served by App Gateway (from Key Vault)
- App Gateway then connects to the backend VM over HTTPS using the same domain's cert

### From the command line

```bash
# Test frontend TLS
curl -v https://app1.contoso.com 2>&1 | grep "subject:"

# Test with --resolve if DNS hasn't propagated yet
curl -vk --resolve app1.contoso.com:443:<App-Gateway-Public-IP> https://app1.contoso.com
```

### Check backend health

Portal → `appgw-demo` → **Monitoring** → **Backend health**

You should see `bp-backend-vms` with your VM IP showing **Healthy**.

If it shows **Unhealthy**, check:
- IIS is running on the VM
- Port 443 is open in the VM's NSG
- The health probe host header matches the IIS SNI binding (`app1.contoso.com`)
- The certificate on the VM is valid and not expired

---

## Architecture Summary

```
                    Internet
                       │
                       ▼
              ┌─────────────────┐
              │  DNS A Record   │
              │ app1.contoso.com│
              │ → Public IP     │
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐       ┌─────────────────┐
              │  App Gateway v2 │──MI──►│   Key Vault     │
              │  subnet-appgw   │       │   cert-app1     │
              │  (TLS termination       │   (PFX secret)  │
              │   + re-encrypt) │       └─────────────────┘
              └────────┬────────┘
                       │ HTTPS (443)
                       │ Host: app1.contoso.com
                       ▼
              ┌─────────────────┐
              │  VM (IIS)       │
              │  subnet-backend │
              │  10.0.1.4       │
              │  SNI: app1.     │
              │  contoso.com    │
              └─────────────────┘
```

**Key design points:**
- App Gateway connects to backend by **IP address** (not FQDN) — mirrors AVS/on-prem pattern
- **Host header override** in backend settings tells IIS which site to serve
- **Managed Identity** provides passwordless, auditable access to Key Vault
- **Certificate lives in Key Vault** — App Gateway polls every 4 hours for renewals

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Forgot to assign managed identity to App Gateway | Key Vault cert doesn't appear in listener dropdown | App Gateway → Identity → User assigned → Add `id-appgw-demo` |
| Managed identity missing `Key Vault Secrets User` role | Listener creation fails or cert shows warning | Key Vault → IAM → Add role → Secrets User → select the MI |
| Used `Certificates Officer` instead of `Secrets User` for the MI | 403 Forbidden from Key Vault at runtime | App Gateway reads certs as **secrets** (to get the private key) |
| Tried to add Key Vault cert via portal with RBAC | Portal shows "key vault doesn't allow access" | This is a [documented limitation](https://learn.microsoft.com/en-us/azure/application-gateway/key-vault-certs#key-vault-azure-role-based-access-control-permission-model) — use CLI ([Step 13](#step-13--add-the-key-vault-certificate-and-https-listener-cli)) |
| No host header override in backend settings | IIS returns wrong site or default cert | Backend settings → Override hostname → `app1.contoso.com` |
| Backend in same subnet as App Gateway | Deployment fails | App Gateway subnet must be **dedicated** — move VM to `subnet-backend` |
| NSG blocking 443 from App Gateway subnet | Backend health shows Unhealthy | NSG on `subnet-backend` → Allow inbound 443 from `10.0.0.0/24` |
| Health probe using HTTP instead of HTTPS | Backend always Unhealthy (connection refused) | Health probe → Protocol → HTTPS |
| Health probe host blank | Probe sends IP as Host header, IIS rejects | Health probe → Host → `app1.contoso.com` |
| DNS still pointing to old IP | Browser reaches wrong server | Update A record to App Gateway's public IP |
| Using backend FQDN that resolves to App Gateway IP | Routing loop — App Gateway sends traffic to itself | Use the VM's **private IP** in the backend pool, not the FQDN |
