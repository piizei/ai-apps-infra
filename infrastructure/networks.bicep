// networks.bicep - New module for virtual network and subnet configurations

// Parameters
param location string
param tags object
param vnetName string
param vnetAddressPrefix string
param containerAppSubnetPrefix string
param resourceSubnetPrefix string
param privateEndpointSubnetPrefix string
param bastionAddressPrefix string
// Removing VPN Gateway subnet parameter
// param vpnGatewaySubnetPrefix string
param usePrivateLinks bool
param caenvDelegation bool

// Local names for subnets
var containerAppSubnetName = 'containerapp-subnet'
var privateEndpointSubnetName = 'pe-subnet'
var resourceSubnetName = 'resource-subnet'
var bastionSubnetName = 'AzureBastionSubnet'
var containerAppSubnetDelegations = caenvDelegation ? [
  {
    name: 'containerappDelegation'
    properties: {
      serviceName: 'Microsoft.App/environments'
    }
  }
] : []

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: privateEndpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
          delegations: []
        }
      }
      {
        name: resourceSubnetName
        properties: {
          addressPrefix: resourceSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
          delegations: []
        }
      }
      {
        name: containerAppSubnetName
        properties: {
          addressPrefix: containerAppSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
          delegations: containerAppSubnetDelegations
          serviceEndpoints: (!usePrivateLinks) ? [
            {
              service: 'Microsoft.Storage'
              locations: ['*']
            }
          ] : []
        }
      }
      {
        name: bastionSubnetName
        properties: {
          addressPrefix: bastionAddressPrefix
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
  // Expose existing sub-resources for easier reference
  resource containerappSubnet 'subnets' existing = {
    name: containerAppSubnetName
  }
  resource privateEndpointSubnet 'subnets' existing = {
    name: privateEndpointSubnetName
  }
  resource resourceSubnet 'subnets' existing = {
    name: resourceSubnetName
  }
  resource bastionSubnet 'subnets' existing = {
    name: bastionSubnetName
  }
}

// Outputs
output vnetId string = vnet.id
output containerAppSubnetId string = vnet::containerappSubnet.id
output privateEndpointSubnetId string = vnet::privateEndpointSubnet.id
output resourceSubnetId string = vnet::resourceSubnet.id
output bastionSubnetId string = vnet::bastionSubnet.id
// Remove gateway subnet output
// output gatewaySubnetId string = usePrivateLinks ? '${vnet.id}/subnets/GatewaySubnet' : ''
