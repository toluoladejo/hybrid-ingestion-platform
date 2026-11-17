output "storage_account_name" {
  value = module.storage.name
}

output "key_vault_name" {
  value = module.vault.name
}

output "workspace_name" {
  value = module.logs.name
}

output "data_factory_name" {
  value = module.adf.name
}

output "curate_pipeline_name" {
  value = module.adf.curate_pipeline_name
}

output "shir_auth_key" {
  value     = module.adf.shir_auth_key
  sensitive = true
}

output "synapse_workspace_name" {
  value = module.synapse.name
}

output "synapse_serverless_endpoint" {
  value = module.synapse.serverless_endpoint
}

output "synapse_sql_admin_password" {
  value     = module.synapse.sql_admin_password
  sensitive = true
}

# Watermark test (null unless deploy_watermark_test = true). Read by scripts/configure-watermark.sh.
output "watermark_sql_server_name" {
  value = one(module.watermark_sql[*].server_name)
}

output "watermark_sql_database" {
  value = one(module.watermark_sql[*].database_name)
}
