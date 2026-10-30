data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "kv" {
  name                       = substr("kv-ingest-${var.env}-${var.suffix}", 0, 24)
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tags                       = var.tags
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7 # soft delete is always on
}
