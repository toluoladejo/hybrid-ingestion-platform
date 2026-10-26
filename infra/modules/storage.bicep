param env string
param location string
param tags object
param workspaceId string
param containers array = ['landing', 'raw', 'curated', 'quarantine', 'archive']

resource st 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: take('stingest${env}${uniqueString(resourceGroup().id)}', 24)
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    isHnsEnabled: true // ADLS Gen2
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

resource blob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: st
  name: 'default'
}

resource cont 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [for c in containers: {
  parent: blob
  name: c
  properties: { publicAccess: 'None' }
}]

// Blob write/delete logs -> StorageBlobLogs table (used by the week 5 alerts)
resource diag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: blob
  properties: {
    workspaceId: workspaceId
    logs: [
      { category: 'StorageWrite', enabled: true }
      { category: 'StorageDelete', enabled: true }
    ]
  }
}

output name string = st.name
output id string = st.id
