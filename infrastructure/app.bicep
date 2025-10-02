param buildId string = 'local'

param projectName string = 'app'
// Create a short, unique suffix, that will be unique to each resource group
param salt string = substring(uniqueString(resourceGroup().id), 0, 4)

param environmentName string
param frontendImage string = ''
param workerImage string = ''
@description('The image to use for the MCP search service container (Python fastmcp).')
param mcpImage string = ''

// New parameters for worker container app environment variables
@description('API key for Content Understanding Service. Required for worker container app')
@secure()
param contentUnderstandingApiKey string = ''

@description('Azure AI Endpoint URL. Required for worker container app')
param azureAiEndpoint string = ''

@description('Azure AI API Version. Required for worker container app')
param azureAiApiVersion string = '2024-12-01-preview'

param useManagedIdentity bool = true
param createPrivateDnsZone bool = false
param publicContainerApps bool

// caenvDelegation parameter removed (unused)
param localPrincipalId string

@secure()
@description('Postgre adminuser password')
param pgAdminPassword string = ''

param authentication string = 'msal-node'
@description('Client ID of authentication app registration. (msal node mode)')
param clientId string = 'fecc85e2-8cd0-4b21-b18a-88b9220bc1f7'



param azureTenantId string = '72f988bf-86f1-41af-91ab-2d7cd011db47'

@description('Set of tags to apply to all resources.')
param tags object = {
  environment: environmentName
  project: projectName
  buildId: buildId
  'azd-env-name': environmentName
}

@description('Azure region used for the deployment of all resources.')
param location string = resourceGroup().location

param oidcIssuerUrl string
param oidcClientId string

@secure()
param oidcClientSecret string

// VNET/Subnet parameters
// vnetAddressPrefix parameter removed (unused)

// Jump Host parameters
@description('Deploy a Bastion jumphost to access the network-isolated environment?')
param deployJumphost bool = false

param usePrivateLinks bool = false

param useWorkloadProfiles bool = true

@description('Jumphost virtual machine username')
param vmJumpboxUsername string = 'azureadmin'

@secure()
@description('Jumphost virtual machine password')
param vmJumpboxPassword string = ''


@description('VM size for the jumphost virtual machine.')
param defaultVmSize string = 'Standard_DS2_v2'

// Open AI parameters
param azureOpenAILocation string = 'eastus2'


//Azure AI Search parameters
 @description('Optional, defaults to standard. The pricing tier of the search service you want to create (for example, basic or standard).')
 @allowed([
   'free'
   'basic'
   'standard'
   'standard2'
   'standard3'
   'storage_optimized_l1'
   'storage_optimized_l2'
 ])
param azureSearchSKU string = 'basic'

 @description('Optional, defaults to 1. Replicas distribute search workloads across the service. You need at least two replicas to support high availability of query workloads (not applicable to the free tier). Must be between 1 and 12.')
 @minValue(1)
 @maxValue(12)
 param azureSearchReplicaCount int = 1

 @description('Optional, defaults to 1. Partitions allow for scaling of document count as well as faster indexing by sharding your index over multiple search units. Allowed values: 1, 2, 3, 4, 6, 12.')
 @allowed([
   1
   2
   3
   4
   6
   12
 ])
param azureSearchPartitionCount int = 1

@description('Optional, defaults to default. Applicable only for SKUs set to standard3. You can set this property to enable a single, high density partition that allows up to 1000 indexes, which is much higher than the maximum indexes allowed for any other SKU.')
 @allowed([
   'default'
   'highDensity'
 ])
param azureSearchHostingMode string = 'default'

// Container App
param skipContainerApps bool = false
param defaultImage string = 'mcr.microsoft.com/dotnet/samples:aspnetapp'

// Add new database connection parameters
param databaseHost string
param databaseName string
param databaseSchema string

@description('Token Store SAS token expiry date in ISO format')
param tokenStoreSasExpiry string = dateTimeAdd(utcNow(), 'P1Y')

var containers = {
  frontend: {
    imageWithTag: skipContainerApps ? defaultImage : frontendImage
    targetPort: 8080
    scaleRules: []
    minReplicas: 1
    maxReplicas: 1
    probes: [
      {
        type: 'Startup'
        httpGet: {
          path: '/health/startup'
          port: 8080
          scheme: 'HTTP'
        }
        failureThreshold: 3
        initialDelaySeconds: 10
        periodSeconds: 50
        timeoutSeconds: 10
      }
      {
        type: 'Readiness'
        httpGet: {
          path: '/health/readiness'
          port: 8080
          scheme: 'HTTP'
        }
        failureThreshold: 3
        initialDelaySeconds: 10
        periodSeconds: 50
        timeoutSeconds: 10
      }
      {
        type: 'Liveness'
        httpGet: {
          path: '/health/liveness'
          port: 8080
          scheme: 'HTTP'
        }
        failureThreshold: 3
        initialDelaySeconds: 10
        periodSeconds: 50
        timeoutSeconds: 10
      }
    ]
  }
  worker: {
    imageWithTag: skipContainerApps ? defaultImage : workerImage
    targetPort: 8080
    scaleRules: []
    minReplicas: 1
    maxReplicas: 2
    probes: []
  }
  // Lightweight MCP server exposing search tool over SSE (see src/backend/mcp/server.py)
  mcp: {
    imageWithTag: skipContainerApps ? defaultImage : mcpImage
    targetPort: 5003
    scaleRules: []
    minReplicas: 1
    maxReplicas: 1
    probes: []
  }
}

param acrName string = 'acr${salt}'

var blobContainerName = 'blob${salt}'
var enableOidcAuth = false // !empty(oidcIssuerUrl) && !empty(oidcClientId) && !empty(oidcClientSecret)
param queueName string = 'tasks${salt}'
// Resource Names
param logAnalyticsWorkspaceName string = 'law-${salt}'
param applicationInsightsName string = 'appi-${salt}'

// The Bastion Subnet is required to be named 'AzureBastionSubnet'
// bastionSubnetName variable removed (unused)

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-06-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
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


// applicationIdentityName parameter removed (unused)
param applicationIdentityPrincipalId string
param applicationIdentityClientId string
param applicationIdentityId string
param gptDeploymentName string = 'gpt-4.1'
param gptModelName string = 'gpt-4.1'
param gptModelVersion string = '2025-04-14'
param openAIAPIVersion string = '2024-12-01-preview'
param miniModelName string = 'gpt-5-mini'
param miniModelVersion string = '2025-08-07'
param miniModelDeploymentName string = 'gpt-5-mini'
//param gptModelName string = 'gpt-4'
//param gptModelVersion string = 'turbo-2024-04-09'
//param openAIAPIVersion string = '2024-06-01'
param openAiModelDeployments array = [
  {
    name: gptDeploymentName
    model: gptModelName
    version: gptModelVersion
    tags: tags
    sku: {
      name: 'GlobalStandard'
      capacity: 440
    }
  }
  {
     name: 'text-embedding-3-large'
     model: 'text-embedding-3-large'
     sku: {
       name: 'Standard'
       capacity: 150
     }
  }
   {
     name: miniModelDeploymentName
     model: miniModelName
     version: miniModelVersion
     sku: {
       name: 'GlobalStandard'
       capacity: 700
     }
  }
]

var acrPullRole = resourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var storageRole = resourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var storageBlobDataOwnerRole = resourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var storageQueueDataContributorRole = resourceId(
  'Microsoft.Authorization/roleDefinitions',
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
)

var openAiAllAccessRole = resourceId('Microsoft.Authorization/roleDefinitions', 'a001fd3d-188f-4b5d-821b-7da978bf7442')
var openAiUserAccessRole = resourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')

resource uaiRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity) {
  name: guid(resourceGroup().id, applicationIdentityId, acrPullRole)
  scope: containerRegistry
  properties: {
    roleDefinitionId: acrPullRole
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource openAiRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity) {
  name: guid(resourceGroup().id, applicationIdentityId, openAiAllAccessRole)
  scope: openAIAccount
  properties: {
    roleDefinitionId: openAiAllAccessRole
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource openAiUserRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity) {
  name: guid(resourceGroup().id, applicationIdentityId, openAiUserAccessRole)
  scope: openAIAccount
  properties: {
    roleDefinitionId: openAiUserAccessRole
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource uaiRbacStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity) {
  name: guid(resourceGroup().id, applicationIdentityId, storageRole)
  scope: storage
  properties: {
    roleDefinitionId: storageRole
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource uaiRbacStorageDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity) {
  name: guid(resourceGroup().id, applicationIdentityId, storageBlobDataOwnerRole)
  scope: storage
  properties: {
    roleDefinitionId: storageBlobDataOwnerRole
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource uaiRbacQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity) {
  name: guid(resourceGroup().id, applicationIdentityId, storageQueueDataContributorRole)
  scope: storage
  properties: {
    roleDefinitionId: storageQueueDataContributorRole
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource localPrincipalStorageAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity && length(localPrincipalId) > 0) {
  name: guid(resourceGroup().id, localPrincipalId, storageRole)
  scope: storage
  properties: {
    roleDefinitionId: storageRole
    principalId: localPrincipalId
    principalType: 'User'
  }
}

resource localPrincipalBlobDataOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity && length(localPrincipalId) > 0) {
  name: guid(resourceGroup().id, localPrincipalId, storageBlobDataOwnerRole)
  scope: storage
  properties: {
    roleDefinitionId: storageBlobDataOwnerRole
    principalId: localPrincipalId
    principalType: 'User'
  }
}

resource localPrincipalQueueDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity && length(localPrincipalId) > 0) {
  name: guid(resourceGroup().id, localPrincipalId, storageQueueDataContributorRole)
  scope: storage
  properties: {
    roleDefinitionId: storageQueueDataContributorRole
    principalId: localPrincipalId
    principalType: 'User'
  }
}

param openAIAccountName string = 'oai${salt}'
resource openAIAccount 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: openAIAccountName
  tags: tags
  location: azureOpenAILocation
  kind: 'OpenAI'
  properties: {
    restore: false
    customSubDomainName: openAIAccountName
    publicNetworkAccess: usePrivateLinks ? 'Disabled' : 'Enabled'
    networkAcls: usePrivateLinks
      ? {
          defaultAction: 'Deny'
        }
      : null
  }
  sku: {
    name: 'S0'
  }
  @batchSize(1)
  resource deployment 'deployments' = [
    for deployment in openAiModelDeployments: {
      name: deployment.name
      sku: deployment.?sku ?? {
            name: 'Standard'
            capacity: 20
      }
      properties: {
        model: {
          format: 'OpenAI'
          name: deployment.model
          version: deployment.?version ?? null
        }
        raiPolicyName: deployment.?raiPolicyName ?? null
        versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
      }
    }
  ]
}

//OpenAI diagnostic settings
resource openAIDiagSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${openAIAccount.name}-diagnosticSettings'
  scope: openAIAccount
  properties: {
    workspaceId: logAnalyticsWorkspace.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
        retentionPolicy: {
          enabled: false
          days: 0
        }
      }
    ]
    logAnalyticsDestinationType: null
  }
}

param openAiPriveEndpointName string = 'ple-${salt}-openai'
module openaiPrivateEndpoint 'privateEndpoint.bicep' = if (usePrivateLinks) {
  name: openAiPriveEndpointName
  params: {
    dnsZoneName: 'privatelink.openai.azure.com'
    groupIds: [
      'account'
    ]
    tags: tags
    location: location
    createPrivateDnsZone: createPrivateDnsZone
    name: openAiPriveEndpointName
    subnetId: privateEndpointSubnetId
    vnetId: vnetId
    privateLinkServiceId: openAIAccount.id
  }
}

param vnetId string
param containerAppSubnetId string
param privateEndpointSubnetId string
param resourceSubnetId string
param bastionSubnetId string

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2021-09-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: 'Premium'
  }
  properties: {
    adminUserEnabled: true
    dataEndpointEnabled: false
    networkRuleBypassOptions: 'AzureServices'
    networkRuleSet: {
      defaultAction: 'Allow'
      ipRules: []
          }
    policies: {
      quarantinePolicy: {
        status: 'disabled'
      }
      retentionPolicy: {
        status: 'enabled'
        days: 7
      }
      trustPolicy: {
        status: 'disabled'
        type: 'Notary'
      }
    }
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: 'Disabled'
  }
}

// module containerRegistryPrivateEndpoint 'privateEndpoint.bicep' = if (usePrivateLinks) {
//   name: 'acrEndpoint'
//   params: {
//     dnsZoneName: 'privatelink${az.environment().suffixes.acrLoginServer}'
//     tags: tags
//     groupIds: [
//       'registry'
//     ]
//     location: location
//     name: acrName
//     subnetId: privateEndpointSubnetId
//     vnetId: vnetId
//     privateLinkServiceId: containerRegistry.id
//     createPrivateDnsZone: createPrivateDnsZone
//   }
// }

@description('The name of the Bastion public IP address')
param bastionPublicIpName string = 'pip-bastion'

@description('The name of the Bastion host')
param bastionHostName string = 'bastion-jumpbox'

resource publicIpAddressForBastion 'Microsoft.Network/publicIPAddresses@2022-01-01' = if (deployJumphost) {
  name: bastionPublicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// Create the Bastion host
resource bastionHost 'Microsoft.Network/bastionHosts@2022-01-01' = if (deployJumphost) {
  name: bastionHostName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'IpConf'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: publicIpAddressForBastion.id
          }
        }
      }
    ]
  }
}

param storageAccountName string = 'st${salt}'
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: usePrivateLinks ? false : true
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: false
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
        queue: {
          enabled: true
          keyType: 'Service'
        }
        table: {
          enabled: true
          keyType: 'Service'
        }
      }
    }
    isHnsEnabled: false
    isNfsV3Enabled: false
    keyPolicy: {
      keyExpirationPeriodInDays: 7
    }
    largeFileSharesState: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'  // Keep as Deny to enforce VNet-only access
      virtualNetworkRules: (!usePrivateLinks) ? [
        {
          id: containerAppSubnetId
          action: 'Allow'
        }
      ] : []
      ipRules: []
    }
    supportsHttpsTrafficOnly: true
  }
  resource blobService 'blobServices' existing = {
    name: 'default'

    resource container 'containers' = {
      name: blobContainerName
    }
    resource tokenStore 'containers' = {
      name: 'tokenstore'  // Changed from 'tokenStore' to 'tokenstore'
    }

  }
  
  resource queueServices 'queueServices' existing = {
    name: 'default'
  }
}
  // Modify the SAS token generation to use the updated container name
  var tokenStoreContainerSas = storage.listServiceSAS('2021-09-01', {
    canonicalizedResource: '/blob/${storage.name}/tokenstore'  
    signedResource: 'c'
    signedProtocol: 'https'
    signedPermission: 'rwadl'
    signedServices: 'b'
    signedExpiry: tokenStoreSasExpiry
    signedVersion: '2022-11-02'
  }).serviceSasToken

  // Update the SAS URL with the correct container name
  var tokenStoreContainerSasUrl = '${storage.properties.primaryEndpoints.blob}tokenstore?${tokenStoreContainerSas}'  // Changed from 'tokenStore' to 'tokenstore'
/*
az containerapp auth update \
  --resource-group rg-app-y5y56-pj6 \
  --name frontend \
  --sas-url-secret-name token-store-sas \
  --token-store true
*/



@description('Deploy development queue')
param deployDevelopmentQueue bool = false

var devQueueName = '${queueName}dev'

@description('Queue names')
var queueNames = deployDevelopmentQueue ? [queueName, devQueueName] : [queueName]

// Create queues using a loop
resource queues 'Microsoft.Storage/storageAccounts/queueServices/queues@2022-09-01' = [for queueName in queueNames: {
  parent: storage::queueServices
  name: queueName
}]

// Create event subscriptions using a loop
resource blobEventSubscriptions 'Microsoft.EventGrid/eventSubscriptions@2023-06-01-preview' = [for (queueName, index) in queueNames: {
  name: 'blobEventsSubscription-${queueName}'
  scope: storage
  properties: {
    destination: {
      endpointType: 'StorageQueue'
      properties: {
        resourceId: storage.id
        queueName: queueName
        queueMessageTimeToLiveInSeconds: 3600
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
        'Microsoft.Storage.BlobDeleted'
        'Microsoft.Storage.BlobPropertiesUpdated'
        'Microsoft.Storage.BlobRenamed'
      ]
    }
    eventDeliverySchema: 'CloudEventSchemaV1_0'
  }
}]

output AZURE_BLOB_STORAGE_ENDPOINT string = storage.properties.primaryEndpoints.blob
output AZURE_BLOB_CONTAINER_NAME string = blobContainerName

var blobPrivateEndpointName = 'ple-${salt}-st-blob'

module blobPrivateEndpoint 'privateEndpoint.bicep' = if (usePrivateLinks) {
  name: blobPrivateEndpointName
  params: {
    dnsZoneName: 'privatelink.blob.${az.environment().suffixes.storage}'
    tags: tags
    groupIds: [
      'blob'
    ]
    location: location
    name: blobPrivateEndpointName
    subnetId: privateEndpointSubnetId
    vnetId: vnetId
    privateLinkServiceId: storage.id
    createPrivateDnsZone: createPrivateDnsZone
  }
}
var queuePrivateEndpointName = 'ple-${salt}-st-queue'
module queuePrivateEndpoint 'privateEndpoint.bicep' = if (usePrivateLinks) {
  name: queuePrivateEndpointName
  params: {
    dnsZoneName: 'privatelink.queue.${az.environment().suffixes.storage}'
    tags: tags
    groupIds: [
      'queue'
    ]
    location: location
    name: queuePrivateEndpointName
    subnetId: privateEndpointSubnetId
    vnetId: vnetId
    privateLinkServiceId: storage.id
    createPrivateDnsZone: createPrivateDnsZone
  }
}

var uploadShareName = 'upload${salt}'
var backendShareName = 'backend${salt}'

var filePrivateEndpointName = 'ple-${salt}-st-file'
module filePrivateEndpoint 'privateEndpoint.bicep' = if (usePrivateLinks) {
  name: filePrivateEndpointName
  params: {
    tags: tags
    dnsZoneName: 'privatelink.file.${az.environment().suffixes.storage}'
    groupIds: [
      'file'
    ]
    location: location
    name: filePrivateEndpointName
    subnetId: privateEndpointSubnetId
    vnetId: vnetId
    privateLinkServiceId: storage.id
    createPrivateDnsZone: createPrivateDnsZone
  }
}

param azureSearchName string = 'azsearch-${salt}'
// semantic search not available in most regions
param azureSearchLocation string = 'westeurope'
// // Create an Azure Search service
resource azureSearch 'Microsoft.Search/searchServices@2023-11-01' = {
   name: azureSearchName
   location: azureSearchLocation
   tags: tags
   sku: {
     name: azureSearchSKU
   }
   properties: {
     replicaCount: azureSearchReplicaCount
     partitionCount: azureSearchPartitionCount
     hostingMode: azureSearchHostingMode
     publicNetworkAccess: usePrivateLinks ? 'disabled' : 'enabled'
     semanticSearch: 'standard'     
     authOptions: {
       aadOrApiKey: {
        aadAuthFailureMode: 'http403'        
      }
     }
   }
   identity: {
    type: 'SystemAssigned'
  }
 }
 resource searchOpenAiUserRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, azureSearch.id, openAiUserAccessRole)
  scope: openAIAccount
  properties: {
    roleDefinitionId: openAiUserAccessRole
    principalId: azureSearch.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

 param azureaisearchPrivateEndpointName string = 'ple-${salt}-azsearch'
 module azureSearchPrivateEndpoint 'privateEndpoint.bicep' = if (usePrivateLinks) {
   name: azureaisearchPrivateEndpointName
   params: {
      tags: tags
     dnsZoneName: 'privatelink.search.windows.net'
     groupIds: [
       'searchService'
     ]
     createPrivateDnsZone: createPrivateDnsZone
     location: location
     name: azureaisearchPrivateEndpointName
     subnetId: privateEndpointSubnetId
     vnetId: vnetId
     privateLinkServiceId: azureSearch.id
   }
 }

// Define the role IDs for Azure AI Search permissions
var searchServiceContributorRole = resourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
var searchIndexDataContributorRole = resourceId('Microsoft.Authorization/roleDefinitions', '8ebe5a00-799e-43f5-93ac-243d3dce84a7')

// Add RBAC assignment for Search Service Contributor role
resource uaiSearchServiceContributorRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity) {
  name: guid(resourceGroup().id, applicationIdentityId, searchServiceContributorRole)
  scope: azureSearch
  properties: {
    roleDefinitionId: searchServiceContributorRole
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// Add RBAC assignment for Search Index Data Contributor role
resource uaiSearchIndexDataContributorRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity) {
  name: guid(resourceGroup().id, applicationIdentityId, searchIndexDataContributorRole)
  scope: azureSearch
  properties: {
    roleDefinitionId: searchIndexDataContributorRole
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

param workloadProfiles array = useWorkloadProfiles
  ? [
      {
        maximumCount: 3
        minimumCount: 0
        name: 'Dedicated'  // Changed to match standard naming
        workloadProfileType: 'D4'
      }
    ]
  : []

param containerAppEnvName string = 'env-${salt}'
resource containerAppEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppEnvName
  tags: tags
  location: location
  properties: {
    vnetConfiguration: {
      internal: usePrivateLinks && !publicContainerApps
      infrastructureSubnetId: containerAppSubnetId
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
  resource uploadEnvironmentStorage 'storages' = {
    name: uploadShareName
    properties: {
      azureFile: {
        accountName: storageAccountName
        shareName: uploadShareName
        accessMode: 'ReadWrite'
        accountKey: storage.listKeys().keys[0].value
      }
    }
  }
  resource backendEnvironmentStorage 'storages' = {
    name: backendShareName
    properties: {
      azureFile: {
        accountName: storageAccountName
        shareName: backendShareName
        accessMode: 'ReadWrite'
        accountKey: storage.listKeys().keys[0].value
      }
    }
  }
  
}

// to be able to use properties as name, this is on a separate module
module containerAppPrivateDns 'containerAppPrivateDns.bicep' = if (usePrivateLinks && !publicContainerApps) {
  name: 'containerAppPrivateDns-${salt}-deployment'
  params: {
    tags: tags
    defaultDomain: containerAppEnv.properties.defaultDomain
    staticIp: containerAppEnv.properties.staticIp
    vnetId: vnetId
  }
}
var secrets = [
    {
      name: 'microsoft-provider-authentication-secret'
      value: enableOidcAuth ? oidcClientSecret : 'NO OIDC'
    }
    {
      name: 'acr-password'
      value: containerRegistry.listCredentials().passwords[0].value
    }
    {
      name: 'openaikey'
      value: openAIAccount.listKeys().key1
    }
    {
      name: 'token-store-sas'
      value: tokenStoreContainerSasUrl
    }
    {
      name: 'azuresearch-key'
      value: azureSearch.listAdminKeys().primaryKey
    }
    {
      name: 'content-understanding-api-key'
      value: contentUnderstandingApiKey
    }
    {
      name: 'pg-admin-password'
      value: pgAdminPassword
    }
]

var servicesUrlConfig = [for container in items(containers): { 
  name: '${toUpper(replace(container.key, '-', '_'))}_URL'
  value: 'https://${container.key}'
}]

var credentialsEnv = [
  {
    name: 'AZURE_BLOB_STORAGE_ENDPOINT'
    value: storage.properties.primaryEndpoints.blob
  }
  {
    name: 'OTEL_RESOURCE_ATTRIBUTES'
    value: 'service.namespace=${resourceGroup().name},service.instance.id=${projectName}-${salt}'
  }
  {
    name: 'OTEL_SERVICE_NAME'
    value: projectName
  }
  {
    name: 'AZURE_CLIENT_ID' 
    value: applicationIdentityClientId
  }
  { name: 'MANAGED_IDENTITY_TENANT'
    value: subscription().tenantId
  }
  {
    name: 'AZURE_AI_SEARCH_ENDPOINT'
    value: 'https://${azureSearchName}.search.windows.net'
  }
  {
    name: 'AZURE_AI_SEARCH_INDEX'
    value: 'content_understanding_index'
  }
  {
    name: 'AZUREAI_SEARCH_API_KEY'
    secretRef: 'azuresearch-key'
  }
  {
    name: 'AZURE_AI_ENDPOINT'
    value: azureAiEndpoint
  }
  {
    name: 'AZURE_AI_API_VERSION'
    value: azureAiApiVersion
  }
  {
    name: 'CONTENT_UNDERSTANDING_API_KEY'
    secretRef: 'content-understanding-api-key'
  }
  {
    name: 'AZURE_OPENAI_ENDPOINT'
    value: openAIAccount.properties.endpoint
  }
  {
    name: 'AZURE_OPENAI_MINI_ENDPOINT'
    value: openAIAccount.properties.endpoint
  }
  {
    name: 'AZURE_OPENAI_INSTANCE_NAME'
    value: openAIAccountName
  }
  {
    name: 'AZURE_OPENAI_API_VERSION'
    value: openAIAPIVersion
  }
  {
    name: 'AZURE_OPENAI_DEPLOYMENT_NAME'
    value: gptDeploymentName
  }
  {
    name: 'AZURE_OPENAI_MINI_DEPLOYMENT_NAME'
    value: miniModelDeploymentName
  }
  {
    name: 'AZURE_OPENAI_DEPLOYMENT_VERSION'
    value: openAIAPIVersion
  }
  {
    name: 'AZURE_OPENAI_API_KEY'
    secretRef: 'openaikey'
  }
  {
    name: 'AZURE_OPENAI_MINI_API_KEY'
    secretRef: 'openaikey'
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: applicationInsights.properties.ConnectionString
  }
  {
    name: 'LOG_LEVEL'
    value: 'INFO'
  }
  { 
    name: 'STORAGE_ACCOUNT_NAME'
    value: storageAccountName 
  }
  { 
    name: 'QUEUE_NAME'
    value: queueName 
  }
  {
    name: 'STORAGE_CONTAINER_NAME'
    value: blobContainerName
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: applicationInsights.properties.ConnectionString
  }
  {
    name: 'USE_MANAGE_IDENTITY'
    value: useManagedIdentity ? 'true' : 'false'
  }  
  {
    name: 'DATABASE_HOST'
    value: databaseHost
  }  
  {
    name: 'DATABASE_NAME'
    value: databaseName
  }
  {
    name: 'DATABASE_SCHEMA'
    value: databaseSchema
  }
  {
    name: 'DATABASE_USER'
    value: applicationIdentityPrincipalId
  }
  {
      name: 'DATABASE_ADMIN_USER'
      value: 'postgres'
    }
{
      name: 'DATABASE_ADMIN_PASSWORD'
      secretRef: 'pg-admin-password'
    }
  {
    name: 'PORT'
    value: '8080'
  }
  {
    name: 'AUTHENTICATION'
    value: authentication
  }
  {
    name: 'CLIENT_ID'
    value: clientId
  }
  {
      name: 'MANAGED_IDENTITY_CLIENT_ID'
      value: applicationIdentityClientId
    }
  {
      name: 'AZURE_TENANT_ID'
      value: azureTenantId
    }
  // MCP (Model Context Protocol) service defaults; can be overridden via deployment params if needed
  {
    name: 'MCP_JWT_VERIFY'
    value: '0'
  }
  {
    name: 'MCP_ALLOW_ANONYMOUS'
    value: '0'
  }
]


resource containerApp 'Microsoft.App/containerApps@2024-08-02-preview' = [
  for container in items(containers): {
    name: container.key
    tags: union(tags, {
      'azd-service-name': container.key
    })
    location: location
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
        '${applicationIdentityId}': {}
      }
    }
    properties: {
      managedEnvironmentId: containerAppEnv.id
      workloadProfileName: useWorkloadProfiles ? 'Dedicated' : null  // Explicitly set the profile name
      configuration: {
        secrets: secrets
        registries: [
          {
            identity: useManagedIdentity ? applicationIdentityId : null
            server: containerRegistry.properties.loginServer
            username: acrName
            passwordSecretRef: 'acr-password'
          }
        ]
        ingress: {
          external: publicContainerApps
          targetPort: container.value.targetPort
          corsPolicy: {
            allowedOrigins: [
              '*'
            ]
            allowedMethods: [
              '*'
            ]
            allowedHeaders: [
              '*'
            ]
            exposeHeaders: null
            maxAge: 0
            allowCredentials: true
          }
          transport: 'auto'  // Enable HTTP/2 and WebSocket support
          allowInsecure: false
          traffic: [
            {
              latestRevision: true
              weight: 100
            }
          ]
        }
      }
      template: {
        scale: {
          minReplicas: container.value.minReplicas ?? 1
          maxReplicas: container.value.maxReplicas ?? 1
          rules: concat([
            {
              name: 'http-requests'
              http: {
                metadata: {
                  concurrentRequests: '10'
                }
              }
            }
          ], container.value.scaleRules ?? [])
        }
        containers: [
          {
            name: container.key
            image: empty(container.value.imageWithTag) ? defaultImage : container.value.imageWithTag
            probes: container.value.probes
            env: union(servicesUrlConfig, credentialsEnv, [
              {
                name: 'OTEL_RESOURCE_ATTRIBUTES'
                value: 'service.namespace=${resourceGroup().name},service.instance.id=${projectName}.${container.key}'
              }
              {
                name: 'OTEL_SERVICE_NAME'
                value: '${projectName}.${container.key}'
              }
              { name:'REDIRECT_URI'
                value: 'https://${container.key}.${containerAppEnv.properties.defaultDomain}/redirect'
              }
              { name:'FRONTEND_URL'
                value: 'https://${container.key}.${containerAppEnv.properties.defaultDomain}'
              }
            ]) 
            resources: {
              cpu: json(useWorkloadProfiles ? '2.0' : '1.0')  // Adjusted CPU for dedicated workload
              memory: useWorkloadProfiles ? '4Gi' : '2Gi'  // Adjusted memory for dedicated workload
            }
          }
        ]
      }
    }
  }
]

module authConfigsModule 'authConfigs.bicep' = if (enableOidcAuth) {
  name: 'authConfigsModule'
  params: {
    containers: containers
    oidcIssuerUrl: oidcIssuerUrl
    oidcClientId: oidcClientId
    tokenStoreSasSecretName: 'token-store-sas'
  }
  dependsOn: [
    containerApp
  ]
}

param virtualMachineName string = 'vm-${salt}'
resource networkInterface 'Microsoft.Network/networkInterfaces@2022-07-01' = if (usePrivateLinks && deployJumphost) {
  name: '${virtualMachineName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: resourceSubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource virtualMachine 'Microsoft.Compute/virtualMachines@2021-03-01' = if (usePrivateLinks && deployJumphost) {
  name: virtualMachineName
  location: location
  properties: {
    hardwareProfile: {
      vmSize: defaultVmSize
    }
    storageProfile: {
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      imageReference: {
        publisher: 'microsoft-dsvm'
        offer: 'dsvm-win-2019'
        sku: 'server-2019'
        version: 'latest'
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
        }
      ]
    }
    osProfile: {
      computerName: virtualMachineName
      adminUsername: vmJumpboxUsername
      adminPassword: vmJumpboxPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
        patchSettings: {
          enableHotpatching: false
          patchMode: 'AutomaticByOS'
        }
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
  identity: {
    type: 'SystemAssigned'
  }
}
var aadLoginExtensionName = 'AADLoginForWindows'
resource virtualMachineName_aadLoginExtensionName 'Microsoft.Compute/virtualMachines/extensions@2021-11-01' = if (usePrivateLinks && deployJumphost) {
  parent: virtualMachine
  name: aadLoginExtensionName
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: aadLoginExtensionName
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
  }
}

output APPLICATIONINSIGHTS_CONNECTION_STRING string = applicationInsights.properties.ConnectionString
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.properties.loginServer
output AZURE_OPENAI_API_VERSION string = openAIAPIVersion
output AZURE_OPENAI_API_KEY string = openAIAccount.listKeys().key1
output AZURE_OPENAI_ENDPOINT string = openAIAccount.properties.endpoint
output AZURE_OPENAI_DEPLOYMENT_NAME string = openAiModelDeployments[0].name
output AZURE_OPENAI_DEPLOYMENT_VERSION string = openAiModelDeployments[0].version
output AZURE_STORAGE_ACCOUNT string = storageAccountName
output LOG_LEVEL string = 'INFO'
output STORAGE_ACCOUNT_NAME string = storageAccountName
output STORAGE_CONTAINER_NAME string = blobContainerName
output QUEUE_NAME string = queueName
output DEV_QUEUE_NAME string = devQueueName
output TOKEN_STORE_SAS_URL string = tokenStoreContainerSasUrl
output AZURE_AI_ENDPOINT string = azureAiEndpoint
output AZURE_AI_API_VERSION string = azureAiApiVersion
output AZURE_AI_SEARCH_ENDPOINT string = 'https://${azureSearchName}.search.windows.net'
// Expose base MCP endpoint (container app default domain + service name) for clients
output MCP_ENDPOINT string = 'https://mcp.${containerAppEnv.properties.defaultDomain}'

