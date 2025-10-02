@description('Environment name for tags and downstream resources.')
param environmentName string

@description('Azure region for the container apps resources.')
param location string

@description('ID of the existing Container Apps Environment provisioned by the env layer.')
param containerAppsEnvironmentId string

@description('Default domain of the Container Apps Environment (used for ingress URLs).')
param containerAppsDefaultDomain string

@description('Application Insights connection string shared by all container apps.')
param applicationInsightsConnectionString string

@description('Name of the shared storage account for blobs/queues.')
param storageAccountName string

@description('Blob container name for token storage.')
param blobContainerName string

@description('Queue name for worker processing.')
param queueName string

@description('Optional dev queue name exposed to the apps.')
param devQueueName string = ''

@description('Primary blob endpoint for the storage account.')
param blobEndpoint string

@description('ACR login server that hosts container images (e.g. contoso.azurecr.io).')
param acrLoginServer string

@description('Principal ID of the user-assigned managed identity attached to the apps.')
param applicationIdentityPrincipalId string

@description('Client ID of the user-assigned managed identity attached to the apps.')
param applicationIdentityClientId string

@description('Resource ID of the user-assigned managed identity attached to the apps.')
param applicationIdentityId string

@description('Endpoint for Azure OpenAI from the PaaS layer.')
param azureOpenAIEndpoint string

@description('Endpoint for Azure AI Search from the PaaS layer.')
param azureAiSearchEndpoint string

@description('Optional Azure AI endpoint override; leave blank to skip.')
param azureAiEndpoint string = ''

@description('API version to use when calling Azure AI services.')
param azureAiApiVersion string = '2024-12-01-preview'

@secure()
@description('SAS URL for the token store container (from env layer outputs).')
param tokenStoreSas string

@description('Fully qualified PostgreSQL host name from the PaaS layer.')
param databaseHost string

@description('Database name for application connections.')
param databaseName string = 'postgres'

@description('Default schema for application database connections.')
param databaseSchema string = 'public'

@description('OCI image tag for the frontend container app.')
param frontendImage string = ''

@description('OCI image tag for the worker container app.')
param workerImage string = ''

@description('OCI image tag for the MCP service container app.')
param mcpImage string = ''

@description('Optional suffix to deploy multiple app instances against shared infrastructure.')
param appInstance string = ''

@description('Toggle use of workload profiles within Container Apps.')
param useWorkloadProfiles bool = true

@description('Expose container app ingress publicly.')
param publicContainerApps bool = true

@secure()
@description('Optional secret passed through to apps for content understanding API.')
param contentUnderstandingApiKey string = ''

@secure()
@description('Optional override for Azure OpenAI API key (use managed auth when empty).')
param openAIApiKey string = ''

@secure()
@description('Optional PostgreSQL admin password for management operations.')
param pgAdminPassword string = ''

@description('Client ID used for app-level authentication (defaults to shared multi-tenant app).')
param clientId string = 'fecc85e2-8cd0-4b21-b18a-88b9220bc1f7'

@description('Azure AD tenant ID used for app authentication.')
param azureTenantId string = tenant().tenantId

@description('Skip deploying container apps (useful for infrastructure-only runs).')
param skipContainerApps bool = false

@description('Fallback image to use when skipContainerApps is true or images are not supplied.')
param defaultImage string = 'mcr.microsoft.com/dotnet/samples:aspnetapp'

var resolvedAcrName = split(acrLoginServer, '.')[0]

module apps '../../infrastructure/layers/main.apps.bicep' = {
  name: 'container-apps'
  params: {
    environmentName: environmentName
    location: location
    containerAppsEnvironmentId: containerAppsEnvironmentId
    containerAppsDefaultDomain: containerAppsDefaultDomain
    applicationInsightsConnectionString: applicationInsightsConnectionString
    storageAccountName: storageAccountName
    blobContainerName: blobContainerName
    queueName: queueName
    devQueueName: devQueueName
    blobEndpoint: blobEndpoint
    acrLoginServer: acrLoginServer
    acrName: resolvedAcrName
    applicationIdentityPrincipalId: applicationIdentityPrincipalId
    applicationIdentityClientId: applicationIdentityClientId
    applicationIdentityId: applicationIdentityId
    azureOpenAIEndpoint: azureOpenAIEndpoint
    azureAiSearchEndpoint: azureAiSearchEndpoint
    azureAiEndpoint: azureAiEndpoint
    azureAiApiVersion: azureAiApiVersion
  tokenStoreSas: tokenStoreSas
  databaseHost: databaseHost
    databaseName: databaseName
    databaseSchema: databaseSchema
    frontendImage: frontendImage
    workerImage: workerImage
    mcpImage: mcpImage
    appInstance: appInstance
    useWorkloadProfiles: useWorkloadProfiles
    publicContainerApps: publicContainerApps
    contentUnderstandingApiKey: contentUnderstandingApiKey
    openAIApiKey: openAIApiKey
    pgAdminPassword: pgAdminPassword
    clientId: clientId
    azureTenantId: azureTenantId
    skipContainerApps: skipContainerApps
    defaultImage: defaultImage
  }
}
