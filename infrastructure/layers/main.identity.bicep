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

@description('Azure region for resources')
param location string = resourceGroup().location

// Bicep: parameter defaults can reference only other parameters; define salt as a param with a computed default
param salt string = substring(uniqueString(subscription().id, projectName, environmentName), 0, 6)

@description('User-assigned managed identity name')
param applicationIdentityName string = 'app-identity-${salt}'

module identity '../identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    tags: tags
    applicationIdentityName: applicationIdentityName
  }
}

output principalId string = identity.outputs.principalId
output clientId string = identity.outputs.clientId
output id string = identity.outputs.id
