targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name which is used to generate a short unique hash for each resource')
param name string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('Id of the user or app to assign application roles')
param principalId string = ''

@description('Flag to decide where to create OpenAI role for current user')
param createRoleForUser bool = true

param acaExists bool = false

// Parameters for the Azure OpenAI resource:
param openAiResourceName string = ''
param openAiResourceGroupName string = ''
@minLength(1)
@description('Location for the OpenAI resource')
// Look for the desired model in availability table. Default model is gpt-4o-mini:
// https://learn.microsoft.com/azure/ai-services/openai/concepts/models#standard-deployment-model-availability
@allowed([
  'eastus'
  'eastus2'
  'northcentralus'
  'southcentralus'
  'swedencentral'
  'westus'
  'westus3'
])
@metadata({
  azd: {
    type: 'location'
  }
})
param openAiResourceLocation string
param openAiSkuName string = ''
param openAiApiVersion string // Used by the SDK in the app code
param disableKeyBasedAuth bool = true

// Parameters for the specific Azure OpenAI deployment:
param openAiDeploymentName string // Set in main.parameters.json
param openAiModelName string // Set in main.parameters.json
param openAiModelVersion string // Set in main.parameters.json
param openAiDeploymentCapacity int // Set in main.parameters.json
param openAiDeploymentSkuName string // Set in main.parameters.json

@description('Flag to decide whether to create Azure OpenAI instance or not')
param createAzureOpenAi bool // Set in main.parameters.json

@description('Azure OpenAI key to use for authentication. If not provided, managed identity will be used (and is preferred)')
@secure()
param openAiKey string = ''

@description('Azure OpenAI endpoint to use. If provided, no Azure OpenAI instance will be created.')
param openAiEndpoint string = ''


var resourceToken = toLower(uniqueString(subscription().id, name, location))
var tags = { 'azd-env-name': name }

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: '${name}-rg'
  location: location
  tags: tags
}

resource openAiResourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' existing = if (!empty(openAiResourceGroupName)) {
  name: !empty(openAiResourceGroupName) ? openAiResourceGroupName : resourceGroup.name
}

var prefix = toLower('${name}-${resourceToken}')

module openAi 'br/public:avm/res/cognitive-services/account:0.9.2' = if (createAzureOpenAi) {
  name: 'openai'
  scope: openAiResourceGroup
  params: {
    // Required parameters
    kind: 'OpenAI'
    name: !empty(openAiResourceName) ? openAiResourceName : '${resourceToken}-cog'
    disableLocalAuth: disableKeyBasedAuth
    sku: !empty(openAiSkuName) ? openAiSkuName : 'S0'
    customSubDomainName: !empty(openAiResourceName) ? openAiResourceName : '${resourceToken}-cog'
    deployments: [
      {
        name: openAiDeploymentName
        model: {
          format: 'OpenAI'
          name: openAiModelName
          version: openAiModelVersion
        }
        sku: {
          name: openAiDeploymentSkuName
          capacity: openAiDeploymentCapacity
        }
      }
    ]
    location: location
    publicNetworkAccess: 'Enabled'
  }
}

module logAnalyticsWorkspace 'br/public:avm/res/operational-insights/workspace:0.10.0' = {
  name: 'loganalytics'
  scope: resourceGroup
  params: {
    name: '${prefix}-loganalytics'
    location: location
    tags: tags
  }
}

// Container apps host (including container registry)
module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.9.0' = {
  scope: resourceGroup
  name: 'app-container-apps-environment'
  params: {
    name: '${prefix}-containerapps-env'
    location: location
    tags: tags
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
    zoneRedundant: false
  }
}

module containerRegistry 'br/public:avm/res/container-registry/registry:0.8.5' = {
  scope: resourceGroup
  name: 'app-container-registry'
  params: {
    name: '${replace(prefix, '-', '')}registry'
    location: location
    tags: tags
    zoneRedundancy: 'Disabled'
    exportPolicyStatus: 'enabled'
  }
}

// Container app frontend
module aca 'app/aca.bicep' = {
  name: 'aca'
  scope: resourceGroup
  params: {
    name: replace('${take(prefix,19)}-ca', '--', '-')
    location: location
    tags: tags
    identityName: '${prefix}-id-aca'
    containerAppsEnvironmentName: containerAppsEnvironment.outputs.name
    containerRegistryName: containerRegistry.outputs.name
    openAiDeploymentName: openAiDeploymentName
    openAiEndpoint: createAzureOpenAi ? openAi.outputs.endpoint : openAiEndpoint
    openAiApiVersion: openAiApiVersion
    openAiKey: openAiKey
    exists: acaExists
  }
}

module openAiRoleUser 'core/security/role.bicep' = if (createRoleForUser && createAzureOpenAi) {
  scope: openAiResourceGroup
  name: 'openai-role-user'
  params: {
    principalId: principalId
    roleDefinitionId: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
    principalType: 'User'
  }
}


module openAiRoleBackend 'core/security/role.bicep' = if (createAzureOpenAi) {
  scope: openAiResourceGroup
  name: 'openai-role-backend'
  params: {
    principalId: aca.outputs.SERVICE_ACA_IDENTITY_PRINCIPAL_ID
    roleDefinitionId: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
    principalType: 'ServicePrincipal'
  }
}

output AZURE_LOCATION string = location

output AZURE_OPENAI_DEPLOYMENT string = openAiDeploymentName
output AZURE_OPENAI_RESOURCE_LOCATION string = openAiResourceLocation
output AZURE_OPENAI_API_VERSION string = openAiApiVersion
output AZURE_OPENAI_ENDPOINT string = createAzureOpenAi ? openAi.outputs.endpoint : openAiEndpoint

output SERVICE_ACA_IDENTITY_PRINCIPAL_ID string = aca.outputs.SERVICE_ACA_IDENTITY_PRINCIPAL_ID
output SERVICE_ACA_NAME string = aca.outputs.SERVICE_ACA_NAME
output SERVICE_ACA_URI string = aca.outputs.SERVICE_ACA_URI
output SERVICE_ACA_IMAGE_NAME string = aca.outputs.SERVICE_ACA_IMAGE_NAME

output AZURE_CONTAINER_ENVIRONMENT_NAME string = containerAppsEnvironment.outputs.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.outputs.loginServer
output AZURE_CONTAINER_REGISTRY_NAME string = containerRegistry.outputs.name
