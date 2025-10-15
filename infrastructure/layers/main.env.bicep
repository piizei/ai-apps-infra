targetScope = 'resourceGroup'

@description('Environment name (e.g., dev, test, prod). Used in naming and tags.')
param environmentName string

@description('Project short name for naming and tags')
param projectName string = 'app'

@description('Tags to apply across resources')
param tags object = {
  project: projectName
  'azd-env-name': environmentName
}

// Bicep: parameter defaults can reference only other parameters; define salt as a param with a computed default
param salt string = substring(uniqueString(subscription().id, projectName, environmentName), 0, 6)

@description('Azure region for resources')
param location string = resourceGroup().location

@description('Networking from base layer (names)')
param vnetName string = 'vnet-${salt}'
param containerAppSubnetName string = 'containerapp-subnet'
param privateEndpointSubnetName string = 'pe-subnet'

resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' existing = {
  name: vnetName
}
resource containerAppSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' existing = {
  name: containerAppSubnetName
  parent: vnet
}
resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' existing = {
  name: privateEndpointSubnetName
  parent: vnet
}

@description('Workload profile toggle for Container Apps')
param useWorkloadProfiles bool = true

@description('Public ingress for container apps')
param publicContainerApps bool = true

@description('Optional instance suffix to allow multiple ACA environments per shared PaaS')
param appInstance string = ''

@description('Azure Container Registry name')
param acrName string = empty(appInstance) ? 'acr${salt}' : 'acr${salt}${appInstance}'

@description('Queue base name')
param queueName string = empty(appInstance) ? 'tasks${salt}' : 'tasks${salt}${appInstance}'

@description('Deploy development queue in addition to main queue')
param deployDevelopmentQueue bool = false

// Monitoring
param logAnalyticsWorkspaceName string = empty(appInstance) ? 'law-${salt}' : 'law-${salt}-${appInstance}'
param applicationInsightsName string = empty(appInstance) ? 'appi-${salt}' : 'appi-${salt}-${appInstance}'

// Storage
param storageAccountName string = empty(appInstance) ? 'st${salt}' : 'st${salt}${appInstance}'
param blobContainerName string = empty(appInstance) ? 'blob${salt}' : 'blob${salt}${appInstance}'

// Container Apps environment
param containerAppEnvName string = empty(appInstance) ? 'env-${salt}' : 'env-${salt}-${appInstance}'

@description('Managed identity name used by container apps within this environment.')
param applicationIdentityName string = empty(appInstance) ? 'ca-identity-${salt}' : 'ca-identity-${salt}-${appInstance}'

module containerAppIdentity '../identity.bicep' = {
  name: 'containerAppIdentity'
  params: {
    location: location
    tags: tags
    applicationIdentityName: applicationIdentityName
  }
}

// ACR
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2021-09-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: 'Premium'
  }
  properties: {
    adminUserEnabled: true
    publicNetworkAccess: 'Enabled'
    dataEndpointEnabled: false
    networkRuleBypassOptions: 'AzureServices'
    policies: {
      retentionPolicy: {
        status: 'enabled'
        days: 7
      }
      quarantinePolicy: {
        status: 'disabled'
      }
      trustPolicy: {
        status: 'disabled'
        type: 'Notary'
      }
    }
  }
}

// Monitoring resources
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-06-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    Flow_Type: 'Bluefield'
  }
}

// Storage account with network rules (deny by default)
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    encryption: {
      keySource: 'Microsoft.Storage'
      services: {
        blob: { enabled: true, keyType: 'Account' }
        file: { enabled: true, keyType: 'Account' }
        queue: { enabled: true, keyType: 'Service' }
        table: { enabled: true, keyType: 'Service' }
      }
    }
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: []
    }
  }
  resource blobService 'blobServices' existing = {
    name: 'default'
    resource container 'containers' = {
      name: blobContainerName
    }
    resource tokenStore 'containers' = {
      name: 'tokenstore'
    }
  }
  resource queueServices 'queueServices' existing = { name: 'default' }
}

// Queues and optional dev queue
var devQueueName = '${queueName}dev'
var queueNames = deployDevelopmentQueue ? [queueName, devQueueName] : [queueName]
resource queues 'Microsoft.Storage/storageAccounts/queueServices/queues@2022-09-01' = [for q in queueNames: {
  parent: storage::queueServices
  name: q
}]

var acrPullRole = resourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var storageBlobDataOwnerRole = resourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var storageQueueContributorRole = resourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')

resource identityAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, applicationIdentityName, acrPullRole)
  scope: containerRegistry
  properties: {
    roleDefinitionId: acrPullRole
    principalId: containerAppIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

resource identityStorageBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, applicationIdentityName, storageBlobDataOwnerRole)
  scope: storage
  properties: {
    roleDefinitionId: storageBlobDataOwnerRole
    principalId: containerAppIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

resource identityStorageQueueContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, applicationIdentityName, storageQueueContributorRole)
  scope: storage
  properties: {
    roleDefinitionId: storageQueueContributorRole
    principalId: containerAppIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// Event Grid subscriptions for blob events to queues
resource blobEventSubscriptions 'Microsoft.EventGrid/eventSubscriptions@2023-06-01-preview' = [for (q, i) in queueNames: {
  name: 'blobEventsSubscription-${q}'
  scope: storage
  properties: {
    destination: {
      endpointType: 'StorageQueue'
      properties: {
        resourceId: storage.id
        queueName: q
        queueMessageTimeToLiveInSeconds: 3600
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated', 'Microsoft.Storage.BlobDeleted', 'Microsoft.Storage.BlobPropertiesUpdated', 'Microsoft.Storage.BlobRenamed'
      ]
    }
    eventDeliverySchema: 'CloudEventSchemaV1_0'
  }
}]

// Storage Private Endpoints (blob/queue/file)
module blobPrivateEndpoint '../privateEndpoint.bicep' = {
  name: 'ple-${salt}-st-blob'
  params: {
    dnsZoneName: 'privatelink.blob.${az.environment().suffixes.storage}'
    groupIds: ['blob']
    tags: tags
    location: location
    createPrivateDnsZone: true
    name: 'ple-${salt}-st-blob'
  subnetId: privateEndpointSubnet.id
  vnetId: vnet.id
    privateLinkServiceId: storage.id
  }
}
module queuePrivateEndpoint '../privateEndpoint.bicep' = {
  name: 'ple-${salt}-st-queue'
  params: {
    dnsZoneName: 'privatelink.queue.${az.environment().suffixes.storage}'
    groupIds: ['queue']
    tags: tags
    location: location
    createPrivateDnsZone: true
    name: 'ple-${salt}-st-queue'
  subnetId: privateEndpointSubnet.id
  vnetId: vnet.id
    privateLinkServiceId: storage.id
  }
}
module filePrivateEndpoint '../privateEndpoint.bicep' = {
  name: 'ple-${salt}-st-file'
  params: {
    dnsZoneName: 'privatelink.file.${az.environment().suffixes.storage}'
    groupIds: ['file']
    tags: tags
    location: location
    createPrivateDnsZone: true
    name: 'ple-${salt}-st-file'
  subnetId: privateEndpointSubnet.id
  vnetId: vnet.id
    privateLinkServiceId: storage.id
  }
}

// Container Apps managed environment
param workloadProfiles array = useWorkloadProfiles
  ? [
      {
        maximumCount: 3
        minimumCount: 0
        name: 'Dedicated'
        workloadProfileType: 'D4'
      }
    ]
  : []

resource containerAppEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppEnvName
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      internal: !publicContainerApps
      infrastructureSubnetId: containerAppSubnet.id
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
    workloadProfiles: workloadProfiles
  }
}

// Private DNS for managed environment default domain when internal
module caPrivateDns '../containerAppPrivateDns.bicep' = if (!publicContainerApps) {
  name: 'containerAppPrivateDns-${salt}-deployment'
  params: {
    tags: tags
    defaultDomain: containerAppEnv.properties.defaultDomain
    staticIp: containerAppEnv.properties.staticIp
    vnetId: vnet.id
  }
}

// SAS for tokenstore container
@description('Token Store SAS token expiry date in ISO format')
param tokenStoreSasExpiry string = dateTimeAdd(utcNow(), 'P1Y')

var tokenStoreContainerSas = storage.listServiceSAS('2021-09-01', {
  canonicalizedResource: '/blob/${storage.name}/tokenstore'
  signedResource: 'c'
  signedProtocol: 'https'
  signedPermission: 'rwadl'
  signedServices: 'b'
  signedExpiry: tokenStoreSasExpiry
  signedVersion: '2022-11-02'
}).serviceSasToken

var tokenStoreContainerSasUrl = '${storage.properties.primaryEndpoints.blob}tokenstore?${tokenStoreContainerSas}'

output acrLoginServer string = containerRegistry.properties.loginServer
output acrName string = acrName
output acrId string = containerRegistry.id
output applicationInsightsConnectionString string = applicationInsights.properties.ConnectionString
output storageAccountName string = storageAccountName
output storageBlobEndpoint string = storage.properties.primaryEndpoints.blob
output storageContainerName string = blobContainerName
output queueName string = queueName
output devQueueName string = devQueueName
output tokenStoreSasUrl string = tokenStoreContainerSasUrl
output containerAppsEnvironmentId string = containerAppEnv.id
output containerAppsDefaultDomain string = containerAppEnv.properties.defaultDomain
output applicationIdentityPrincipalId string = containerAppIdentity.outputs.principalId
output applicationIdentityClientId string = containerAppIdentity.outputs.clientId
output applicationIdentityId string = containerAppIdentity.outputs.id
