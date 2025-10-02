@description('The location for the resource(s) to be deployed.')
param location string = resourceGroup().location

// Added parameter for resource tags
param tags object = {}

param postgreName string

param principalId string

param principalType string

@description('Display name for Entra principal; use the application (client) ID for service principals.')
param principalName string

@description('Tenant ID for the Entra principal.')
param principalTenantId string = tenant().tenantId

@secure()
@description('Postgre adminuser password')
param pgAdminPassword string = ''

@description('Enable private endpoint for PostgreSQL flexible server')
param usePrivateLinks bool = false

@description('Subnet resource id for PostgreSQL private endpoint')
param privateEndpointSubnetId string = ''

@description('Virtual network id for PostgreSQL private endpoint')
param vnetId string = ''

@description('Enable private DNS zone creation for PostgreSQL private endpoint')
param createPrivateDnsZone bool = false

resource pgsql2 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' = {
  name: postgreName
  location: location
  properties: {
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth: 'Enabled'
    }
    availabilityZone: '1'
    backup: {
      backupRetentionDays: 7
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    storage: {
      storageSizeGB: 32
    }
    version: '16'
    administratorLogin: 'postgres'
    administratorLoginPassword: pgAdminPassword
  }
  sku: {
    name: 'Standard_D2ds_v5'
    tier: 'GeneralPurpose'
  }
  // Inline firewall rule to allow all Azure IPs
  resource firewallRuleAllowAll 'firewallRules@2024-08-01' = {
    name: 'AllowAllAzureIps'
    properties: {
      startIpAddress: '0.0.0.0'
      endIpAddress: '0.0.0.0'
    }
  }
  resource pgsql2_admin 'administrators@2024-08-01' = {
    // Use the principal's objectId as the resource name (GUID)
    name: principalId
    properties: {
      principalName: principalName
      principalType: principalType
      tenantId: principalTenantId
    }
  }

}


// Module call for Private Endpoint for PostgreSQL Flexible Server
module postgrePrivateEndpoint 'privateEndpoint.bicep' = if (usePrivateLinks) {
  name: '${postgreName}-pe'
  params: {
    dnsZoneName: 'privatelink.postgres.database.azure.com'
    tags: tags
    groupIds: [
      'postgresqlServer'
    ]
    location: location
    createPrivateDnsZone: createPrivateDnsZone
    name: '${postgreName}-pe'
    subnetId: privateEndpointSubnetId
    vnetId: vnetId
    privateLinkServiceId: pgsql2.id
  }
}

output fullyQualifiedDomainName string = pgsql2.properties.fullyQualifiedDomainName

// Add output for the resource id of PostgreSQL flexible server
output serverId string = pgsql2.id
