targetScope = 'subscription'

@description('Environment name (e.g., dev, test, prod). Used in resource naming and tags.')
param environmentName string

@description('Azure region for deployment')
param location string

@description('Project short name for naming and tags')
param projectName string = 'app'

// Compute salt deterministically from subscription + project + env (as a parameter so other parameter defaults can reference it)
param salt string = substring(uniqueString(subscription().id, projectName, environmentName), 0, 6)

@description('Virtual Network Name')
param virtualNetworkName string = 'vnet-${salt}'

@description('Virtual Network Address Prefix')
param vnetAddressPrefix string = '192.168.0.0/16'

@description('Container App Subnet Address Prefix')
param containerAppSubnetPrefix string = cidrSubnet(vnetAddressPrefix, 23, 0)

@description('Resource Subnet Address Prefix')
param resourceSubnetPrefix string = cidrSubnet(vnetAddressPrefix, 24, 2)

@description('Private Endpoint Subnet Address Prefix')
param privateEndpointSubnetPrefix string = cidrSubnet(vnetAddressPrefix, 24, 3)

@description('Bastion Subnet Address Prefix')
param bastionAddressPrefix string = cidrSubnet(vnetAddressPrefix, 24, 4)

@description('Set of tags to apply to all resources.')
param tags object = {
  project: projectName
  'azd-env-name': environmentName
}

@description('Resource group name for this environment')
param resourceGroupName string = 'rg-${projectName}-${salt}-${environmentName}'

resource rg 'Microsoft.Resources/resourceGroups@2020-06-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// Always use VNet-based networking
module network '../networks.bicep' = {
  scope: rg
  name: 'network'
  params: {
    location: location
    tags: tags
    vnetName: virtualNetworkName
    vnetAddressPrefix: vnetAddressPrefix
    containerAppSubnetPrefix: containerAppSubnetPrefix
    resourceSubnetPrefix: resourceSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    bastionAddressPrefix: bastionAddressPrefix
    usePrivateLinks: true
    caenvDelegation: true
  }
}

output resourceGroupName string = resourceGroupName
output salt string = salt
output vnetId string = network.outputs.vnetId
output containerAppSubnetId string = network.outputs.containerAppSubnetId
output privateEndpointSubnetId string = network.outputs.privateEndpointSubnetId
output resourceSubnetId string = network.outputs.resourceSubnetId
output bastionSubnetId string = network.outputs.bastionSubnetId
