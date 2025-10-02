targetScope = 'resourceGroup'

@description('Environment name (e.g., dev, test, prod). Used in naming and tags.')
param environmentName string

@description('Project short name for naming and tags')
param projectName string = 'app'

// Bicep: parameter defaults can reference only other parameters; define salt as a param with a computed default
param salt string = substring(uniqueString(subscription().id, projectName, environmentName), 0, 6)

@description('Tags to apply across resources')
param tags object = {
  project: projectName
  'azd-env-name': environmentName
}

@description('Azure region for compute where applicable')
param location string = resourceGroup().location

@description('Virtual network and subnet names from Base layer (will be referenced as existing)')
param vnetName string = 'vnet-${salt}'
param privateEndpointSubnetName string = 'pe-subnet'

// Existing references for networking
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' existing = {
  name: vnetName
}
resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-05-01' existing = {
  name: privateEndpointSubnetName
  parent: vnet
}

@description('Managed identity for apps that will consume PaaS services')
param applicationIdentityPrincipalId string
param applicationIdentityClientId string
param applicationIdentityId string

@secure()
@description('Password for posgres admin user "postgres"')
param pgAdminPassword string

@description('OpenAI account location (can differ by availability)')
param azureOpenAILocation string = 'eastus2'

@description('Azure AI Search parameters')
param azureSearchSKU string = 'basic'
@minValue(1)
@maxValue(12)
param azureSearchReplicaCount int = 1
@allowed([1,2,3,4,6,12])
param azureSearchPartitionCount int = 1
@allowed(['default','highDensity'])
param azureSearchHostingMode string = 'default'

@description('Names')
param openAIAccountName string = 'oai${salt}'
param azureSearchName string = 'azsearch-${salt}'
param postgreName string = 'postgre-${salt}'

// PostgreSQL Flexible Server
module postgres '../postgre.bicep' = {
  name: 'postgres'
  params: {
    postgreName: postgreName
    location: location
    pgAdminPassword: pgAdminPassword
    usePrivateLinks: true
    privateEndpointSubnetId: privateEndpointSubnet.id
    vnetId: vnet.id
    createPrivateDnsZone: true
    tags: tags
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
    principalName: applicationIdentityClientId
  }
}

// OpenAI account and deployments
resource openAIAccount 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name: openAIAccountName
  location: azureOpenAILocation
  tags: tags
  kind: 'OpenAI'
  properties: {
    customSubDomainName: openAIAccountName
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
    }
  }
  sku: {
    name: 'S0'
  }
}

// Private endpoint for OpenAI
module openaiPrivateEndpoint '../privateEndpoint.bicep' = {
  name: 'ple-${salt}-openai'
  params: {
    dnsZoneName: 'privatelink.openai.azure.com'
    groupIds: ['account']
    tags: tags
    location: location
    createPrivateDnsZone: true
    name: 'ple-${salt}-openai'
    subnetId: privateEndpointSubnet.id
    vnetId: vnet.id
    privateLinkServiceId: openAIAccount.id
  }
}

// Azure AI Search (system-assigned identity)
resource azureSearch 'Microsoft.Search/searchServices@2023-11-01' = {
  name: azureSearchName
  location: location
  tags: tags
  sku: {
    name: azureSearchSKU
  }
  properties: {
    replicaCount: azureSearchReplicaCount
    partitionCount: azureSearchPartitionCount
    hostingMode: azureSearchHostingMode
    publicNetworkAccess: 'disabled'
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

// Grant Search access to OpenAI (User Access role)
var openAiUserAccessRole = resourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
resource searchOpenAiUserRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, azureSearch.id, openAiUserAccessRole)
  scope: openAIAccount
  properties: {
    roleDefinitionId: openAiUserAccessRole
    principalId: azureSearch.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Private endpoint for Search
module searchPrivateEndpoint '../privateEndpoint.bicep' = {
  name: 'ple-${salt}-azsearch'
  params: {
    dnsZoneName: 'privatelink.search.windows.net'
    groupIds: ['searchService']
    tags: tags
    location: location
    createPrivateDnsZone: true
    name: 'ple-${salt}-azsearch'
    subnetId: privateEndpointSubnet.id
    vnetId: vnet.id
    privateLinkServiceId: azureSearch.id
  }
}

// RBAC for application identity on Search
var searchServiceContributorRole = resourceId('Microsoft.Authorization/roleDefinitions', '7ca78c08-252a-4471-8644-bb5ff32d4ba0')
var searchIndexDataContributorRole = resourceId('Microsoft.Authorization/roleDefinitions', '8ebe5a00-799e-43f5-93ac-243d3dce84a7')
resource uaiSearchServiceContributorRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, applicationIdentityId, searchServiceContributorRole)
  scope: azureSearch
  properties: {
    roleDefinitionId: searchServiceContributorRole
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}
resource uaiSearchIndexDataContributorRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, applicationIdentityId, searchIndexDataContributorRole)
  scope: azureSearch
  properties: {
    roleDefinitionId: searchIndexDataContributorRole
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// RBAC for application identity on OpenAI (optional AAD-based access)
var openAiAllAccessRole = resourceId('Microsoft.Authorization/roleDefinitions', 'a001fd3d-188f-4b5d-821b-7da978bf7442')
var openAiUserAccessRoleForUai = resourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
resource uaiOpenAiAllAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, applicationIdentityId, openAiAllAccessRole)
  scope: openAIAccount
  properties: {
    roleDefinitionId: openAiAllAccessRole
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}
resource uaiOpenAiUserAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, applicationIdentityId, openAiUserAccessRoleForUai)
  scope: openAIAccount
  properties: {
    roleDefinitionId: openAiUserAccessRoleForUai
    principalId: applicationIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output postgresFqdn string = postgres.outputs.fullyQualifiedDomainName
output azureOpenAiEndpoint string = openAIAccount.properties.endpoint
output azureAiSearchEndpoint string = 'https://${azureSearchName}.search.windows.net'
output azureOpenAiAccountId string = openAIAccount.id
output azureAiSearchId string = azureSearch.id
// Do not output secrets (OpenAI/Search keys). Use managed identity where possible.
