targetScope = 'subscription'

param acrName string = 'acr${salt}'
@description('Build ID, will be added to the tags of all resources. If not provided, defaults to "local"')
param buildId string = 'local'

@description('The image to use for the frontend container, this will be filled from azd through the parameter file')
param frontendImage string = ''
@description('will also be filled from azd through the parameter file')
param frontendResourceExists bool = false

@description('The image to use for the worker container, this will be filled from azd through the parameter file')
param workerImage string = '' 
param workerResourceExists bool = false

@description('The image to use for the MCP search service container, filled from azd via parameter file')
param mcpImage string = ''
param mcpResourceExists bool = false

// New parameters for worker container app environment variables
@description('API key for Content Understanding Service. Required for worker container app')
@secure()
param contentUnderstandingApiKey string

@description('Azure AI Endpoint URL. Required for worker container app')
param azureAiEndpoint string = ''

@description('Azure AI API Version. Required for worker container app')
param azureAiApiVersion string = '2024-12-01-preview'

param environmentName string
param location string

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

// Removing VPN Gateway Subnet parameter
// @description('VPN Gateway Subnet Address Prefix')
// param vpnGatewaySubnetPrefix string = cidrSubnet(vnetAddressPrefix, 24, 5)

param useManagedIdentity bool = true

@description('Whether to create a private DNS zone for the app')
param createPrivateDnsZone bool = true

@description('Whether to use container app network delegation for the app. Only required if you use workload profiles')
param caenvDelegation bool = false

param publicContainerApp bool = true
param projectName string = 'app'
param postgreName string = 'postgre-${salt}'
param resourceGroupName string = 'rg-${projectName}-${salt}-${environmentName}'

@description('The principal ID of a local user that should have access to Azure Service. Only use it for developer, leave empty otherwise (e.g. use: az ad signed-in-user show --query id --output tsv)')
param localPrincipalId string
var effectiveLocalPrincipalId = localPrincipalId == 'none' ? '' : localPrincipalId

// Removed: localPrincipalName was unused


@description('The salt to use for the resource names. If not provided, a random salt will be generated')
param newSalt string

param salt string =  newSalt == '' ? substring((uniqueString(subscription().id, projectName, environmentName)), 0, 6): newSalt

@description('Set of tags to apply to all resources.')
param tags object = {
  project: projectName
  buildId: buildId
  'azd-env-name': environmentName
}

@description('Whether to use private links for the app')
param usePrivateLinks bool
param useWorkloadProfiles bool = true

// Determine if we should skip deploying container apps when images do not exist yet
var skipContainerApps = !frontendResourceExists || !workerResourceExists || !mcpResourceExists

@description('Whether to deploy the development queue')
param deployDevelopmentQueue bool

param applicationIdentityName string = 'app-identity-${salt}'

resource rg 'Microsoft.Resources/resourceGroups@2020-06-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module networkModule 'networks.bicep' = {
  scope: rg
  name: 'networkModule'
  params: {
    location: location
    tags: tags
    vnetName: virtualNetworkName
    vnetAddressPrefix: vnetAddressPrefix
    containerAppSubnetPrefix: containerAppSubnetPrefix
    resourceSubnetPrefix: resourceSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    bastionAddressPrefix: bastionAddressPrefix
    // vpnGatewaySubnetPrefix: vpnGatewaySubnetPrefix  // Removing parameter
    usePrivateLinks: usePrivateLinks
    caenvDelegation: caenvDelegation
  }
}

@description('The URL of the OpenID Connect issuer, leave empty to disable')
param oidcIssuerUrl string

@description('The client ID of the OpenID Connect application, leave empty to disable (for aca authentication)')
param oidcClientId string

@secure()
@description('The client secret of the OpenID Connect application, leave empty to disable')
param oidcClientSecret string

@description('Client ID for container apps')
param clientId string = '9706eeeb-7caa-4127-a0e9-dc015e6ee44b'

param azureTenantId string = '72f988bf-86f1-41af-91ab-2d7cd011db47'

@secure()
@description('Password for posgres admin user *postgres*')
param pgAdminPassword string


module identity 'identity.bicep' = {
  scope: rg
  name: 'identity'
  params: {
    location: location
    tags: tags
    applicationIdentityName: applicationIdentityName
  }
}

// Modify the postgres module invocation to pass VNET outputs for private endpoints

module postgres 'postgre.bicep' = {
  scope: rg
  name: 'postgres'
  params: {
    postgreName: postgreName
    location: location
    pgAdminPassword: pgAdminPassword
    // New parameters to enable private endpoint wiring when usePrivateLinks is true
    usePrivateLinks: usePrivateLinks
    privateEndpointSubnetId: networkModule.outputs.privateEndpointSubnetId
    vnetId: networkModule.outputs.vnetId
    createPrivateDnsZone: createPrivateDnsZone
    principalId: identity.outputs.principalId
    principalType: 'ServicePrincipal'
    principalName: identity.outputs.principalId
  }
}

module app 'app.bicep' = {
  scope: rg
  name: 'app'
  params: {    
    acrName: acrName
    localPrincipalId: effectiveLocalPrincipalId
    oidcClientId: oidcClientId
    oidcClientSecret: oidcClientSecret
    oidcIssuerUrl: oidcIssuerUrl
    useWorkloadProfiles: useWorkloadProfiles
    // caenvDelegation removed from app module params
    frontendImage: frontendImage
    workerImage: workerImage
    mcpImage: mcpImage
    salt: salt
    tags: tags
    skipContainerApps: skipContainerApps
    publicContainerApps: publicContainerApp
    location: location
    projectName: projectName
    environmentName: environmentName
    usePrivateLinks: usePrivateLinks
    useManagedIdentity: useManagedIdentity
    createPrivateDnsZone: createPrivateDnsZone
    deployDevelopmentQueue: deployDevelopmentQueue
    databaseHost: postgres.outputs.fullyQualifiedDomainName
    databaseName: 'postgres'
    databaseSchema: 'public'
    applicationIdentityPrincipalId: identity.outputs.principalId
    applicationIdentityClientId: identity.outputs.clientId
    applicationIdentityId: identity.outputs.id
    azureTenantId: azureTenantId
    // Newly added network parameters from network module
    vnetId: networkModule.outputs.vnetId
    containerAppSubnetId: networkModule.outputs.containerAppSubnetId
    privateEndpointSubnetId: networkModule.outputs.privateEndpointSubnetId
    resourceSubnetId: networkModule.outputs.resourceSubnetId
    bastionSubnetId: networkModule.outputs.bastionSubnetId
    // New worker container app variables
    contentUnderstandingApiKey: contentUnderstandingApiKey
    azureAiEndpoint: azureAiEndpoint
    azureAiApiVersion: azureAiApiVersion
    clientId: clientId
    pgAdminPassword: pgAdminPassword
  }
}

@description('Enable automatic deletion of a specific Load Balancer rule via Event Grid + Function')
param enableLbRuleCleanup bool = false

@description('Full resource ID of the Load Balancer rule to auto-delete when created')
param lbRuleResourceId string = ''

@description('API version for Microsoft.Network/loadBalancers/loadBalancingRules')
param lbRuleApiVersion string = '2022-09-01'


output POSTGRE_SERVER_NAME string = postgres.outputs.fullyQualifiedDomainName
output DATABASE_HOST string = postgres.outputs.fullyQualifiedDomainName
output DATABASE_NAME string = 'postgres'
output DATABASE_SCHEMA string = 'public'

output APPLICATIONINSIGHTS_CONNECTION_STRING string = app.outputs.APPLICATIONINSIGHTS_CONNECTION_STRING
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = app.outputs.AZURE_CONTAINER_REGISTRY_ENDPOINT
output AZURE_ENV_NAME string = environmentName
output AZURE_OPENAI_API_KEY string = app.outputs.AZURE_OPENAI_API_KEY
output AZURE_OPENAI_API_VERSION string = app.outputs.AZURE_OPENAI_API_VERSION
output AZURE_OPENAI_ENDPOINT string = app.outputs.AZURE_OPENAI_ENDPOINT
output AZURE_OPENAI_DEPLOYMENT_VERSION string = app.outputs.AZURE_OPENAI_DEPLOYMENT_VERSION
output AZURE_OPENAI_DEPLOYMENT_NAME string = app.outputs.AZURE_OPENAI_DEPLOYMENT_NAME
output AZURE_STORAGE_ACCOUNT string = app.outputs.AZURE_STORAGE_ACCOUNT
output AZURE_RESOURCE_GROUP string = resourceGroupName
output LOG_LEVEL string = app.outputs.LOG_LEVEL
output QUEUE_NAME string = deployDevelopmentQueue ? app.outputs.DEV_QUEUE_NAME : app.outputs.QUEUE_NAME
output OTEL_SERVICE_NAME string = projectName
output OTEL_RESOURCE_ATTRIBUTES string = 'service.namespace=${resourceGroupName},service.instance.id=${projectName}-local'
output STORAGE_CONTAINER_NAME string = app.outputs.STORAGE_CONTAINER_NAME
output STORAGE_ACCOUNT_NAME string = app.outputs.STORAGE_ACCOUNT_NAME
output PRINCIPAL_ID string = identity.outputs.principalId
output AZURE_AI_ENDPOINT string = app.outputs.AZURE_AI_ENDPOINT
output AZURE_AI_API_VERSION string = app.outputs.AZURE_AI_API_VERSION
output AZURE_AI_SEARCH_ENDPOINT string = app.outputs.AZURE_AI_SEARCH_ENDPOINT
output MCP_ENDPOINT string = app.outputs.MCP_ENDPOINT
