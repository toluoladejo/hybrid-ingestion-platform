output "name" {
  value = azurerm_storage_account.st.name
}

output "id" {
  value = azurerm_storage_account.st.id
}

output "dfs_endpoint" {
  value = azurerm_storage_account.st.primary_dfs_endpoint
}

# Referencing a container through this map makes callers wait until it exists.
output "container_names" {
  value = { for k, c in azurerm_storage_container.cont : k => c.name }
}
