# Hybrid File Ingestion Platform: base resources for one environment.

# Created by scripts/bootstrap.sh, so the pipeline only needs Contributor on it.
data "azurerm_resource_group" "rg" {
  name = "rg-ingest-${var.env}"
}

locals {
  location = coalesce(var.location, data.azurerm_resource_group.rg.location)
  # Stable per-resource-group suffix for globally unique names (like Bicep's uniqueString).
  suffix = substr(sha1(data.azurerm_resource_group.rg.id), 0, 13)
  tags = merge({
    project = "hybrid-ingestion-platform"
    env     = var.env
  }, var.tags)
}

module "logs" {
  source              = "./modules/loganalytics"
  env                 = var.env
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = local.location
  tags                = local.tags
}

module "storage" {
  source              = "./modules/storage"
  env                 = var.env
  suffix              = local.suffix
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = local.location
  tags                = local.tags
  workspace_id        = module.logs.id
}

module "vault" {
  source              = "./modules/keyvault"
  env                 = var.env
  suffix              = local.suffix
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = local.location
  tags                = local.tags
}

module "adf" {
  source               = "./modules/datafactory"
  env                  = var.env
  suffix               = local.suffix
  resource_group_name  = data.azurerm_resource_group.rg.name
  location             = local.location
  tags                 = local.tags
  storage_account_id   = module.storage.id
  storage_dfs_endpoint = module.storage.dfs_endpoint
  key_vault_id         = module.vault.id
  outbox_path          = var.outbox_path
  outbox_user          = var.outbox_user
}

module "synapse" {
  source                = "./modules/synapse"
  env                   = var.env
  suffix                = local.suffix
  resource_group_name   = data.azurerm_resource_group.rg.name
  location              = local.location
  tags                  = local.tags
  storage_account_id    = module.storage.id
  storage_filesystem_id = "${module.storage.dfs_endpoint}${module.storage.container_names["synapse"]}"
  github_owner          = var.github_owner
  allowed_ip            = var.allowed_ip
  reader_object_id      = var.reader_object_id
  deploy_spark          = var.deploy_spark
}
