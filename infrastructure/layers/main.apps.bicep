targetScope = 'resourceGroup'

@description('Environment name for tags')
param environmentName string

@description('Project name')
param projectName string = 'app'

@description('Azure region')
param location string = resourceGroup().location

var salt string = substring(uniqueString(subscription().id, projectName, environmentName), 0, 6)

@description('Tags to apply across resources')
param tags object = {
  environment: environmentName
  project: projectName
  'azd-env-name': environmentName
}

// Inputs from env layer
param containerAppsEnvironmentId string
param containerAppsDefaultDomain string
param applicationInsightsConnectionString string
param storageAccountName string
param blobContainerName string
param queueName string
@description('If provided, deploy an additional dev queue name variable as DEV_QUEUE_NAME via env')
param devQueueName string = ''
param blobEndpoint string
param acrLoginServer string

// Images and app deploy switches
param frontendImage string = ''
param workerImage string = ''
param mcpImage string = ''

param useWorkloadProfiles bool = true
param publicContainerApps bool = true

@description('Optional instance suffix to allow multiple ACA apps per shared PaaS')
param appInstance string = ''

// Identity inputs
param applicationIdentityPrincipalId string
param applicationIdentityClientId string
param applicationIdentityId string

// External service endpoints
param azureOpenAIEndpoint string
param azureAiSearchEndpoint string
param azureAiEndpoint string = ''
param azureAiApiVersion string = '2024-12-01-preview'

// Secrets
@secure()
param contentUnderstandingApiKey string = ''
@secure()
param openAIApiKey string = ''
@secure()
param tokenStoreSas string
@secure()
param pgAdminPassword string = ''

// Database connection
param databaseHost string
param databaseName string = 'postgres'
param databaseSchema string = 'public'

// App auth
param clientId string = 'fecc85e2-8cd0-4b21-b18a-88b9220bc1f7'
param azureTenantId string = subscription().tenantId

// Skip flag when images missing
param skipContainerApps bool = false
param defaultImage string = 'mcr.microsoft.com/dotnet/samples:aspnetapp'

var containers = {
  frontend: {
    imageWithTag: skipContainerApps ? defaultImage : frontendImage
    targetPort: 8080
    minReplicas: 1
    maxReplicas: 1
    probes: []
  }
  worker: {
    imageWithTag: skipContainerApps ? defaultImage : workerImage
    targetPort: 8080
    minReplicas: 1
    maxReplicas: 2
    probes: []
  }
  mcp: {
    imageWithTag: skipContainerApps ? defaultImage : mcpImage
    targetPort: 5003
    minReplicas: 1
    maxReplicas: 1
    probes: []
  }
}

var secrets = [
  { name: 'token-store-sas', value: tokenStoreSas }
  { name: 'openaikey', value: openAIApiKey }
  { name: 'azuresearch-key', value: '' } // Optional: use managed auth when available
  { name: 'content-understanding-api-key', value: contentUnderstandingApiKey }
  { name: 'pg-admin-password', value: pgAdminPassword }
]

var credentialsEnv = [
  { name: 'AZURE_BLOB_STORAGE_ENDPOINT', value: blobEndpoint }
  { name: 'OTEL_RESOURCE_ATTRIBUTES', value: 'service.namespace=${resourceGroup().name},service.instance.id=${projectName}-${salt}' }
  { name: 'OTEL_SERVICE_NAME', value: projectName }
  { name: 'AZURE_CLIENT_ID', value: applicationIdentityClientId }
  { name: 'MANAGED_IDENTITY_TENANT', value: subscription().tenantId }
  { name: 'AZURE_AI_SEARCH_ENDPOINT', value: azureAiSearchEndpoint }
  { name: 'AZURE_AI_ENDPOINT', value: azureAiEndpoint }
  { name: 'AZURE_AI_API_VERSION', value: azureAiApiVersion }
  { name: 'CONTENT_UNDERSTANDING_API_KEY', secretRef: 'content-understanding-api-key' }
  { name: 'AZURE_OPENAI_ENDPOINT', value: azureOpenAIEndpoint }
  { name: 'AZURE_OPENAI_API_KEY', secretRef: 'openaikey' }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: applicationInsightsConnectionString }
  { name: 'LOG_LEVEL', value: 'INFO' }
  { name: 'STORAGE_ACCOUNT_NAME', value: storageAccountName }
  { name: 'QUEUE_NAME', value: queueName }
  { name: 'STORAGE_CONTAINER_NAME', value: blobContainerName }
  { name: 'USE_MANAGE_IDENTITY', value: 'true' }
  { name: 'DATABASE_HOST', value: databaseHost }
  { name: 'DATABASE_NAME', value: databaseName }
  { name: 'DATABASE_SCHEMA', value: databaseSchema }
  { name: 'DATABASE_USER', value: applicationIdentityPrincipalId }
  { name: 'DATABASE_ADMIN_USER', value: 'postgres' }
  { name: 'DATABASE_ADMIN_PASSWORD', secretRef: 'pg-admin-password' }
  { name: 'PORT', value: '8080' }
  { name: 'CLIENT_ID', value: clientId }
  { name: 'MANAGED_IDENTITY_CLIENT_ID', value: applicationIdentityClientId }
  { name: 'AZURE_TENANT_ID', value: azureTenantId }
  { name: 'MCP_JWT_VERIFY', value: '0' }
  { name: 'MCP_ALLOW_ANONYMOUS', value: '0' }
]

resource containerApp 'Microsoft.App/containerApps@2024-08-02-preview' = [
  for container in items(containers): {
    name: container.key
    tags: union(tags, { 'azd-service-name': container.key })
    location: location
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
        '${applicationIdentityId}': {}
      }
    }
    properties: {
      managedEnvironmentId: containerAppsEnvironmentId
      workloadProfileName: useWorkloadProfiles ? 'Dedicated' : null
      configuration: {
        secrets: secrets
        registries: [
          { server: acrLoginServer, identity: applicationIdentityId }
        ]
        ingress: {
          external: publicContainerApps
          targetPort: container.value.targetPort
          corsPolicy: { allowedOrigins: ['*'], allowedMethods: ['*'], allowedHeaders: ['*'], exposeHeaders: null, maxAge: 0, allowCredentials: true }
          transport: 'auto'
          traffic: [ { latestRevision: true, weight: 100 } ]
        }
      }
      template: {
        scale: {
          minReplicas: container.value.minReplicas
          maxReplicas: container.value.maxReplicas
          rules: [ { name: 'http-requests', http: { metadata: { concurrentRequests: '10' } } } ]
        }
        containers: [
          {
            name: container.key
            image: empty(container.value.imageWithTag) ? defaultImage : container.value.imageWithTag
            probes: container.value.probes
            env: union(credentialsEnv, [ { name: 'OTEL_RESOURCE_ATTRIBUTES', value: 'service.namespace=${resourceGroup().name},service.instance.id=${projectName}.${container.key}${empty(appInstance) ? '' : '.${appInstance}'}' }, { name: 'OTEL_SERVICE_NAME', value: '${projectName}.${container.key}${empty(appInstance) ? '' : '.${appInstance}'}' }, { name: 'REDIRECT_URI', value: 'https://${container.key}.${containerAppsDefaultDomain}/redirect' }, { name: 'FRONTEND_URL', value: 'https://${container.key}.${containerAppsDefaultDomain}' } ], length(devQueueName) > 0 ? [ { name: 'DEV_QUEUE_NAME', value: devQueueName } ] : [])
            resources: { cpu: json(useWorkloadProfiles ? '2.0' : '1.0'), memory: useWorkloadProfiles ? '4Gi' : '2Gi' }
          }
        ]
      }
    }
  }
]

// Ensure the user-assigned identity has AcrPull on ACR
output MCP_ENDPOINT string = 'https://mcp.${containerAppsDefaultDomain}'
