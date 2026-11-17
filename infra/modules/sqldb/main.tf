# Watermark test (optional, var.deploy_watermark_test): the Azure SQL Database used by the
# synapse/ replica of the "RTO Watermark Incremental" pipeline. It plays two roles: the
# simulated source system (schema src) and the control database (schema etl).
# sql/watermark/ creates both.
#
# Entra-only authentication, so no SQL logins or passwords. You are the admin
# (admin_object_id); the Synapse workspace identity gets access from
# sql/watermark/04_permissions.sql.

data "azurerm_client_config" "current" {}

resource "azurerm_mssql_server" "sql" {
  name                          = "sql-wm-${var.env}-${var.suffix}"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  tags                          = var.tags
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true

  azuread_administrator {
    login_username              = var.admin_login
    object_id                   = var.admin_object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }
}

# Basic (5 DTU, 2 GB) is a few dollars a month and enough for the 200k-row test table.
resource "azurerm_mssql_database" "db" {
  name        = "rto_watermark_test"
  server_id   = azurerm_mssql_server.sql.id
  sku_name    = "Basic"
  max_size_gb = 2
  tags        = var.tags
}

# ---------- Firewall ----------

# 0.0.0.0 is the special "Allow Azure services" rule: Synapse pipelines and Spark reach the DB through it.
resource "azurerm_mssql_firewall_rule" "azure" {
  name             = "AllowAllWindowsAzureIps"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Your own IP, for running sql/watermark/*.sql.
resource "azurerm_mssql_firewall_rule" "me" {
  count            = var.allowed_ip != "" ? 1 : 0
  name             = "allow-my-ip"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = var.allowed_ip
  end_ip_address   = var.allowed_ip
}
