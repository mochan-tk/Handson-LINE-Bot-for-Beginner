// playground:https://bicepdemo.z22.web.core.windows.net/
param location string = resourceGroup().location
param random string
param secret string
param access string
param containerRegistryName string
param containerVer string
param containerAppsName string = 'capp-${toLower(random)}'

var appInsightsName = 'AppInsights'
var storageAccountName = 'fnstor${toLower(substring(replace(random, '-', ''), 0, 18))}'
var containerName = 'files'

param accountName string = 'cosmos-${toLower(random)}'
var databaseName = 'SimpleDB'
var cosmosContainerName = 'Accounts'

@description('That name is the name of our application. It has to be unique.Type a name followed by your resource group name. (<name>-<resourceGroupName>)')

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    supportsHttpsTrafficOnly: true
    encryption: {
      services: {
        file: {
          keyType: 'Account'
          enabled: true
        }
        blob: {
          keyType: 'Account'
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
    accessTier: 'Hot'
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: '${storageAccount.name}/default/${containerName}'
  properties: {
    publicAccess:'Container'
  }
}

// https://docs.microsoft.com/en-us/azure/cosmos-db/sql/manage-with-bicep
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2022-08-15' = {
  name: toLower(accountName)
  location: location
  kind: 'GlobalDocumentDB'
  properties: {
    //enableFreeTier: true
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    capabilities: [
      {
        name: 'EnableServerless'
      }
    ]
  }
}

resource cosmosDB 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2022-08-15' = {
  parent: cosmosAccount
  name: databaseName
  properties: {
    resource: {
      id: databaseName
    }
  }
}

resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2022-08-15' = {
  parent: cosmosDB
  name: cosmosContainerName
  properties: {
    resource: {
      id: cosmosContainerName
      partitionKey: {
        paths: [
          '/partitionKey'
        ]
        kind: 'Hash'
      }
     }
     options:{}
    }
  }

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2022-12-01' existing = {
  name: containerRegistryName
}

var containerImageName = 'linebot/aca'
var containerImageTag = containerVer

// https://github.com/Azure/azure-quickstart-templates/blob/master/quickstarts/microsoft.app/container-app-scale-http/main.bicep
@description('Specifies the name of the log analytics workspace.')
param containerAppLogAnalyticsName string = 'log-${uniqueString(resourceGroup().id)}'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: containerAppLogAnalyticsName
  location: location
  properties: any({
    retentionInDays: 30
    features: {
      searchVersion: 1
    }
    sku: {
      name: 'PerGB2018'
    }
  })
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId:logAnalytics.id
  }
}

/*
resource managedEnvironments 'Microsoft.App/managedEnvironments@2022-10-01' = {
  name: 'managedEnv'
  location: location
  properties: {
    daprAIInstrumentationKey:appInsights.properties.InstrumentationKey
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
  sku: {
    name: 'Consumption'
  }
}
*/

// https://learn.microsoft.com/ja-jp/dotnet/orleans/deployment/deploy-to-azure-container-apps
// https://github.com/microsoft/azure-container-apps/blob/main/docs/templates/bicep/main.bicep
resource containerApps 'Microsoft.App/containerApps@2022-10-01' = {
  name: containerAppsName
  location: location
  properties: {
    managedEnvironmentId: '/subscriptions/62f5527b-7ac9-4999-bb23-6a253ad279ea/resourceGroups/20220615LineBot1/providers/Microsoft.App/managedEnvironments/managedEnv'
    configuration: {
      registries: [
        {
          server: containerRegistry.properties.loginServer
          username: containerRegistry.listCredentials().username
          passwordSecretRef: 'reg-pswd-d6696fb9-a98d'
        }
      ]
      secrets: [
        {
          name: 'reg-pswd-d6696fb9-a98d'
          value: containerRegistry.listCredentials().passwords[0].value
        }
      ]
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        transport: 'auto'
        targetPort: 3000
      }
    }
    template: {
      containers: [
        {
          name: 'line-bot-container-apps'
          image: '${containerRegistry.name}.azurecr.io/${containerImageName}:${containerImageTag}'
          command: []
          resources: {
            cpu: json('0.5')
            memory: '1Gi'

          }
          env: [
            {
              name: 'CHANNEL_SECRET'
              value: secret
            }
            {
              name: 'CHANNEL_ACCESS_TOKEN'
              value: access
            }
            {
              name: 'STORAGE_CONNECTION_STRING'
              value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${listKeys(storageAccount.id, storageAccount.apiVersion).keys[0].value}'
            }
            {
              name: 'COSMOSDB_ACCOUNT'
              value: cosmosAccount.properties.documentEndpoint
            }
            {
              name: 'COSMOSDB_KEY'
              value: cosmosAccount.listKeys().primaryMasterKey
            }
            {
              name: 'COSMOSDB_DATABASENAME'
              value: databaseName
            }
            {
              name: 'COSMOSDB_CONTAINERNAME'
              value: cosmosContainerName
            }
            {
              name: 'COSMOSDB_CONNECTION_STRING'
              value: 'AccountEndpoint=${cosmosAccount.properties.documentEndpoint};AccountKey=${cosmosAccount.listKeys().primaryMasterKey};'
            }
          ]
        }
      ]
      scale: {
        maxReplicas: 1
        minReplicas: 1
      }
    }
  }
}

output acaUrl string = 'https://${containerApps.properties.configuration.ingress.fqdn}'
