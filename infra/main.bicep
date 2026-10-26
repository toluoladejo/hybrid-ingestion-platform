// Hybrid File Ingestion Platform: base resources for one environment.
@allowed(['dev', 'prod'])
param env string
param location string = resourceGroup().location
param tags object = {
  project: 'hybrid-ingestion-platform'
  env: env
}

module logs 'modules/loganalytics.bicep' = {
  name: 'logs'
  params: { env: env, location: location, tags: tags }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: { env: env, location: location, tags: tags, workspaceId: logs.outputs.id }
}

module vault 'modules/keyvault.bicep' = {
  name: 'vault'
  params: { env: env, location: location, tags: tags }
}

output storageAccountName string = storage.outputs.name
output keyVaultName string = vault.outputs.name
output workspaceName string = logs.outputs.name
