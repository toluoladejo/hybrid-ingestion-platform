output "storage_account_name" {
  value = module.storage.name
}

output "key_vault_name" {
  value = module.vault.name
}

output "workspace_name" {
  value = module.logs.name
}
