# Week 5: Synapse workspace over the lake. Its pipeline (pl_curate) turns validated CSVs in
# raw/orders/ into Parquet in curated/orders/; serverless SQL exposes them as dbo.orders.
#
# Terraform owns the workspace, its identity, firewall, lake roles, Git link and Spark pool.
# Pipelines, datasets, linked services and triggers are Synapse artifacts: they live as JSON
# under synapse/ in the repo and are published from Synapse Studio, not from Terraform.

# The workspace requires a SQL admin login even though we only use Entra ID day to day.
# Generated here and kept only in (remote, RBAC-protected) state; read it with
# `terraform output -raw synapse_sql_admin_password` if you ever need it.
resource "random_password" "sql_admin" {
  length      = 32
  special     = true
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
  min_special = 1
  # Characters SQL logins and shells both accept.
  override_special = "!#%*-_=+"
}

resource "azurerm_synapse_workspace" "syn" {
  name                = "syn-ingest-${var.env}-${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  # Primary storage: the "synapse" container on the lake. It must exist first.
  storage_data_lake_gen2_filesystem_id = var.storage_filesystem_id

  sql_administrator_login          = "sqladminuser"
  sql_administrator_login_password = random_password.sql_admin.result

  managed_resource_group_name   = "rg-ingest-${var.env}-synapse-managed"
  public_network_access_enabled = true
  # Managed VNet is fixed at creation. Changing it later means recreating the workspace.
  managed_virtual_network_enabled = false

  identity {
    type = "SystemAssigned"
  }

  # Git integration in dev only: prod only ever receives published artifacts (week 7).
  dynamic "github_repo" {
    for_each = var.env == "dev" && var.github_owner != "" ? [1] : []
    content {
      account_name    = var.github_owner
      repository_name = var.github_repo
      branch_name     = var.collaboration_branch
      root_folder     = "/synapse"
    }
  }
}

# ---------- Firewall ----------

# 0.0.0.0 is the special "Allow Azure services" rule (pipelines, Power BI service).
resource "azurerm_synapse_firewall_rule" "azure" {
  name                 = "AllowAllWindowsAzureIps"
  synapse_workspace_id = azurerm_synapse_workspace.syn.id
  start_ip_address     = "0.0.0.0"
  end_ip_address       = "0.0.0.0"
}

# Your own IP, for Synapse Studio and SQL clients.
resource "azurerm_synapse_firewall_rule" "me" {
  count                = var.allowed_ip != "" ? 1 : 0
  name                 = "allow-my-ip"
  synapse_workspace_id = azurerm_synapse_workspace.syn.id
  start_ip_address     = var.allowed_ip
  end_ip_address       = var.allowed_ip
}

# ---------- Lake access (storage data plane) ----------

# The workspace identity reads and writes the lake (pipelines, serverless credential).
resource "azurerm_role_assignment" "syn_lake" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_synapse_workspace.syn.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# You read the lake with your own identity when exploring with OPENROWSET (Entra passthrough).
resource "azurerm_role_assignment" "reader_lake" {
  count                = var.reader_object_id != "" ? 1 : 0
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = var.reader_object_id
  principal_type       = "User"
}

# ---------- Optional Spark pool (Lab 6) ----------

# Costs nothing until a session starts; pauses itself 15 minutes after the last activity.
resource "azurerm_synapse_spark_pool" "small" {
  count                = var.deploy_spark ? 1 : 0
  name                 = "sparksmall"
  synapse_workspace_id = azurerm_synapse_workspace.syn.id
  spark_version        = "3.4"
  node_size_family     = "MemoryOptimized"
  node_size            = "Small"
  node_count           = 3
  tags                 = var.tags

  auto_pause {
    delay_in_minutes = 15
  }
}
