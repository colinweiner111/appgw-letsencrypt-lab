# How Let's Encrypt Works

A beginner-friendly guide to Let's Encrypt, ACME challenges, and how they apply to Azure Application Gateway.

## Table of Contents

- [The Problem](#the-problem)
- [What Is Let's Encrypt?](#what-is-lets-encrypt)
- [The ACME Protocol](#the-acme-protocol)
- [Challenge Types](#challenge-types)
- [What Is Certbot?](#what-is-certbot)
- [The Certificate Files](#the-certificate-files)
- [The Trust Chain](#the-trust-chain)
- [Why App Gateway Needs a PFX](#why-app-gateway-needs-a-pfx)
- [Certificate Lifetime and Renewal](#certificate-lifetime-and-renewal)
- [Glossary](#glossary)

---

## The Problem

You want your users to connect to your app over HTTPS. To do that, your web server (or in this case, Azure Application Gateway) needs a **TLS certificate** — a digital file that proves "yes, this server really is `appgw-lab.yourdomain.com`."

Traditionally, you'd buy a certificate from a Certificate Authority (CA) like DigiCert or GoDaddy for $50-$200/year. You'd generate a CSR, email it to the CA, wait for approval, download the cert, convert it to the right format, and upload it.

**Let's Encrypt eliminates all of that.** Free certificates, issued in seconds, fully automated.

---

## What Is Let's Encrypt?

[Let's Encrypt](https://letsencrypt.org/) is a **free, automated, open Certificate Authority** run by the nonprofit Internet Security Research Group (ISRG). It launched in 2015 and now secures over 300 million websites.

Key facts:

| | |
|---|---|
| **Cost** | Free. Always. |
| **Certificate type** | Domain Validation (DV) — proves you control the domain |
| **Validity** | 90 days (short by design, to encourage automation) |
| **Issuance speed** | Seconds, not days |
| **Wildcard support** | Yes (via DNS-01 challenge only) |
| **Rate limits** | 50 certificates per registered domain per week |

> **DV vs. OV vs. EV:** Let's Encrypt issues Domain Validation (DV) certificates. These prove domain ownership but don't verify your organization's identity. For a lab or internal app, DV is perfectly fine. For a customer-facing bank website, your org might want an OV or EV cert from a paid CA — but that's a policy decision, not a technical one.

---

## The ACME Protocol

Let's Encrypt doesn't have humans reviewing certificate requests. Instead, it uses a protocol called **ACME** (Automatic Certificate Management Environment) to verify that you control a domain.

The flow:

```
┌──────────────┐                          ┌───────────────────┐
│  Your Machine │                          │  Let's Encrypt    │
│  (certbot)    │                          │  ACME Server      │
└──────┬───────┘                          └────────┬──────────┘
       │                                           │
       │  1. "I want a cert for appgw-lab.foo.com" │
       │──────────────────────────────────────────►│
       │                                           │
       │  2. "Prove you control that domain.       │
       │      Here's a challenge token: abc123"    │
       │◄──────────────────────────────────────────│
       │                                           │
       │  3. (You complete the challenge)          │
       │                                           │
       │  4. "Done — check now."                   │
       │──────────────────────────────────────────►│
       │                                           │
       │  5. (LE verifies the challenge)           │
       │                                           │
       │  6. "Verified ✓ — here's your cert."     │
       │◄──────────────────────────────────────────│
       │                                           │
```

Certbot automatically generates the CSR (Certificate Signing Request) and key pair locally before contacting the ACME server — you never handle the CSR yourself.

The critical part is step 3: **how you prove domain control.** That's where challenge types come in.

---

## Challenge Types

Let's Encrypt supports two main challenge types. Which one you use depends on your architecture.

### HTTP-01 Challenge

```
How it works:
  1. Let's Encrypt gives you a token (e.g., "abc123")
  2. You place a file at:  http://yourdomain.com/.well-known/acme-challenge/abc123
  3. Let's Encrypt fetches that URL from the public internet
  4. If the file is there → you control the domain → cert issued
```

| Pros | Cons |
|---|---|
| Simple, no DNS access needed | **Requires port 80 open to the internet** |
| Works with any DNS provider | Cannot issue wildcard certs |
| Easy to automate | Doesn't work for private-only servers |

**For App Gateway:** HTTP-01 works when your App Gateway has a **public IP** and port 80 is reachable from the internet. This lab deploys a public IP, so HTTP-01 is an option. However, DNS-01 is still recommended because it doesn't require temporarily opening port 80.

### DNS-01 Challenge

```
How it works:
  1. Let's Encrypt gives you a validation string (e.g., "xyz789...")
  2. You create a DNS TXT record:
       _acme-challenge.yourdomain.com  TXT  "xyz789..."
  3. Let's Encrypt queries public DNS for that TXT record
  4. If the record exists with the correct value → cert issued
```

| Pros | Cons |
|---|---|
| **No public IP or open port needed** | Requires DNS API access or manual DNS editing |
| Works with private servers | Slightly more complex |
| Supports wildcard certs | DNS propagation can add delay |
| More secure (no public exposure) | |

**For App Gateway:** DNS-01 is the **recommended approach** for App Gateway TLS labs. Your App Gateway doesn't need to be reachable from the internet during certificate issuance — you just need the ability to create a TXT record in your public DNS zone.

> **Critical:** DNS-01 requires the DNS zone to be **publicly resolvable**. Azure Private DNS zones and on-prem internal-only DNS will **not** work — Let's Encrypt validates by querying public DNS resolvers. Even if your App Gateway is private, the `_acme-challenge` TXT record must live in a public zone.

> **CAA Records:** If your domain uses [CAA records](https://letsencrypt.org/docs/caa/), ensure they allow issuance by `letsencrypt.org`. Otherwise the challenge will succeed but certificate issuance will be denied.

### Side-by-Side

```
HTTP-01:                              DNS-01:
  Let's Encrypt                         Let's Encrypt
       │                                     │
       │  GET http://domain/                  │  DNS lookup
       │  .well-known/acme-challenge/abc      │  _acme-challenge.domain TXT
       │                                     │
       ▼                                     ▼
  ┌──────────┐                         ┌──────────┐
  │ App GW   │ ← must be public!      │  DNS     │ ← always public
  │ port 80  │                         │  Zone    │
  └──────────┘                         └──────────┘
```

---

## What Is Certbot?

**[Certbot](https://certbot.eff.org/)** is a free, open-source tool that implements the ACME protocol. It's the most popular Let's Encrypt client.

What certbot does:
1. Talks to Let's Encrypt's ACME server
2. Handles the challenge (HTTP-01 or DNS-01)
3. Downloads the signed certificate
4. Saves the certificate files to disk

Certbot runs on **Linux, macOS, and Windows**. For this lab on Windows, you have three options:

| Option | How | Best for |
|---|---|---|
| **WSL** (recommended) | `sudo apt install certbot` in WSL | Windows users who want the standard Linux experience |
| **Chocolatey** | `choco install certbot` natively on Windows | Quick and simple |
| **Azure Cloud Shell** | Pre-installed in Cloud Shell (bash) | No local install needed |

> **Important:** Certbot just issues the certificate. It doesn't upload it to App Gateway — that's a separate step using Azure CLI or the portal. Certbot doesn't know or care about Azure.

> **No signup required:** On first run, Certbot automatically creates and registers an ACME account with Let's Encrypt. You don't need to create an account or sign up anywhere — just run the command.

### Running Certbot

For DNS-01 (the recommended approach for App Gateway):

```bash
certbot certonly \
  --manual \
  --preferred-challenges dns \
  --config-dir ~/letsencrypt --work-dir ~/letsencrypt/work --logs-dir ~/letsencrypt/logs \
  -d appgw-lab.yourdomain.com
```

Breaking down the flags:
- `certonly` — just get the cert, don't try to install it on a web server
- `--manual` — I'll handle the DNS record myself (as opposed to using a DNS plugin)
- `--preferred-challenges dns` — use the DNS-01 challenge type
- `-d appgw-lab.yourdomain.com` — the domain name for the certificate

Certbot will pause and ask you to create a TXT record. Once you do, press Enter and it continues.

---

## The Certificate Files

After certbot succeeds, it saves files to `~/letsencrypt/live/yourdomain.com/`:

```
~/letsencrypt/live/appgw-lab.yourdomain.com/
├── privkey.pem        ← Your private key (never share this)
├── cert.pem           ← Your certificate only (leaf cert)
├── chain.pem          ← The intermediate CA certificate
└── fullchain.pem      ← cert.pem + chain.pem combined (USE THIS ONE)
```

| File | What's in it | When to use |
|---|---|---|
| `privkey.pem` | Your private key | Always needed for PFX conversion |
| `fullchain.pem` | Your cert + intermediate CA cert | **Use this** for PFX conversion |
| `cert.pem` | Just your cert (no intermediate) | **Don't use this** — causes trust errors |
| `chain.pem` | Just the intermediate CA cert | Rarely needed alone |

> **The #1 mistake** people make: using `cert.pem` instead of `fullchain.pem` when creating the PFX. This produces a certificate that looks valid but fails in browsers because the intermediate CA is missing from the chain. Always use `fullchain.pem`.

---

## The Trust Chain

When a browser verifies your certificate, it checks a chain of signatures:

```
┌─────────────────────────────────────────────────────┐
│  ISRG Root X1  (Root CA)                             │
│  • Built into browsers and OS trust stores           │
│  • Self-signed — the ultimate trust anchor           │
│                                                      │
│       ▼  signs                                       │
│                                                      │
│  R10 / R11  (Intermediate CA)                        │
│  • Signed by ISRG Root X1                            │
│  • This is what actually signs your certificate      │
│  • This is what's in chain.pem / fullchain.pem       │
│                                                      │
│       ▼  signs                                       │
│                                                      │
│  appgw-lab.yourdomain.com  (Your Certificate)        │
│  • Signed by the intermediate CA                     │
│  • Contains your domain name and public key          │
│  • This is what's in cert.pem                        │
└─────────────────────────────────────────────────────┘
```

The browser needs to build this chain:
- **Your cert** (you provide this) → signed by **Intermediate** (you provide this in fullchain.pem) → signed by **Root CA** (already in the browser's trust store)

If the intermediate is missing (because you used `cert.pem`), the browser can't build the chain and shows a security warning.

---

## Why App Gateway Needs a PFX

Azure Application Gateway doesn't accept PEM files. It requires a **PFX** (also called PKCS#12) file — a single binary file that bundles:

1. Your private key (`privkey.pem`)
2. Your certificate (`cert.pem`)
3. The intermediate certificate(s) (`chain.pem`)

The conversion command:

```bash
openssl pkcs12 -export \
  -out appgw-cert.pfx \
  -inkey privkey.pem \
  -in fullchain.pem
```

You'll be prompted for a password — this protects the PFX file since it contains your private key. You'll need this password when uploading to App Gateway or Key Vault.

> **Why PFX?** It's a Windows/Azure convention. Linux typically uses separate PEM files. Azure services like App Gateway and Key Vault expect the bundled PFX format. The `openssl pkcs12` command bridges the two worlds.

> **Azure Tip:** Application Gateway v2 supports [Key Vault integration](https://learn.microsoft.com/azure/application-gateway/key-vault-certs) — instead of uploading PFX directly, you import it to Key Vault and App Gateway retrieves it automatically via a user-assigned managed identity. This is the pattern used in this lab's Bicep infrastructure.

---

## Certificate Lifetime and Renewal

Let's Encrypt certificates are valid for **90 days** — intentionally short to encourage automation and limit damage if a key is compromised.

```
Day 0:   Certificate issued          ← certbot certonly
Day 60:  Renewal window opens        ← certbot renew starts working
Day 90:  Certificate expires          ← HTTPS stops working if not renewed
```

For this lab, manual renewal is fine — just re-run the steps. For longer-lived environments:

| Approach | Complexity | Best for |
|---|---|---|
| Re-run certbot manually | Low | Labs and one-off demos |
| Cron job + certbot renew | Medium | Linux VMs running certbot |
| Azure Automation runbook | Medium | Scheduled Azure-native renewal |
| GitHub Actions workflow | Medium | CI/CD-integrated renewal |
| Azure Key Vault + Let's Encrypt | Medium | Import PFX to KV, App GW pulls via managed identity |
| Azure App Service Managed Certificates | High | Production; built-in auto-renewal but not Let's Encrypt |

---

## Glossary

| Term | Definition |
|---|---|
| **ACME** | Automatic Certificate Management Environment — the protocol Let's Encrypt uses |
| **CA** | Certificate Authority — an organization trusted to issue certificates |
| **Certbot** | A free tool that talks to Let's Encrypt's ACME server to get certificates |
| **CSR** | Certificate Signing Request — a file you send to a CA (certbot handles this for you) |
| **DNS-01** | An ACME challenge where you prove domain control via a DNS TXT record |
| **DV** | Domain Validation — proves you control a domain (not your org identity) |
| **fullchain.pem** | Your certificate + the intermediate CA certificate bundled together |
| **HTTP-01** | An ACME challenge where Let's Encrypt connects to port 80 on your domain |
| **Intermediate CA** | A CA certificate signed by the root CA, which signs your certificate |
| **ISRG** | Internet Security Research Group — the nonprofit behind Let's Encrypt |
| **Leaf certificate** | Your certificate (the bottom of the trust chain) |
| **Let's Encrypt** | A free, automated Certificate Authority |
| **PEM** | Privacy Enhanced Mail — a text-based certificate format (base64-encoded) |
| **PFX / PKCS#12** | A binary format that bundles private key + certs into one file |
| **Private key** | The secret half of your key pair — never share it |
| **Root CA** | The top of the trust chain — built into browsers |
| **TLS** | Transport Layer Security — the protocol HTTPS uses (successor to SSL) |
| **TXT record** | A DNS record type used for DNS-01 challenges |

---

## Further Reading

- [Let's Encrypt — How It Works](https://letsencrypt.org/how-it-works/)
- [Let's Encrypt — Challenge Types](https://letsencrypt.org/docs/challenge-types/)
- [Certbot Documentation](https://eff-certbot.readthedocs.io/)
- [ACME Protocol (RFC 8555)](https://datatracker.ietf.org/doc/html/rfc8555)
- [Azure App Gateway TLS Overview](https://learn.microsoft.com/azure/application-gateway/ssl-overview)
- [Azure App Gateway Key Vault Integration](https://learn.microsoft.com/azure/application-gateway/key-vault-certs)

---

← Back to [README](../README.md)
