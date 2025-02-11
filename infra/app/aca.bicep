param name string
param location string = resourceGroup().location
param tags object = {}

param identityName string
param containerAppsEnvironmentName string
param containerRegistryName string
param serviceName string = 'aca'
param exists bool
param openAiDeploymentName string
param openAiEndpoint string
param openAiApiVersion string
@secure()
param openAiKey string = ''

module acaIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.0' = {
  name: 'user-assigned-identity'
  params: {
    name: identityName
    location: location
    tags: tags
  }
}

var env = [
  {
    name: 'AZURE_OPENAI_DEPLOYMENT'
    value: openAiDeploymentName
  }
  {
    name: 'AZURE_OPENAI_ENDPOINT'
    value: openAiEndpoint
  }
  {
    name: 'AZURE_OPENAI_API_VERSION'
    value: openAiApiVersion
  }
  {
    name: 'RUNNING_IN_PRODUCTION'
    value: 'true'
  }
  {
    // DefaultAzureCredential will look for an environment variable with this name:
    name: 'AZURE_CLIENT_ID'
    value: acaIdentity.outputs.clientId
  }
]

var envWithSecret = !empty(openAiKey) ? union(env, [
  {
    name: 'AZURE_OPENAI_KEY'
    secretRef: 'azure-openai-key'
  }
]) : env

var secrets = !empty(openAiKey) ? {
  'azure-openai-key': openAiKey
} : {}

var imageName = exists ? existingApp.properties.template.containers[0].name : 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2023-05-01' existing = {
  name: containerAppsEnvironmentName
}

resource existingApp 'Microsoft.App/containerApps@2023-05-02-preview' existing = if (exists) {
  name: name
}

module containerRegistryAccess '../core/security/registry-access.bicep' = {
  name: '${deployment().name}-registry-access'
  params: {
    containerRegistryName: containerRegistryName
    principalId: acaIdentity.outputs.principalId
  }
}

//resource app 'Microsoft.App/containerApps@2023-05-02-preview' = {
module app 'br/public:avm/res/app/container-app:0.13.0' = {
  name: '${deployment().name}-update'
  // It is critical that the identity is granted ACR pull access before the app is created
  // otherwise the container app will throw a provision error
  // This also forces us to use an user assigned managed identity since there would no way to 
  // provide the system assigned identity with the ACR pull access before the app is created
  dependsOn: [containerRegistryAccess]
  params: {
    name: name
    location: location
    tags: union(tags, { 'azd-service-name': serviceName })
    managedIdentities: {userAssignedResourceIds: ['${acaIdentity.outputs.resourceId}']}
    environmentResourceId: containerAppsEnvironment.id
    ingressExternal: true
    ingressTargetPort: 8080
    ingressTransport: 'auto'
    corsPolicy: {
      allowedOrigins: ['https://portal.azure.com', 'https://ms.portal.azure.com']
    }
    secrets: [
      for secret in items(secrets): {
        name: secret.key
        value: secret.value
      }
    ]
    registries: [
      {
        server: '${containerRegistryName}.azurecr.io'
        identity: acaIdentity.outputs.resourceId
      }
    ]
    containers: [
      {
        image: imageName
        name: 'main'
        env: envWithSecret
        resources: {
          cpu: json('0.5')
          memory: '1.0Gi'
        }
      }
    ]
    scaleMinReplicas: 1
    scaleMaxReplicas: 10
  }
}

output SERVICE_ACA_IDENTITY_PRINCIPAL_ID string = acaIdentity.outputs.principalId
output SERVICE_ACA_NAME string = app.outputs.name
output SERVICE_ACA_URI string = app.outputs.fqdn
output SERVICE_ACA_IMAGE_NAME string = imageName
