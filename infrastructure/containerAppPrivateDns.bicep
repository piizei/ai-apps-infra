param defaultDomain string
param vnetId string
param staticIp string
param tags object

resource caenvPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: defaultDomain
  location: 'global'
  tags: tags
  properties: {}

  resource privateDnsZoneLink 'virtualNetworkLinks' = {
  name: 'ca-link'
  location: 'global'
  tags: tags
  properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnetId
      }
    }
  }

  resource caEnvStaticIpEntry 'A' = {
    name: '*'
    properties: {
      ttl: 300
      aRecords: [
        {
          ipv4Address: staticIp
        }
      ]
    }
  }

  resource caEnvStaticIpEntryRoot 'A' = {
    name: '@'
    properties: {
      ttl: 300
      aRecords: [
        {
          ipv4Address: staticIp
        }
      ]
    }
  }
}
