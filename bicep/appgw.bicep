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

@description('Enable end-to-end TLS (backend pool uses HTTPS:443 instead of HTTP:80)')
param enableE2ETLS bool = false

@description('Backend hostname for E2E TLS SNI (must match backend cert CN/SAN, e.g. app1.contoso.com)')
param backendHostName string = ''

@description('Hostname for multi-site listener (e.g. app1.contoso.com). When set, listeners use Multi-site mode instead of Basic.')
param listenerHostName string = ''

@description('Hostname for a second site (e.g. app2.contoso.com). Adds a second set of multi-site listeners, backend settings, and routing rules.')
param secondSiteHostName string = ''

@secure()
@description('Key Vault secret ID for the second site SSL certificate')
param secondSiteKeyVaultSecretId string = ''

@description('Tags to apply to resources')
param tags object = {}

@description('Custom error page URL for HTTP 502 (Bad Gateway). Must be a publicly accessible URL.')
param customErrorPage502Url string = ''

@description('Custom error page URL for HTTP 403 (Forbidden). Must be a publicly accessible URL.')
param customErrorPage403Url string = ''

// ─── Backend address pool ───────────────────────────────────────

var backendAddresses = [
  for ip in backendIpAddresses: {
    ipAddress: ip
  }
]

var hasSecondSite = enableHttps && !empty(secondSiteHostName) && !empty(secondSiteKeyVaultSecretId)

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

    // ── Custom error pages (gateway-level) ──────────────
    // Equivalent of F5 Sorry Pages / fallback iRules.
    // Serves branded HTML from Azure Blob Storage when backends are down (502)
    // or requests are blocked (403).
    customErrorConfigurations: union(
      !empty(customErrorPage502Url) ? [
        {
          statusCode: 'HttpStatus502'
          customErrorPageUrl: customErrorPage502Url
        }
      ] : [],
      !empty(customErrorPage403Url) ? [
        {
          statusCode: 'HttpStatus403'
          customErrorPageUrl: customErrorPage403Url
        }
      ] : []
    )
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

    // ── SSL Policy (gateway-wide default) ────────────────────
    sslPolicy: {
      policyType: 'Predefined'
      policyName: 'AppGwSslPolicy20220101'
    }

    // ── SSL Profiles (per-listener TLS policy override) ────────
    // Listeners WITHOUT an SSL Profile inherit the gateway-wide default above.
    // Listeners WITH an SSL Profile use their own stricter policy.
    sslProfiles: hasSecondSite
      ? [
          {
            name: 'sslprof-app2'
            properties: {
              sslPolicy: {
                policyType: 'Predefined'
                policyName: 'AppGwSslPolicy20220101S'
              }
            }
          }
        ]
      : []

    // ── Rewrite Rule Sets (response header manipulation) ─────
    // Equivalent of F5 iRules / LTM Policies for header rewriting.
    // Applied to routing rules — every response through those rules
    // gets these headers added, stripped, or overwritten.
    rewriteRuleSets: enableHttps ? [
      {
        name: 'rwset-security-headers'
        properties: {
          rewriteRules: [
            {
              ruleSequence: 100
              name: 'rw-add-hsts'
              actionSet: {
                responseHeaderConfigurations: [
                  {
                    headerName: 'Strict-Transport-Security'
                    headerValue: 'max-age=31536000; includeSubDomains'
                  }
                ]
              }
            }
            {
              ruleSequence: 200
              name: 'rw-strip-server'
              actionSet: {
                responseHeaderConfigurations: [
                  {
                    headerName: 'Server'
                    headerValue: ''
                  }
                ]
              }
            }
            {
              ruleSequence: 300
              name: 'rw-add-xcto'
              actionSet: {
                responseHeaderConfigurations: [
                  {
                    headerName: 'X-Content-Type-Options'
                    headerValue: 'nosniff'
                  }
                ]
              }
            }
          ]
        }
      }
    ] : []

    // ── SSL certificates (Key Vault reference) ───────────────
    sslCertificates: union(
      enableHttps && !empty(keyVaultSecretId)
        ? [
            {
              name: 'cert-app1'
              properties: {
                keyVaultSecretId: keyVaultSecretId
              }
            }
          ]
        : [],
      hasSecondSite
        ? [
            {
              name: 'cert-app2'
              properties: {
                keyVaultSecretId: secondSiteKeyVaultSecretId
              }
            }
          ]
        : []
    )

    // ── Listeners ─────────────────────────────────────────────
    httpListeners: union(
      enableHttps
        ? [
            {
              name: 'lstn-app1-https'
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
                    'cert-app1'
                  )
                }
                // No sslProfile — inherits gateway-wide default (AppGwSslPolicy20220101)
                hostNames: !empty(listenerHostName) ? [listenerHostName] : []
              }
            }
            {
              name: 'lstn-app1-http'
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
                hostNames: !empty(listenerHostName) ? [listenerHostName] : []
              }
            }
          ]
        : [
            {
              name: 'lstn-app1-http'
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
                hostNames: !empty(listenerHostName) ? [listenerHostName] : []
              }
            }
          ],
      // ── Second site listeners ───────────────────────────────
      hasSecondSite
        ? [
            {
              name: 'lstn-app2-https'
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
                    'cert-app2'
                  )
                }
                sslProfile: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/sslProfiles',
                    appGatewayName,
                    'sslprof-app2'
                  )
                }
                hostNames: [secondSiteHostName]
              }
            }
            {
              name: 'lstn-app2-http'
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
                hostNames: [secondSiteHostName]
              }
            }
          ]
        : []
    )

    // ── Backend pool ──────────────────────────────────────────
    backendAddressPools: [
      {
        name: 'bp-backend-vms'
        properties: {
          backendAddresses: backendAddresses
        }
      }
    ]

    // ── Backend HTTP settings ─────────────────────────────────
    backendHttpSettingsCollection: union([
      {
        name: 'be-htst-app1'
        properties: {
          port: enableE2ETLS ? 443 : 80
          protocol: enableE2ETLS ? 'Https' : 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          hostName: enableE2ETLS && !empty(backendHostName) ? backendHostName : null
          probe: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/probes',
              appGatewayName,
              'hp-app1'
            )
          }
        }
      }
    ], hasSecondSite ? [
      {
        name: 'be-htst-app2'
        properties: {
          port: enableE2ETLS ? 443 : 80
          protocol: enableE2ETLS ? 'Https' : 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          hostName: enableE2ETLS ? secondSiteHostName : null
          probe: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/probes',
              appGatewayName,
              'hp-app2'
            )
          }
        }
      }
    ] : [])

    // ── Health probes (explicit, never rely on defaults) ──────
    probes: union([
      {
        name: 'hp-app1'
        properties: {
          protocol: enableE2ETLS ? 'Https' : 'Http'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: enableE2ETLS && !empty(backendHostName)
          host: enableE2ETLS && !empty(backendHostName) ? null : '127.0.0.1'
          port: enableE2ETLS ? 443 : 80
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ], hasSecondSite ? [
      {
        name: 'hp-app2'
        properties: {
          protocol: enableE2ETLS ? 'Https' : 'Http'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          port: enableE2ETLS ? 443 : 80
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ] : [])

    // ── Routing rules ─────────────────────────────────────────
    requestRoutingRules: union(
      enableHttps
        ? [
            {
              name: 'rr-app1-https'
              properties: {
                priority: 100
                ruleType: 'Basic'
                httpListener: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/httpListeners',
                    appGatewayName,
                    'lstn-app1-https'
                  )
                }
                backendAddressPool: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/backendAddressPools',
                    appGatewayName,
                    'bp-backend-vms'
                  )
                }
                backendHttpSettings: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
                    appGatewayName,
                    'be-htst-app1'
                  )
                }
                rewriteRuleSet: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/rewriteRuleSets',
                    appGatewayName,
                    'rwset-security-headers'
                  )
                }
              }
            }
            {
              name: 'rr-app1-redirect'
              properties: {
                priority: 200
                ruleType: 'Basic'
                httpListener: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/httpListeners',
                    appGatewayName,
                    'lstn-app1-http'
                  )
                }
                redirectConfiguration: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/redirectConfigurations',
                    appGatewayName,
                    'rdrcfg-app1-http-to-https'
                  )
                }
              }
            }
          ]
        : [
            {
              name: 'rr-app1-http'
              properties: {
                priority: 100
                ruleType: 'Basic'
                httpListener: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/httpListeners',
                    appGatewayName,
                    'lstn-app1-http'
                  )
                }
                backendAddressPool: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/backendAddressPools',
                    appGatewayName,
                    'bp-backend-vms'
                  )
                }
                backendHttpSettings: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
                    appGatewayName,
                    'be-htst-app1'
                  )
                }
              }
            }
          ],
      // ── Second site routing rules ───────────────────────────
      hasSecondSite
        ? [
            {
              name: 'rr-app2-https'
              properties: {
                priority: 110
                ruleType: 'Basic'
                httpListener: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/httpListeners',
                    appGatewayName,
                    'lstn-app2-https'
                  )
                }
                backendAddressPool: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/backendAddressPools',
                    appGatewayName,
                    'bp-backend-vms'
                  )
                }
                backendHttpSettings: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
                    appGatewayName,
                    'be-htst-app2'
                  )
                }
                rewriteRuleSet: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/rewriteRuleSets',
                    appGatewayName,
                    'rwset-security-headers'
                  )
                }
              }
            }
            {
              name: 'rr-app2-redirect'
              properties: {
                priority: 210
                ruleType: 'Basic'
                httpListener: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/httpListeners',
                    appGatewayName,
                    'lstn-app2-http'
                  )
                }
                redirectConfiguration: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/redirectConfigurations',
                    appGatewayName,
                    'rdrcfg-app2-http-to-https'
                  )
                }
              }
            }
          ]
        : []
    )

    // ── Redirect configuration (HTTP → HTTPS) ────────────────
    redirectConfigurations: union(
      enableHttps
        ? [
            {
              name: 'rdrcfg-app1-http-to-https'
              properties: {
                redirectType: 'Permanent'
                targetListener: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/httpListeners',
                    appGatewayName,
                    'lstn-app1-https'
                  )
                }
                includePath: true
                includeQueryString: true
              }
            }
          ]
        : [],
      hasSecondSite
        ? [
            {
              name: 'rdrcfg-app2-http-to-https'
              properties: {
                redirectType: 'Permanent'
                targetListener: {
                  id: resourceId(
                    'Microsoft.Network/applicationGateways/httpListeners',
                    appGatewayName,
                    'lstn-app2-https'
                  )
                }
                includePath: true
                includeQueryString: true
              }
            }
          ]
        : []
    )
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
