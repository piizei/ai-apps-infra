param containers object
param oidcIssuerUrl string
param oidcClientId string
param tokenStoreSasSecretName string

resource authConfigs 'Microsoft.App/containerApps/authConfigs@2024-10-02-preview' = [
  for container in items(containers): {
    name: '${container.key}/current'
    properties: {
      platform: {
        enabled: true
      }
      globalValidation: {
        unauthenticatedClientAction: 'RedirectToLoginPage'
        redirectToProvider: 'azureactivedirectory'
      }
      identityProviders: {
        azureActiveDirectory: {
          registration: {
            openIdIssuer: oidcIssuerUrl
            clientId: oidcClientId
            clientSecretSettingName: 'microsoft-provider-authentication-secret'
          }
          validation: {
            allowedAudiences: [
              'api://${oidcClientId}'
            ]
          }
          isAutoProvisioned: false
        }
        customOpenIdConnectProviders: {}
      }
      login: {
        preserveUrlFragmentsForLogins: false
        allowedExternalRedirectUrls: []
        tokenStore: {
          azureBlobStorage: {
            sasUrlSettingName: tokenStoreSasSecretName
          }
          enabled: true
          tokenRefreshExtensionHours: 72
        }
      }
    }
  }
]
