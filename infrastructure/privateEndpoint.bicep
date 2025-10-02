param location string = resourceGroup().location
param subnetId string
param name string
param dnsZoneName string
param createPrivateDnsZone bool
param privateLinkServiceId string
param groupIds array
param vnetId string
param tags object

var privateEndpointName = '${name}-pe'
var privateDnsGroupName = '${name}-pdg'

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-05-01' = {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: privateEndpointName
        properties: {
          privateLinkServiceId: privateLinkServiceId
          groupIds: groupIds
        }
      }
    ]
  }
  dependsOn: [
    privateDnsZone
    privateDnsZone::privateDnsZoneLink
  ]

  resource privateDnsGroup 'privateDnsZoneGroups' = {
    name: privateDnsGroupName
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'config1'
          properties: {
            privateDnsZoneId: privateDnsZone.id
          }
        }
      ]
    }
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if(createPrivateDnsZone) {
  name: dnsZoneName
  tags: tags
  location: 'global'
  properties: {}
  resource privateDnsZoneLink 'virtualNetworkLinks' = if (createPrivateDnsZone) {
    name: '${dnsZoneName}-link'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnetId
      }
    }
  }
}
