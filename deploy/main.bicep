// Azure Application Gateway (WAF_v2) Advanced Routing demo.
// Mirrors the 5 advanced rules of agw-routing-simulator.html / docs/agw-advanced-routing-demo-guide.html.
// Deployed by deploy.sh (az deployment group create). Advanced rules are a preview feature, and
// they are only expressible through ARM API versions that include advancedRoutingMaps (2026-01-01+).

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Prefix for resource names.')
param prefix string = 'agwdemo'

@description('Source CIDR that the WAF custom rule blocks (WAF runs before routing).')
param wafBlockCidr string = '198.51.100.0/24'

@description('SSH public key for the backend VM (azureuser).')
param sshPublicKey string

@description('Static private IP of the backend VM inside the backend subnet.')
param vm1Ip string = '192.168.1.10'

var vnetName = '${prefix}-vnet'
var nsgName = '${prefix}-backend-nsg'
var vmName = '${prefix}-backend'
var nicName = '${prefix}-backend-nic'
var wafName = '${prefix}-waf'
var gwName = '${prefix}-agw'
var gwPipName = '${gwName}-pip'
var mapName = 'advancedRoutingMap1'
var canaryMapName = 'canaryMap'
var priorityMapName = 'priorityMap'
var flagMapName = 'flagMap'
// VM 2 runs the new version (srv-canary, port 8080 like srv-web) and the dedicated processes for
// priority-based selection (srv-primary, 8088) and the feature flag (srv-flag-on, 8089).
var vm2Ip = '192.168.1.11'
var canaryVmName = '${vmName}-canary'
var poolAddressPools = [for p in pools: {
  name: p.name
  properties: {
    backendAddresses: [
      {
        ipAddress: p.vm == 2 ? vm2Ip : vm1Ip
      }
    ]
  }
}]

// One backend HTTP setting per process in `pools`.
var poolHttpSettings = [
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
// #82 server selection demo: 8086 = srv-slow (VM 1) / srv-fast (VM 2), 8087 = srv-rr-a (VM 1) / srv-rr-b (VM 2).
// Affinity stays off: Least Connections is not applied while cookie-based affinity is on.
var serverSelectHttpSettings = [
  for port in [8086, 8087]: {
    name: 'hs-${port}'
    properties: {
      port: port
      protocol: 'Http'
      cookieBasedAffinity: 'Disabled'
      requestTimeout: 20
      probe: {
        id: '${gwId}/probes/healthz'
      }
    }
  }
]

var appgwSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'appgw')
var backendSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'backend')
var gwId = resourceId('Microsoft.Network/applicationGateways', gwName)

// name|port|vm  (name = the backend pool's name in Azure; the server in it is the srv-... process with the same port in
// backend/pools.conf and backend/pools-canary.conf, one Node.js process per entry).
// Each entry becomes a backend pool with the VM's address and backend settings hs-<name> on its port.
var pools = [
  { name: 'pool-web', port: 8080, vm: 1 }
  { name: 'pool-partner', port: 8081, vm: 1 }
  { name: 'pool-tenant', port: 8082, vm: 1 }
  { name: 'pool-api-v2', port: 8083, vm: 1 }
  { name: 'pool-canary', port: 8080, vm: 2 }
  { name: 'pool-mobile', port: 8085, vm: 1 }
  // #131 dedicated processes: priority-based selection (8090) and the feature flag (8100) no longer reuse port 8080.
  { name: 'pool-primary', port: 8088, vm: 2 }
  { name: 'pool-standby', port: 8088, vm: 1 }
  { name: 'pool-flag-on', port: 8089, vm: 2 }
  { name: 'pool-flag-off', port: 8089, vm: 1 }
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
          privateIPAddress: vm1Ip
        }
      }
    ]
  }
  dependsOn: [
    vnet
  ]
}

// ---------- Backend VM 1 (9 Node.js servers, see backend/pools.conf and cloud-init.yaml) ----------

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

// ---------- VM 2 (5 Node.js servers: srv-canary 8080, srv-fast 8086, srv-rr-b 8087, srv-primary 8088, srv-flag-on 8089; see cloud-init-canary.yaml) ----------

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
          privateIPAddress: vm2Ip
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
        // Port 8080: canary rule (advanced rule, weighted 90:10 pool split).
        name: 'port-8080'
        properties: {
          port: 8080
        }
      }
      {
        // Port 8090: priority-based selection (pool-primary on VM 2 (srv-primary) first, pool-standby on VM 1 (srv-standby) when pool-primary is unhealthy).
        name: 'port-8090'
        properties: {
          port: 8090
        }
      }
      {
        // Port 8100: feature flag (#74). X-Feature: new -> pool-flag-on (srv-flag-on); otherwise -> pool-flag-off (srv-flag-off).
        name: 'port-8100'
        properties: {
          port: 8100
        }
      }
      {
        // Port 8110: Round Robin with two fast servers (#82).
        name: 'port-8110'
        properties: {
          port: 8110
        }
      }
      {
        // Port 8120: Round Robin with one slow server (srv-slow waits 3 s) (#82).
        name: 'port-8120'
        properties: {
          port: 8120
        }
      }
      {
        // Port 8130: Least Connections over the same slow and fast servers as 8120 (#82).
        name: 'port-8130'
        properties: {
          port: 8130
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
    backendAddressPools: concat(poolAddressPools, [
      {
        // #82 server selection demo. Every pool here has two servers; the port comes from hs-8086 / hs-8087.
        // 8110: srv-rr-a (VM 1, 8087) and srv-rr-b (VM 2, 8087), both fast. Round Robin (the default).
        name: 'pool-rr'
        properties: {
          backendAddresses: [
            {
              ipAddress: vm1Ip
            }
            {
              ipAddress: vm2Ip
            }
          ]
        }
      }
      {
        // 8120: srv-slow (VM 1, 8086, 3 s) and srv-fast (VM 2, 8086). Round Robin (the default).
        name: 'pool-rr-slow'
        properties: {
          backendAddresses: [
            {
              ipAddress: vm1Ip
            }
            {
              ipAddress: vm2Ip
            }
          ]
        }
      }
      {
        // 8130: the same two servers as pool-rr-slow (srv-slow and srv-fast), with Least Connections.
        name: 'pool-lc'
        properties: {
          backendAddresses: [
            {
              ipAddress: vm1Ip
            }
            {
              ipAddress: vm2Ip
            }
          ]
          // Preview property, missing from the public API spec and the Bicep types (no warning here only because
          // this array is built with concat()).
          // Found by setting Least Connections on a pool in the portal and diffing the gateway (see
          // docs/superpowers/specs/2026-11-25-server-selection-demo-design.md).
          serverSelectionAlgorithm: 'LeastConnections'
        }
      }
    ])
    backendHttpSettingsCollection: concat(poolHttpSettings, serverSelectHttpSettings)
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
      {
        name: 'listener-priority'
        properties: {
          frontendIPConfiguration: {
            id: '${gwId}/frontendIPConfigurations/fe-ip'
          }
          frontendPort: {
            id: '${gwId}/frontendPorts/port-8090'
          }
          protocol: 'Http'
        }
      }
      {
        name: 'listener-flag'
        properties: {
          frontendIPConfiguration: {
            id: '${gwId}/frontendIPConfigurations/fe-ip'
          }
          frontendPort: {
            id: '${gwId}/frontendPorts/port-8100'
          }
          protocol: 'Http'
        }
      }
      {
        name: 'listener-rr'
        properties: {
          frontendIPConfiguration: {
            id: '${gwId}/frontendIPConfigurations/fe-ip'
          }
          frontendPort: {
            id: '${gwId}/frontendPorts/port-8110'
          }
          protocol: 'Http'
        }
      }
      {
        name: 'listener-rr-slow'
        properties: {
          frontendIPConfiguration: {
            id: '${gwId}/frontendIPConfigurations/fe-ip'
          }
          frontendPort: {
            id: '${gwId}/frontendPorts/port-8120'
          }
          protocol: 'Http'
        }
      }
      {
        name: 'listener-lc'
        properties: {
          frontendIPConfiguration: {
            id: '${gwId}/frontendIPConfigurations/fe-ip'
          }
          frontendPort: {
            id: '${gwId}/frontendPorts/port-8130'
          }
          protocol: 'Http'
        }
      }
    ]
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
      {
        // Feature flag (#74) on port 8100: the header X-Feature: new turns the flag on (pool-flag-on).
        name: 'cs-flag-on'
        properties: {
          routingConditions: [
            {
              conditionType: 'Header'
              propertyName: 'X-Feature'
              propertyValues: [
                'new'
              ]
            }
          ]
        }
      }
      {
        // Port 8080 only: matches every request (all paths), so the canary split applies to the whole port.
        name: 'cs-canary-split'
        properties: {
          routingConditions: [
            {
              conditionType: 'Path'
              propertyValueMatcher: {
                pattern: '^/'
              }
            }
          ]
        }
      }
      {
        // Port 8090 only: matches every request (all paths).
        name: 'cs-priority-all'
        properties: {
          routingConditions: [
            {
              conditionType: 'Path'
              propertyValueMatcher: {
                pattern: '^/'
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
      {
        // Port 8080 (whole port): the rule splits 90% pool-web / 10% pool-canary; the default is pool-canary.
        name: canaryMapName
        properties: {
          advancedRoutingRules: [
            {
              name: 'canary-split'
              properties: {
                priority: 10
                advancedRoutingConditionSet: {
                  id: '${gwId}/advancedRoutingConditionSets/cs-canary-split'
                }
                backendAddressPoolsAndSettings: [
                  {
                    backendAddressPool: { id: '${gwId}/backendAddressPools/pool-web' }
                    backendHttpSettings: { id: '${gwId}/backendHttpSettingsCollection/hs-pool-web' }
                    weight: 90
                  }
                  {
                    backendAddressPool: { id: '${gwId}/backendAddressPools/pool-canary' }
                    backendHttpSettings: { id: '${gwId}/backendHttpSettingsCollection/hs-pool-web' }
                    weight: 10
                  }
                ]
                poolSelectionAlgorithm: 'WeightedDistribution'
              }
            }
          ]
          defaultBackendAddressPool: {
            id: '${gwId}/backendAddressPools/pool-canary'
          }
          defaultBackendHttpSettings: {
            id: '${gwId}/backendHttpSettingsCollection/hs-pool-web'
          }
        }
      }
      {
        // Port 8090: Primary pool (priority 1, VM 2) is used while it has >= 60% healthy servers;
        // otherwise the Standby pool (priority 2, VM 1) takes over. Each pool here has one server.
        name: priorityMapName
        properties: {
          advancedRoutingRules: [
            {
              name: 'priority-split'
              properties: {
                priority: 10
                advancedRoutingConditionSet: {
                  id: '${gwId}/advancedRoutingConditionSets/cs-priority-all'
                }
                backendAddressPoolsAndSettings: [
                  {
                    backendAddressPool: { id: '${gwId}/backendAddressPools/pool-primary' }
                    backendHttpSettings: { id: '${gwId}/backendHttpSettingsCollection/hs-pool-primary' }
                    priority: 1
                  }
                  {
                    backendAddressPool: { id: '${gwId}/backendAddressPools/pool-standby' }
                    backendHttpSettings: { id: '${gwId}/backendHttpSettingsCollection/hs-pool-standby' }
                    priority: 2
                  }
                ]
                poolSelectionAlgorithm: 'PriorityAware'
                minimumHealthyPercent: 60
              }
            }
          ]
          defaultBackendAddressPool: {
            id: '${gwId}/backendAddressPools/pool-standby'
          }
          defaultBackendHttpSettings: {
            id: '${gwId}/backendHttpSettingsCollection/hs-pool-standby'
          }
        }
      }
      {
        // Feature flag (#74) on port 8100: flag on -> pool-flag-on; the default (flag off) -> pool-flag-off.
        name: flagMapName
        properties: {
          advancedRoutingRules: [
            {
              name: 'flag-on'
              properties: {
                priority: 10
                advancedRoutingConditionSet: {
                  id: '${gwId}/advancedRoutingConditionSets/cs-flag-on'
                }
                backendAddressPool: {
                  id: '${gwId}/backendAddressPools/pool-flag-on'
                }
                backendHttpSettings: {
                  id: '${gwId}/backendHttpSettingsCollection/hs-pool-flag-on'
                }
              }
            }
          ]
          defaultBackendAddressPool: {
            id: '${gwId}/backendAddressPools/pool-flag-off'
          }
          defaultBackendHttpSettings: {
            id: '${gwId}/backendHttpSettingsCollection/hs-pool-flag-off'
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
        // Advanced rule on port 8080; all requests on this port use canaryMap (canary-split rule: 90:10).
        name: 'rule-canary'
        properties: {
          ruleType: 'AdvancedRouting'
          priority: 200
          httpListener: {
            id: '${gwId}/httpListeners/listener-canary'
          }
          advancedRoutingMap: {
            id: '${gwId}/advancedRoutingMaps/${canaryMapName}'
          }
        }
      }
      {
        // Port 8090: priority-based selection (see priorityMap).
        name: 'rule-priority'
        properties: {
          ruleType: 'AdvancedRouting'
          priority: 300
          httpListener: {
            id: '${gwId}/httpListeners/listener-priority'
          }
          advancedRoutingMap: {
            id: '${gwId}/advancedRoutingMaps/${priorityMapName}'
          }
        }
      }
      {
        // Port 8100: feature flag (see flagMap).
        name: 'rule-flag'
        properties: {
          ruleType: 'AdvancedRouting'
          priority: 400
          httpListener: {
            id: '${gwId}/httpListeners/listener-flag'
          }
          advancedRoutingMap: {
            id: '${gwId}/advancedRoutingMaps/${flagMapName}'
          }
        }
      }
      {
        // Port 8110: Round Robin over two fast servers (#82). Basic rule: no conditions are needed.
        name: 'rule-rr'
        properties: {
          ruleType: 'Basic'
          priority: 500
          httpListener: {
            id: '${gwId}/httpListeners/listener-rr'
          }
          backendAddressPool: {
            id: '${gwId}/backendAddressPools/pool-rr'
          }
          backendHttpSettings: {
            id: '${gwId}/backendHttpSettingsCollection/hs-8087'
          }
        }
      }
      {
        // Port 8120: Round Robin with a slow server; about half of the requests wait 3 s.
        name: 'rule-rr-slow'
        properties: {
          ruleType: 'Basic'
          priority: 600
          httpListener: {
            id: '${gwId}/httpListeners/listener-rr-slow'
          }
          backendAddressPool: {
            id: '${gwId}/backendAddressPools/pool-rr-slow'
          }
          backendHttpSettings: {
            id: '${gwId}/backendHttpSettingsCollection/hs-8086'
          }
        }
      }
      {
        // Port 8130: Least Connections (set on pool-lc); new requests avoid the slow server.
        name: 'rule-lc'
        properties: {
          ruleType: 'Basic'
          priority: 700
          httpListener: {
            id: '${gwId}/httpListeners/listener-lc'
          }
          backendAddressPool: {
            id: '${gwId}/backendAddressPools/pool-lc'
          }
          backendHttpSettings: {
            id: '${gwId}/backendHttpSettingsCollection/hs-8086'
          }
        }
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
output vm1PrivateIp string = vm1Ip
