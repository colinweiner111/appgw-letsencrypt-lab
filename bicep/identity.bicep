// identity.bicep
// User-Assigned Managed Identity for Application Gateway → Key Vault access
// Enterprise-preferred: reusable, explicit RBAC, cleaner separation than system-assigned

@description('Azure region for the managed identity')
param location string

@description('Name of the user-assigned managed identity')
param identityName string = 'id-appgw-lab'

@description('Tags to apply to resources')
param tags object = {}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

@description('Resource ID of the managed identity')
output identityId string = managedIdentity.id

@description('Principal ID for RBAC assignments')
output principalId string = managedIdentity.properties.principalId

@description('Client ID of the managed identity')
output clientId string = managedIdentity.properties.clientId
