param env string
param location string
param tags object

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: take('kv-ingest-${env}-${uniqueString(resourceGroup().id)}', 24)
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

output name string = kv.name
output id string = kv.id
