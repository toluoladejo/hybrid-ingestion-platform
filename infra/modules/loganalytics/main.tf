resource "azurerm_log_analytics_workspace" "law" {
  name                = "log-ingest-${var.env}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 1 # keep the lab cheap
}
