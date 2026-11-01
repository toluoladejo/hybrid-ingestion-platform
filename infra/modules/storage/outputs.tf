output "name" {
  value = azurerm_storage_account.st.name
}

output "id" {
  value = azurerm_storage_account.st.id
}

output "dfs_endpoint" {
  value = azurerm_storage_account.st.primary_dfs_endpoint
}
