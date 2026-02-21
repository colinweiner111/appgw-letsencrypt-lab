// appgw.bicep
// Application Gateway v2 — public + private frontend, Key Vault TLS integration
//
// Design decisions:
// - Public IP for internet-facing HTTPS + private IP for VNet-internal access
// - User-assigned managed identity for Key Vault access
// - SSL cert referenced via Key Vault secret URI
// - Explicit health probe (never rely on defaults)
// - Autoscale enabled
// - HTTPS listener with optional HTTP → HTTPS redirect

@description('Azure region')
param location string

@description('Name of the Application Gateway')
param appGatewayName string = 'appgw-lab'

@description('App Gateway subnet resource ID')
param subnetId string

@description('User-assigned managed identity resource ID')
param identityId string

@secure()
@description('Key Vault secret ID for the SSL certificate (full URI with version)')
param keyVaultSecretId string = ''

@description('Private IP address for the App Gateway frontend')
param privateIpAddress string = '10.0.0.10'

@description('Backend VM private IP addresses')
param backendIpAddresses array = []

@description('App Gateway SKU: Standard_v2 or WAF_v2')
@allowed([
  'Standard_v2'
  'WAF_v2'
])
param skuName string = 'Standard_v2'

@description('Minimum autoscale capacity')
@minValue(0)
@maxValue(10)
param minCapacity int = 1

@description('Maximum autoscale capacity')
@minValue(1)
@maxValue(32)
param maxCapacity int = 2

@description('Deploy HTTPS listener with Key Vault cert (requires keyVaultSecretId)')
param enableHttps bool = false

@description('Tags to apply to resources')
param tags object = {}

// ─── Backend address pool ───────────────────────────────────────

var backendAddresses = [
  for ip in backendIpAddresses: {
    ipAddress: ip
  }
]

// ─── Public IP Address ──────────────────────────────────────────

resource publicIP 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${appGatewayName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// ─── Application Gateway ────────────────────────────────────────

resource appGateway 'Microsoft.Network/applicationGateways@2023-11-01' = {
  name: appGatewayName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    sku: {
      name: skuName
      tier: skuName
    }
    autoscaleConfiguration: {
      minCapacity: minCapacity
      maxCapacity: maxCapacity
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: subnetId
          }
        }
      }
    ]

    // ── Frontend IPs: public + private ────────────────────────
    frontendIPConfigurations: [
      {
        name: 'appGatewayPublicFrontendIP'
        properties: {
          publicIPAddress: {
            id: publicIP.id
          }
        }
      }
      {
        name: 'appGatewayPrivateFrontendIP'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: privateIpAddress
          subnet: {
            id: subnetId
          }
        }
      }
    ]

    // ── Frontend ports ────────────────────────────────────────
    frontendPorts: union(
      [
        {
          name: 'port-http'
          properties: {
            port: 80
          }
        }
      ],
      enableHttps
        ? [
            {
              name: 'port-https'
              properties: {
                port: 443
              }
            }
          ]
        : []
    )

    // ── SSL certificates (Key Vault reference) ───────────────
    sslCertificates: enableHttps && !empty(keyVaultSecretId)
      ? [
          {
            name: 'appgw-cert'
            properties: {
              keyVaultSecretId: keyVaultSecretId
            }
          }
        ]
      : []

    // ── Listeners ─────────────────────────────────────────────
    httpListeners: enableHttps
        ? [
            {
              name: 'https-listener'
              properties: {
                frontendIPConfiguration: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/frontendIPConfigurations',
                    appGatewayName,
                    'appGatewayPublicFrontendIP'
                  )
                }
                frontendPort: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/frontendPorts',
                    appGatewayName,
                    'port-https'
                  )
                }
                protocol: 'Https'
                sslCertificate: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/sslCertificates',
                    appGatewayName,
                    'appgw-cert'
                  )
                }
              }
            }
            {
              name: 'http-listener'
              properties: {
                frontendIPConfiguration: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/frontendIPConfigurations',
                    appGatewayName,
                    'appGatewayPublicFrontendIP'
                  )
                }
                frontendPort: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/frontendPorts',
                    appGatewayName,
                    'port-http'
                  )
                }
                protocol: 'Http'
              }
            }
          ]
        : [
            {
              name: 'http-listener'
              properties: {
                frontendIPConfiguration: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/frontendIPConfigurations',
                    appGatewayName,
                    'appGatewayPublicFrontendIP'
                  )
                }
                frontendPort: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/frontendPorts',
                    appGatewayName,
                    'port-http'
                  )
                }
                protocol: 'Http'
              }
            }
          ]

    // ── Backend pool ──────────────────────────────────────────
    backendAddressPools: [
      {
        name: 'backend-pool'
        properties: {
          backendAddresses: backendAddresses
        }
      }
    ]

    // ── Backend HTTP settings ─────────────────────────────────
    backendHttpSettingsCollection: [
      {
        name: 'http-settings'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          probe: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/probes',
              appGatewayName,
              'health-probe'
            )
          }
        }
      }
    ]

    // ── Health probe (explicit, never rely on defaults) ───────
    probes: [
      {
        name: 'health-probe'
        properties: {
          protocol: 'Http'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          host: '127.0.0.1'
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]

    // ── Routing rules ─────────────────────────────────────────
    requestRoutingRules: enableHttps
        ? [
            {
              name: 'https-rule'
              properties: {
                priority: 100
                ruleType: 'Basic'
                httpListener: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/httpListeners',
                    appGatewayName,
                    'https-listener'
                  )
                }
                backendAddressPool: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/backendAddressPools',
                    appGatewayName,
                    'backend-pool'
                  )
                }
                backendHttpSettings: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
                    appGatewayName,
                    'http-settings'
                  )
                }
              }
            }
            {
              name: 'http-to-https-redirect'
              properties: {
                priority: 200
                ruleType: 'Basic'
                httpListener: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/httpListeners',
                    appGatewayName,
                    'http-listener'
                  )
                }
                redirectConfiguration: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/redirectConfigurations',
                    appGatewayName,
                    'http-to-https'
                  )
                }
              }
            }
          ]
        : [
            {
              name: 'http-rule'
              properties: {
                priority: 100
                ruleType: 'Basic'
                httpListener: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/httpListeners',
                    appGatewayName,
                    'http-listener'
                  )
                }
                backendAddressPool: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/backendAddressPools',
                    appGatewayName,
                    'backend-pool'
                  )
                }
                backendHttpSettings: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
                    appGatewayName,
                    'http-settings'
                  )
                }
              }
            }
          ]

    // ── Redirect configuration (HTTP → HTTPS) ────────────────
    redirectConfigurations: enableHttps
      ? [
          {
            name: 'http-to-https'
            properties: {
              redirectType: 'Permanent'
              targetListener: {
                id: resourceId(
                  'Microsoft.Network/applicationGateways/httpListeners',
                  appGatewayName,
                  'https-listener'
                )
              }
              includePath: true
              includeQueryString: true
            }
          }
        ]
      : []
  }
}

// ─── Outputs ────────────────────────────────────────────────────

@description('Resource ID of the Application Gateway')
output appGatewayId string = appGateway.id

@description('Public IP address')
output publicIp string = publicIP.properties.ipAddress

@description('Public IP resource ID')
output publicIpId string = publicIP.id

@description('Private frontend IP address')
output privateIp string = privateIpAddress
