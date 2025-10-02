targetScope = 'subscription'

@description('Environment name (e.g., dev, test, prod). Used in resource naming and tags.')
param environmentName string

@description('Azure region for deployment')
param location string

@description('Project short name for naming and tags')
param projectName string = 'app'

// Salt is computed deterministically inside each layer based on subscription, project, and environment

@description('Set of tags to apply to all resources.')
param tags object = {
  project: projectName
  'azd-env-name': environmentName
}

@description('Resource group name for this environment')
param resourceGroupName string = 'rg-${projectName}-${substring(uniqueString(subscription().id, projectName, environmentName), 0, 6)}-${environmentName}'

// Images (optional for full stack; can be empty to skip apps)
param frontendImage string = ''
param workerImage string = ''
param mcpImage string = ''
param skipContainerApps bool = false

// OIDC/Auth (pass-through)
param clientId string = 'fecc85e2-8cd0-4b21-b18a-88b9220bc1f7'
param azureTenantId string = subscription().tenantId

// External services for worker
@secure()
param contentUnderstandingApiKey string = ''
param azureAiEndpoint string = ''
param azureAiApiVersion string = '2024-12-01-preview'

// Database admin
@secure()
param pgAdminPassword string

// Ingress/profile toggles
param useWorkloadProfiles bool = true
param publicContainerApps bool = true
param deployDevelopmentQueue bool = false

resource rg 'Microsoft.Resources/resourceGroups@2020-06-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module base './main.base.bicep' = {
  name: 'base'
  params: {
    environmentName: environmentName
    location: location
    projectName: projectName
    tags: tags
    resourceGroupName: resourceGroupName
  }
}

module identity './main.identity.bicep' = {
  scope: rg
  name: 'identity'
  params: {
    environmentName: environmentName
    projectName: projectName
    tags: tags
    location: location
  }
}

module paas './main.paas.bicep' = {
  scope: rg
  name: 'paas'
  params: {
    environmentName: environmentName
    projectName: projectName
    tags: tags
    location: location
    // paas resolves vnet/subnet by name internally
    applicationIdentityPrincipalId: identity.outputs.principalId
    applicationIdentityClientId: identity.outputs.clientId
    applicationIdentityId: identity.outputs.id
    pgAdminPassword: pgAdminPassword
  }
}

module env './main.env.bicep' = {
  scope: rg
  name: 'env'
  params: {
    environmentName: environmentName
    projectName: projectName
    tags: tags
    location: location
    useWorkloadProfiles: useWorkloadProfiles
    publicContainerApps: publicContainerApps
    deployDevelopmentQueue: deployDevelopmentQueue
  }
}

module apps './main.apps.bicep' = {
  scope: rg
  name: 'apps'
  params: {
    environmentName: environmentName
    projectName: projectName
    location: location
    tags: tags
  containerAppsEnvironmentId: env.outputs.containerAppsEnvironmentId
  containerAppsDefaultDomain: env.outputs.containerAppsDefaultDomain
  applicationInsightsConnectionString: env.outputs.applicationInsightsConnectionString
  storageAccountName: env.outputs.storageAccountName
  blobContainerName: env.outputs.storageContainerName
  queueName: env.outputs.queueName
  devQueueName: deployDevelopmentQueue ? env.outputs.devQueueName : ''
  blobEndpoint: env.outputs.storageBlobEndpoint
  acrLoginServer: env.outputs.acrLoginServer
  acrName: env.outputs.acrName
    frontendImage: frontendImage
    workerImage: workerImage
    mcpImage: mcpImage
    useWorkloadProfiles: useWorkloadProfiles
    publicContainerApps: publicContainerApps
    applicationIdentityPrincipalId: identity.outputs.principalId
    applicationIdentityClientId: identity.outputs.clientId
    applicationIdentityId: identity.outputs.id
  azureOpenAIEndpoint: paas.outputs.azureOpenAiEndpoint
  azureAiSearchEndpoint: paas.outputs.azureAiSearchEndpoint
    contentUnderstandingApiKey: contentUnderstandingApiKey
  tokenStoreSas: env.outputs.tokenStoreSasUrl
  pgAdminPassword: pgAdminPassword
  databaseHost: paas.outputs.postgresFqdn
    databaseName: 'postgres'
    databaseSchema: 'public'
    clientId: clientId
    azureTenantId: azureTenantId
    azureAiEndpoint: azureAiEndpoint
    azureAiApiVersion: azureAiApiVersion
    skipContainerApps: skipContainerApps
  }
}

output MCP_ENDPOINT string = apps.outputs.MCP_ENDPOINT
output AZURE_OPENAI_ENDPOINT string = paas.outputs.azureOpenAiEndpoint
output AZURE_AI_SEARCH_ENDPOINT string = paas.outputs.azureAiSearchEndpoint
output APPLICATIONINSIGHTS_CONNECTION_STRING string = env.outputs.applicationInsightsConnectionString
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = env.outputs.acrLoginServer
output STORAGE_ACCOUNT_NAME string = env.outputs.storageAccountName
output STORAGE_CONTAINER_NAME string = env.outputs.storageContainerName
output QUEUE_NAME string = env.outputs.queueName
