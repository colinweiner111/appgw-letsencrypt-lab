// main.bicep
// Azure Application Gateway v2 TLS Lab — Main Orchestrator
//
// Deploys:
//   1. User-assigned managed identity
//   2. Virtual network (App GW subnet + backend subnet + optional Bastion)
//   3. Azure Key Vault with RBAC for the managed identity
//   4. Backend VMs (Linux + NGINX, no public IPs)
//   5. Application Gateway v2 (private IP, Key Vault TLS)
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

@description('Deploy Azure Bastion for secure VM access')
param deployBastion bool = false

@description('Tags applied to all resources')
param tags object = {
  project: 'appgw-letsencrypt-lab'
  environment: 'lab'
}

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

module backend 'backend.bicep' = {
  name: 'deploy-backend'
  params: {
    location: location
    subnetId: network.outputs.backendSubnetId
    vmCount: vmCount
    sshPublicKey: sshPublicKey
    tags: tags
  }
}

// ─── Module 5: Application Gateway ──────────────────────────────

module appGateway 'appgw.bicep' = {
  name: 'deploy-appgw'
  params: {
    location: location
    subnetId: network.outputs.appGatewaySubnetId
    identityId: identity.outputs.identityId
    backendIpAddresses: backend.outputs.backendPrivateIps
    skuName: skuName
    enableHttps: enableHttps
    keyVaultSecretId: keyVaultSecretId
    tags: tags
  }
}

// ─── Outputs ────────────────────────────────────────────────────

@description('Application Gateway private IP address')
output appGatewayPrivateIp string = appGateway.outputs.privateIp

@description('Key Vault name — import your cert here')
output keyVaultName string = keyVault.outputs.keyVaultName

@description('Key Vault URI')
output keyVaultUri string = keyVault.outputs.keyVaultUri

@description('Managed identity principal ID')
output identityPrincipalId string = identity.outputs.principalId

@description('Backend VM private IPs')
output backendVmIps array = backend.outputs.backendPrivateIps

@description('Next step instructions')
output nextSteps string = enableHttps
  ? 'HTTPS is configured. Verify your App Gateway HTTPS listener is healthy.'
  : 'Infrastructure deployed. Next: (1) Issue cert via DNS-01, (2) Import to Key Vault: az keyvault certificate import --vault-name ${keyVault.outputs.keyVaultName} --name appgw-cert --file appgw-cert.pfx, (3) Re-deploy with enableHttps=true and keyVaultSecretId=<secret-uri>'
