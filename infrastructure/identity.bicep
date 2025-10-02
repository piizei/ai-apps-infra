param location string
param tags object
param applicationIdentityName string

resource applicationIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: applicationIdentityName
  location: location
  tags: tags
}

output principalId string = applicationIdentity.properties.principalId
output clientId string = applicationIdentity.properties.clientId
output id string = applicationIdentity.id
