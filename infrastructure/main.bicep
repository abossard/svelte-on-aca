@description('A randrom unique string to salt all names.')
param salt string = substring(uniqueString(resourceGroup().id), 0, 5)

@description('The name of the project. Used to generate names.')
param projectName string = 'svelteonaca'

param imageWithTag string = 'svelteonaca:latest'

@description('The location to deploy to.')
param location string = resourceGroup().location

@description('Should it deploy the container app?')
param deployApps bool = true

@description('Build container app image?')
param doBuildContainerAppImage bool = true

// some default names
param containerAppName string = 'ca-${projectName}-${salt}'
param containerRegistryName string = 'acr${salt}'
param containerAppEnvName string = 'caenvvnet-${projectName}-${salt}'
param containerAppLogAnalyticsName string = 'calog-${projectName}-${salt}'
param storageAccountName string = 'castrg${salt}'
param blobContainerName string = 'parquet${salt}'
param githubApiRepositoryUrl string = 'https://github.com/abossard/svelte-on-aca.git'
param githubApiRepositoryBranch string = 'main'

var acrPullRole = resourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var storageRole = resourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

module buildContainerImage 'build_image.bicep' = {
  name: 'build_image'
  params: {
    acrName: acr.name
    doBuildContainerAppImage: doBuildContainerAppImage
    location: location
    imageWithTag: imageWithTag
    githubApiRepositoryUrl: githubApiRepositoryUrl
    githubApiRepositoryBranch: githubApiRepositoryBranch
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: containerRegistryName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    adminUserEnabled: true
  }
}

resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${containerAppName}'
  location: location
}

resource uaiRbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, uai.id, acrPullRole)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRole
    principalId: uai.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource uaiRbacStorage 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, uai.id, storageRole)
  scope: sa
  properties: {
    roleDefinitionId: storageRole
    principalId: uai.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource sa 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    isHnsEnabled: true
    accessTier: 'Hot'
  }
}
resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: sa
  name: 'default'
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: blobContainerName
  parent: blobServices
  properties: {}
}

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: containerAppLogAnalyticsName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: containerAppEnvName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

resource containerApp 'Microsoft.App/containerApps@2023-05-01' = if (deployApps) {
  name: containerAppName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uai.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      secrets: [
        {
          name: 'myregistrypassword'
          value: acr.listCredentials().passwords[0].value
        }
        {
          name: 'storageaccountkey'
          value: sa.listKeys().keys[0].value
        }
      ]
      registries: [
        {
          server: acr.properties.loginServer
          username: acr.listCredentials().username
          passwordSecretRef: 'myregistrypassword'
        }
      ]
      ingress: {
        external: true
        targetPort: 3000
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
      containers: [
        {
          name: containerAppName
          image: '${acr.properties.loginServer}/${buildContainerImage.outputs.imageWithTag}'
          env: [
            {
              name: 'OMIT_STARTUP_CHECK'
              value: 'true'
            }
            {
              name: 'STORAGE_ACCOUNT_KEY'
              secretRef: 'storageaccountkey'
            }
            {
              name: 'AZURE_CLIENT_ID'
              value: uai.properties.clientId
            }
            {
              name: 'STORAGE_ACCOUNT_NAME'
              value: sa.name
            }
            {
              name: 'STORAGE_CONTAINER_NAME'
              value: blobContainer.name
            }
          ]
          resources: {
            cpu: json('1')
            memory: '2Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 10
        rules: [
          {
            name: 'http-requests'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
}

output containerAppFQDN string = (deployApps) ? containerApp.properties.configuration.ingress.fqdn : 'https://<containerAppFQDN>'
output containerAppStaticIP string = containerAppEnv.properties.staticIp
