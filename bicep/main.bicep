// main.bicep
// Azure Application Gateway v2 TLS Lab — Main Orchestrator
//
// Deploys:
//   1. User-assigned managed identity
//   2. Virtual network (App GW subnet + backend subnet + optional Bastion)
//   3. Azure Key Vault with RBAC for the managed identity
//   4. Backend VMs (Linux + NGINX, no public IPs)
//   5. Application Gateway v2 (public + private IP, Key Vault TLS)
//
// Usage:
//   az deployment group create \
//     --resource-group rg-appgw-lab \
//     --template-file main.bicep \
//     --parameters sshPublicKey="$(cat ~/.ssh/id_rsa.pub)"
//
//   # After deploying, import cert to Key Vault then update App GW:
//   az deployment group create \
//     --resource-group rg-appgw-lab \
//     --template-file main.bicep \
//     --parameters sshPublicKey="$(cat ~/.ssh/id_rsa.pub)" \
//                  enableHttps=true \
//                  keyVaultSecretId="https://kv-appgw-xxx.vault.azure.net/secrets/appgw-cert/<version>"

targetScope = 'resourceGroup'

// ─── Parameters ─────────────────────────────────────────────────

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('SSH public key for backend VM authentication')
@secure()
param sshPublicKey string

@description('Key Vault name (must be globally unique)')
param keyVaultName string = 'kv-appgw-${uniqueString(resourceGroup().id)}'

@description('Enable HTTPS listener with Key Vault cert')
param enableHttps bool = false

@secure()
@description('Key Vault secret ID for SSL cert (required if enableHttps=true)')
param keyVaultSecretId string = ''

@description('App Gateway SKU: Standard_v2 or WAF_v2')
@allowed([
  'Standard_v2'
  'WAF_v2'
])
param skuName string = 'Standard_v2'

@description('Number of backend VMs')
@minValue(1)
@maxValue(4)
param vmCount int = 2

@description('Enable end-to-end TLS (App Gateway connects to backends over HTTPS:443)')
param enableE2ETLS bool = false

@description('Backend hostname for E2E TLS SNI matching (must match backend cert CN/SAN)')
param backendHostName string = ''

@description('Hostname for multi-site listener (e.g. app1.contoso.com). Enables multi-site mode.')
param listenerHostName string = ''

@description('Hostname for the second site (e.g. app2.contoso.com). Adds a second set of listeners.')
param secondSiteHostName string = ''

@secure()
@description('Key Vault secret ID for the second site SSL certificate')
param secondSiteKeyVaultSecretId string = ''

@description('Deploy Azure Bastion for secure VM access')
param deployBastion bool = false

@description('Deploy backend VMs (set false on Phase 2 redeploy to avoid customData conflict)')
param deployBackend bool = true

@description('Existing backend IPs (required when deployBackend=false)')
param existingBackendIps array = []

@description('Tags applied to all resources')
param tags object = {
  project: 'appgw-letsencrypt-lab'
  environment: 'lab'
}

@description('Custom error page URL for HTTP 502 (Bad Gateway). Must be publicly accessible.')
param customErrorPage502Url string = ''

@description('Custom error page URL for HTTP 403 (Forbidden). Must be publicly accessible.')
param customErrorPage403Url string = ''

// ─── Module 1: User-Assigned Managed Identity ───────────────────

module identity 'identity.bicep' = {
  name: 'deploy-identity'
  params: {
    location: location
    tags: tags
  }
}

// ─── Module 2: Virtual Network ──────────────────────────────────

module network 'network.bicep' = {
  name: 'deploy-network'
  params: {
    location: location
    deployBastion: deployBastion
    tags: tags
  }
}

// ─── Module 3: Azure Key Vault ──────────────────────────────────

module keyVault 'keyvault.bicep' = {
  name: 'deploy-keyvault'
  params: {
    location: location
    keyVaultName: keyVaultName
    appGatewayPrincipalId: identity.outputs.principalId
    tags: tags
  }
}

// ─── Module 4: Backend VMs ──────────────────────────────────────

module backend 'backend.bicep' = if (deployBackend) {
  name: 'deploy-backend'
  params: {
    location: location
    subnetId: network.outputs.backendSubnetId
    vmCount: vmCount
    sshPublicKey: sshPublicKey
    tags: tags
  }
}

// Resolve backend IPs from module output or parameter
var resolvedBackendIps = deployBackend ? backend.outputs.backendPrivateIps : existingBackendIps

// ─── Module 5: Application Gateway ──────────────────────────────

module appGateway 'appgw.bicep' = {
  name: 'deploy-appgw'
  params: {
    location: location
    subnetId: network.outputs.appGatewaySubnetId
    identityId: identity.outputs.identityId
    backendIpAddresses: resolvedBackendIps
    skuName: skuName
    enableHttps: enableHttps
    keyVaultSecretId: keyVaultSecretId
    enableE2ETLS: enableE2ETLS
    backendHostName: backendHostName
    listenerHostName: listenerHostName
    secondSiteHostName: secondSiteHostName
    secondSiteKeyVaultSecretId: secondSiteKeyVaultSecretId
    customErrorPage502Url: customErrorPage502Url
    customErrorPage403Url: customErrorPage403Url
    tags: tags
  }
}

// ─── Outputs ────────────────────────────────────────────────────

@description('Application Gateway public IP address')
output appGatewayPublicIp string = appGateway.outputs.publicIp

@description('Application Gateway private IP address')
output appGatewayPrivateIp string = appGateway.outputs.privateIp

@description('Key Vault name — import your cert here')
output keyVaultName string = keyVault.outputs.keyVaultName

@description('Key Vault URI')
output keyVaultUri string = keyVault.outputs.keyVaultUri

@description('Managed identity principal ID')
output identityPrincipalId string = identity.outputs.principalId

@description('Backend VM private IPs')
output backendVmIps array = resolvedBackendIps

@description('Next step instructions')
output nextSteps string = enableHttps
  ? 'HTTPS is configured. Verify your App Gateway HTTPS listener is healthy.'
  : 'Infrastructure deployed. Next: (1) Issue cert via DNS-01, (2) Import to Key Vault: az keyvault certificate import --vault-name ${keyVault.outputs.keyVaultName} --name appgw-cert --file appgw-cert.pfx, (3) Re-deploy with enableHttps=true and keyVaultSecretId=<secret-uri>'
