// Azure Application Gateway (WAF_v2) Advanced Routing demo.
// Mirrors the 5 advanced rules of agw-routing-simulator.html / docs/agw-advanced-routing-demo-guide.html.
// Deployed by deploy.sh (az deployment group create). Advanced rules are a preview feature, and
// they are only expressible through ARM API versions that include advancedRoutingMaps (2026-01-01+).

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix for resource names.')
param prefix string = 'agwdemo'

@description('Use the weighted 90:10 split on port 8080 (needs Microsoft.Network/AllowApplicationGatewayLoadDistributionPolicy). false = all port-8080 traffic goes to pool-canary.')
param weightedCanary bool = false

@description('Source CIDR that the WAF custom rule blocks (WAF runs before routing).')
param wafBlockCidr string = '198.51.100.0/24'

@description('SSH public key for the backend VM (azureuser).')
param sshPublicKey string

@description('Static private IP of the backend VM inside the backend subnet.')
param backendIp string = '192.168.1.10'

var vnetName = '${prefix}-vnet'
var nsgName = '${prefix}-backend-nsg'
var vmName = '${prefix}-backend'
var nicName = '${prefix}-backend-nic'
var wafName = '${prefix}-waf'
var gwName = '${prefix}-agw'
var gwPipName = '${gwName}-pip'
var mapName = 'advancedRoutingMap1'
// The new version (pool-canary) runs on its own VM, on port 8080 like pool-web. The weighted /canary split
// needs both pools to share one backend HTTP setting, so they must use the same port.
var canaryIp = '192.168.1.11'
var canaryVmName = '${vmName}-canary'
var poolAddressPools = [for p in pools: {
  name: p.name
  properties: {
    backendAddresses: [
      {
        ipAddress: p.name == 'pool-canary' ? canaryIp : backendIp
      }
    ]
  }
}]

var appgwSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'appgw')
var backendSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'backend')
var gwId = resourceId('Microsoft.Network/applicationGateways', gwName)

// name|port  (same as backend/pools.conf; one Node.js process per port on the backend VM)
var pools = [
  { name: 'pool-web', port: 8080 }
  { name: 'pool-partner', port: 8081 }
  { name: 'pool-tenant', port: 8082 }
  { name: 'pool-api-v2', port: 8083 }
  { name: 'pool-canary', port: 8080 }
  { name: 'pool-mobile', port: 8085 }
]

// ---------- Network ----------

// No custom rules: Azure's default rules allow VNet inbound and DenyAllInBound (so the Internet cannot reach the backend).
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [ '192.168.0.0/16' ]
    }
    subnets: [
      {
        name: 'appgw'
        properties: {
          addressPrefix: '192.168.0.0/24'
        }
      }
      {
        name: 'backend'
        properties: {
          addressPrefix: '192.168.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
          natGateway: {
            id: natGateway.id
          }
          // Private subnet: no default outbound IP. Outbound goes through the NAT gateway above.
          defaultOutboundAccess: false
        }
      }
    ]
  }
}

// Backend VMs have no public IP. Outbound traffic (cloud-init packages, etc.) goes through this NAT gateway.
// Inbound from the Internet is blocked by the NSG; only the App Gateway subnet reaches the pool ports.
// NAT gateway (StandardV2: zone redundant by default). A NAT gateway V2 needs a StandardV2 public IP.
resource natPip 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${prefix}-nat-pip'
  location: location
  sku: {
    name: 'StandardV2'
  }
  properties: {
    publicIPAddressVersion: 'IPv4'
    publicIPAllocationMethod: 'Static'
    idleTimeoutInMinutes: 4
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-01-01' = {
  name: '${prefix}-nat'
  location: location
  sku: {
    name: 'StandardV2'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natPip.id
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: backendSubnetId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: backendIp
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

// ---------- Backend VM (6 Node.js pools, see cloud-init.yaml) ----------

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2s'
    }
    osProfile: {
      computerName: vmName
      adminUsername: 'azureuser'
      customData: base64(loadTextContent('cloud-init.yaml'))
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/azureuser/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
        }
      ]
    }
  }
}

// ---------- Canary backend VM (new version; serves pool-canary on 8080, see cloud-init-canary.yaml) ----------

resource canaryNic 'Microsoft.Network/networkInterfaces@2024-05-01' = {
  name: '${canaryVmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: backendSubnetId
          }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: canaryIp
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

resource canaryVm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: canaryVmName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2s'
    }
    osProfile: {
      computerName: canaryVmName
      adminUsername: 'azureuser'
      customData: base64(loadTextContent('cloud-init-canary.yaml'))
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/azureuser/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: canaryNic.id
        }
      ]
    }
  }
}

// ---------- WAF policy (custom rule runs before routing) ----------

resource waf 'Microsoft.Network/ApplicationGatewayWebApplicationFirewallPolicies@2024-05-01' = {
  name: wafName
  location: location
  properties: {
    policySettings: {
      state: 'Enabled'
      mode: 'Prevention'
    }
    customRules: [
      {
        name: 'BlockDemoIp'
        priority: 10
        ruleType: 'MatchRule'
        action: 'Block'
        matchConditions: [
          {
            matchVariables: [
              {
                variableName: 'RemoteAddr'
              }
            ]
            operator: 'IPMatch'
            matchValues: [
              wafBlockCidr
            ]
          }
        ]
      }
      {
        // Demo block by User-Agent (works from any client): curl -A "agw-block-demo" http://<IP>/app/home  -> 403
        name: 'BlockDemoUA'
        priority: 12
        ruleType: 'MatchRule'
        action: 'Block'
        matchConditions: [
          {
            matchVariables: [
              {
                variableName: 'RequestHeaders'
                selector: 'User-Agent'
              }
            ]
            operator: 'Contains'
            transforms: [
              'Lowercase'
            ]
            matchValues: [
              'agw-block-demo'
            ]
          }
        ]
      }
    ]
    managedRules: {
      managedRuleSets: [
        {
          ruleSetType: 'Microsoft_DefaultRuleSet'
          ruleSetVersion: '2.1'
        }
      ]
    }
  }
}

// ---------- Application Gateway (WAF_v2) ----------

resource gwPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: gwPipName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource agw 'Microsoft.Network/applicationGateways@2026-03-01' = {
  name: gwName
  location: location
  properties: {
    sku: {
      name: 'WAF_v2'
      tier: 'WAF_v2'
      capacity: 1
    }
    firewallPolicy: {
      id: waf.id
    }
    gatewayIPConfigurations: [
      {
        name: 'gw-ip'
        properties: {
          subnet: {
            id: appgwSubnetId
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'fe-ip'
        properties: {
          publicIPAddress: {
            id: gwPip.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port-80'
        properties: {
          port: 80
        }
      }
      {
        // Weighted canary split (Basic/path-based rule). Advanced rules (port 80) support one pool per rule only.
        name: 'port-8080'
        properties: {
          port: 8080
        }
      }
    ]
    probes: [
      {
        name: 'healthz'
        properties: {
          protocol: 'Http'
          host: '127.0.0.1'
          path: '/healthz'
          interval: 30
          timeout: 20
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          minServers: 0
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    backendAddressPools: poolAddressPools
    backendHttpSettingsCollection: [
      for p in pools: {
        name: 'hs-${p.name}'
        properties: {
          port: p.port
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 20
          probe: {
            id: '${gwId}/probes/healthz'
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener-http'
        properties: {
          frontendIPConfiguration: {
            id: '${gwId}/frontendIPConfigurations/fe-ip'
          }
          frontendPort: {
            id: '${gwId}/frontendPorts/port-80'
          }
          protocol: 'Http'
        }
      }
      {
        name: 'listener-canary'
        properties: {
          frontendIPConfiguration: {
            id: '${gwId}/frontendIPConfigurations/fe-ip'
          }
          frontendPort: {
            id: '${gwId}/frontendPorts/port-8080'
          }
          protocol: 'Http'
        }
      }
    ]
    // Weighted split on port 8080 (whole port): 90% pool-web (stable), 10% pool-canary (new version).
    loadDistributionPolicies: weightedCanary ? [
      {
        name: 'ld-canary-split'
        properties: {
          loadDistributionAlgorithm: 'RoundRobin'
          loadDistributionTargets: [
            {
              name: 'stable'
              properties: {
                backendAddressPool: {
                  id: '${gwId}/backendAddressPools/pool-web'
                }
                weightPerServer: 90
              }
            }
            {
              name: 'canary'
              properties: {
                backendAddressPool: {
                  id: '${gwId}/backendAddressPools/pool-canary'
                }
                weightPerServer: 10
              }
            }
          ]
        }
      }
    ] : []
    redirectConfigurations: [
      {
        name: 'redirect-campaign'
        properties: {
          redirectType: 'Found'
          targetUrl: 'https://www.contoso.com/campaign'
          includePath: false
          includeQueryString: true
        }
      }
    ]
    advancedRoutingConditionSets: [
      {
        name: 'cs-partner'
        properties: {
          routingConditions: [
            {
              conditionType: 'Header'
              propertyName: 'X-Partner-Id'
              propertyValues: [ 'contoso', 'fabrikam' ]
            }
          ]
        }
      }
      {
        name: 'cs-tenant'
        properties: {
          routingConditions: [
            {
              conditionType: 'Header'
              propertyName: 'X-Tenant-Id'
              propertyValueMatcher: {
                pattern: '^customer-[0-9]+$'
              }
            }
            {
              conditionType: 'Path'
              propertyValueMatcher: {
                pattern: '^/app(/.*)?$'
              }
            }
          ]
        }
      }
      {
        name: 'cs-apiv2'
        properties: {
          routingConditions: [
            {
              conditionType: 'Header'
              propertyName: 'X-Api-Version'
              propertyValues: [ '2', '2.0' ]
            }
            {
              conditionType: 'Path'
              propertyValueMatcher: {
                pattern: '^/api/orders(/.*)?$'
              }
            }
          ]
        }
      }
      {
        name: 'cs-campaign'
        properties: {
          routingConditions: [
            {
              conditionType: 'QueryString'
              propertyName: 'campaign'
              propertyValues: [ 'spring', 'summer' ]
            }
          ]
        }
      }
      {
        name: 'cs-mobile'
        properties: {
          routingConditions: [
            {
              conditionType: 'Header'
              propertyName: 'User-Agent'
              propertyValueMatcher: {
                pattern: '(iPhone|Android)'
              }
            }
          ]
        }
      }
    ]
    advancedRoutingMaps: [
      {
        name: mapName
        properties: {
          advancedRoutingRules: [
            {
              name: 'partner'
              properties: {
                priority: 10
                advancedRoutingConditionSet: {
                  id: '${gwId}/advancedRoutingConditionSets/cs-partner'
                }
                backendAddressPool: {
                  id: '${gwId}/backendAddressPools/pool-partner'
                }
                backendHttpSettings: {
                  id: '${gwId}/backendHttpSettingsCollection/hs-pool-partner'
                }
              }
            }
            {
              name: 'tenant'
              properties: {
                priority: 20
                advancedRoutingConditionSet: {
                  id: '${gwId}/advancedRoutingConditionSets/cs-tenant'
                }
                backendAddressPool: {
                  id: '${gwId}/backendAddressPools/pool-tenant'
                }
                backendHttpSettings: {
                  id: '${gwId}/backendHttpSettingsCollection/hs-pool-tenant'
                }
              }
            }
            {
              name: 'api-v2'
              properties: {
                priority: 30
                advancedRoutingConditionSet: {
                  id: '${gwId}/advancedRoutingConditionSets/cs-apiv2'
                }
                backendAddressPool: {
                  id: '${gwId}/backendAddressPools/pool-api-v2'
                }
                backendHttpSettings: {
                  id: '${gwId}/backendHttpSettingsCollection/hs-pool-api-v2'
                }
              }
            }
            {
              name: 'campaign'
              properties: {
                priority: 40
                advancedRoutingConditionSet: {
                  id: '${gwId}/advancedRoutingConditionSets/cs-campaign'
                }
                redirectConfiguration: {
                  id: '${gwId}/redirectConfigurations/redirect-campaign'
                }
              }
            }
            {
              name: 'mobile'
              properties: {
                priority: 60
                advancedRoutingConditionSet: {
                  id: '${gwId}/advancedRoutingConditionSets/cs-mobile'
                }
                backendAddressPool: {
                  id: '${gwId}/backendAddressPools/pool-mobile'
                }
                backendHttpSettings: {
                  id: '${gwId}/backendHttpSettingsCollection/hs-pool-mobile'
                }
              }
            }
          ]
          defaultBackendAddressPool: {
            id: '${gwId}/backendAddressPools/pool-web'
          }
          defaultBackendHttpSettings: {
            id: '${gwId}/backendHttpSettingsCollection/hs-pool-web'
          }
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'rule1'
        properties: {
          ruleType: 'AdvancedRouting'
          priority: 100
          httpListener: {
            id: '${gwId}/httpListeners/listener-http'
          }
          advancedRoutingMap: {
            id: '${gwId}/advancedRoutingMaps/${mapName}'
          }
        }
      }
      {
        // Basic rule on port 8080: every request on this port is split 90:10 (pool-web / pool-canary).
        name: 'rule-canary'
        properties: union({
          ruleType: 'Basic'
          priority: 200
          httpListener: {
            id: '${gwId}/httpListeners/listener-canary'
          }
          backendHttpSettings: {
            id: '${gwId}/backendHttpSettingsCollection/hs-pool-web'
          }
        }, weightedCanary ? {
          // 90% pool-web / 10% pool-canary (whole port 8080)
          loadDistributionPolicy: {
            id: '${gwId}/loadDistributionPolicies/ld-canary-split'
          }
        } : {
          // all port-8080 traffic goes to the new version until the weighted split is enabled
          backendAddressPool: {
            id: '${gwId}/backendAddressPools/pool-canary'
          }
        })
      }
    ]
  }
  dependsOn: [
    vnet
    waf
    gwPip
  ]
}

output frontendIp string = gwPip.properties.ipAddress
output backendPrivateIp string = backendIp
