# Feature Demo Guide

This lab deploys several App Gateway features beyond basic TLS termination. Each feature is documented on the **live landing page** (served by the backend VMs) with a dedicated card showing the configuration and its effect in real time.

---

## Rewrite Rules — Response Headers

App Gateway **Rewrite Rules** modify HTTP headers and URLs in-flight — the equivalent of **F5 iRules** or **LTM Policies**. They are defined in a **Rewrite Rule Set** (`rwset-security-headers`) and attached to HTTPS routing rules, so every response flowing through those rules is automatically modified.

### What's Deployed

| Rule Name | Sequence | Action | Header | Value |
|---|---|---|---|---|
| `rw-add-hsts` | 100 | **Set** response header | `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` |
| `rw-strip-server` | 200 | **Delete** response header | `Server` | *(empty — removes the header entirely)* |
| `rw-add-xcto` | 300 | **Set** response header | `X-Content-Type-Options` | `nosniff` |

### What Each Rule Does

**`rw-add-hsts`** — Injects `Strict-Transport-Security: max-age=31536000; includeSubDomains` into every response. Tells browsers "never connect to this domain over HTTP again for 1 year." Once a browser sees this header, it automatically upgrades any `http://` request to `https://` locally — the request never leaves the browser as plaintext. Prevents SSL-stripping attacks (e.g., a rogue Wi-Fi intercepting the initial HTTP request before the 301 redirect fires).

**`rw-strip-server`** — Deletes the `Server` response header entirely. Without this rule, every response includes `Server: nginx/1.x.x`, which tells attackers exactly what software and version the backend runs. That's the first thing a scanner looks for — known CVEs for that specific version. Setting the header value to an empty string causes App Gateway to strip it completely.

**`rw-add-xcto`** — Adds `X-Content-Type-Options: nosniff` to every response. Prevents browsers from "MIME-type sniffing" — where the browser ignores the declared `Content-Type` and guesses based on content. Without this, an attacker could upload a file that looks like HTML but is served as `text/plain`, and the browser might execute it as HTML/JavaScript anyway. `nosniff` forces the browser to trust the server's declared type.

All three are **response header** rewrites — they modify what the client receives, not what the backend sees.

### How to Demo

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

### F5 Comparison

| F5 BIG-IP | Azure App Gateway |
|---|---|
| iRule: `HTTP::header insert` in `HTTP_RESPONSE` | Rewrite Rule → Set response header |
| iRule: `HTTP::header remove` in `HTTP_RESPONSE` | Rewrite Rule → Set header value to empty string |
| iRule attached to virtual server | Rewrite Rule Set attached to routing rule |
| iRule = Tcl scripting, requires developer skill | Rewrite Rule = declarative config, portal or Bicep IaC |
| iRule debugging: `log local0.` + tcpdump | Rewrite Rule verification: check response headers in browser DevTools |
| iRule error can crash a virtual server | Rewrite Rule misconfiguration is isolated, no crash risk |

> **Key talking point:** *"Everything you did with iRules for header manipulation is a declarative checkbox in App Gateway — no Tcl, no scripting, no risk of a syntax error taking down a VIP."*
