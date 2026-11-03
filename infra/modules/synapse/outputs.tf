output "name" {
  value = azurerm_synapse_workspace.syn.name
}

output "id" {
  value = azurerm_synapse_workspace.syn.id
}

output "principal_id" {
  value = azurerm_synapse_workspace.syn.identity[0].principal_id
}

# Connect SQL clients and Power BI here (database "ingest", Entra ID auth).
output "serverless_endpoint" {
  value = azurerm_synapse_workspace.syn.connectivity_endpoints["sqlOnDemand"]
}

output "sql_admin_password" {
  value     = random_password.sql_admin.result
  sensitive = true
}
