// network.bicep
// Virtual Network with dedicated subnets for App Gateway, backend VMs, and optional Bastion
//
// Design decisions:
// - App Gateway MUST be in its own dedicated subnet (Azure requirement)
// - No other resources allowed in the App Gateway subnet
// - Backend VMs in a separate subnet with no public IPs
// - Optional Bastion subnet for secure management access

@description('Azure region')
param location string

@description('Name of the virtual network')
param vnetName string = 'vnet-appgw-lab'

@description('VNet address space')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('App Gateway subnet address prefix')
param appGatewaySubnetPrefix string = '10.0.0.0/24'

@description('Backend VM subnet address prefix')
param backendSubnetPrefix string = '10.0.1.0/24'

@description('Deploy Azure Bastion subnet for secure VM management')
param deployBastion bool = false

@description('Bastion subnet address prefix (must be named AzureBastionSubnet)')
param bastionSubnetPrefix string = '10.0.2.0/26'

@description('Tags to apply to resources')
param tags object = {}

// ─── Network Security Groups ────────────────────────────────────

resource nsgBackend 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-backend'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowAppGatewayProbes'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: appGatewaySubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'AllowAppGatewayTraffic'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: appGatewaySubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'DenyDirectInternet'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgAppGateway 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-appgw'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowGatewayManager'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'GatewayManager'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '65200-65535'
        }
      }
      {
        name: 'AllowHTTPS'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

// ─── Virtual Network ────────────────────────────────────────────

var subnets = union(
  [
    {
      name: 'subnet-appgw'
      properties: {
        addressPrefix: appGatewaySubnetPrefix
        networkSecurityGroup: {
          id: nsgAppGateway.id
        }
      }
    }
    {
      name: 'subnet-backend'
      properties: {
        addressPrefix: backendSubnetPrefix
        networkSecurityGroup: {
          id: nsgBackend.id
        }
      }
    }
  ],
  deployBastion
    ? [
        {
          name: 'AzureBastionSubnet'
          properties: {
            addressPrefix: bastionSubnetPrefix
          }
        }
      ]
    : []
)

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: subnets
  }
}

// ─── Outputs ────────────────────────────────────────────────────

@description('Resource ID of the virtual network')
output vnetId string = vnet.id

@description('Resource ID of the App Gateway subnet')
output appGatewaySubnetId string = vnet.properties.subnets[0].id

@description('Resource ID of the backend subnet')
output backendSubnetId string = vnet.properties.subnets[1].id

@description('Bastion subnet ID (empty if not deployed)')
output bastionSubnetId string = deployBastion ? vnet.properties.subnets[2].id : ''
