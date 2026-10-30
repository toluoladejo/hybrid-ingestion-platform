resource "azurerm_storage_account" "st" {
  name                            = substr("stingest${var.env}${var.suffix}", 0, 24)
  resource_group_name             = var.resource_group_name
  location                        = var.location
  tags                            = var.tags
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true # ADLS Gen2
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
}

resource "azurerm_storage_container" "cont" {
  for_each              = toset(var.containers)
  name                  = each.key
  storage_account_id    = azurerm_storage_account.st.id
  container_access_type = "private"
}

# Blob write/delete logs -> StorageBlobLogs table (used by the week 5 alerts)
resource "azurerm_monitor_diagnostic_setting" "diag" {
  name                       = "to-log-analytics"
  target_resource_id         = "${azurerm_storage_account.st.id}/blobServices/default"
  log_analytics_workspace_id = var.workspace_id

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }
}
