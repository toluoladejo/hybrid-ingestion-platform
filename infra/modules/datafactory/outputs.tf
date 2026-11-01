output "name" {
  value = azurerm_data_factory.adf.name
}

output "id" {
  value = azurerm_data_factory.adf.id
}

output "principal_id" {
  value = azurerm_data_factory.adf.identity[0].principal_id
}

output "shir_name" {
  value = azurerm_data_factory_integration_runtime_self_hosted.shir.name
}

# Paste into the SHIR Configuration Manager on the on-prem machine to register it.
output "shir_auth_key" {
  value     = azurerm_data_factory_integration_runtime_self_hosted.shir.primary_authorization_key
  sensitive = true
}
