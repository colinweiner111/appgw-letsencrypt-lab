// keyvault.bicep
// Azure Key Vault with RBAC authorization for App Gateway managed identity
//
// Design decisions:
// - Azure RBAC (not access policies) — modern best practice
// - Soft delete + purge protection enabled
// - App Gateway identity gets Key Vault Secrets User role
// - App Gateway reads certs via secret URI, not certificate URI

@description('Azure region')
param location string

@description('Key Vault name (must be globally unique)')
param keyVaultName string

@description('Principal ID of the App Gateway managed identity')
param appGatewayPrincipalId string

@description('Enable public network access (true for lab simplicity, false for private endpoint)')
param publicNetworkAccess bool = true

@description('Tags to apply to resources')
param tags object = {}

// ─── Key Vault ──────────────────────────────────────────────────

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: publicNetworkAccess ? 'Enabled' : 'Disabled'
  }
}

// ─── RBAC: Key Vault Secrets User → App Gateway Identity ────────

// Built-in role: Key Vault Secrets User (4633458b-17de-408a-b874-0445c86b69e6)
// Grants secrets/get and secrets/list — minimum required for App Gateway TLS
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, appGatewayPrincipalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    principalId: appGatewayPrincipalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalType: 'ServicePrincipal'
  }
}

// ─── Outputs ────────────────────────────────────────────────────

@description('Resource ID of the Key Vault')
output keyVaultId string = keyVault.id

@description('Key Vault name')
output keyVaultName string = keyVault.name

@description('Key Vault URI')
output keyVaultUri string = keyVault.properties.vaultUri
