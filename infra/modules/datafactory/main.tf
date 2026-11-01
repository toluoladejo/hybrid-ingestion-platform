# Data Factory that pulls C:\outbox\*.csv from an on-prem machine (via a self-hosted
# integration runtime) into the landing container, then archives the source file.

resource "azurerm_data_factory" "adf" {
  name                = "adf-ingest-${var.env}-${var.suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

# The factory's own identity reads/writes the lake and reads secrets: no keys anywhere.
# Creating these needs "Role Based Access Control Administrator" on the resource group.
resource "azurerm_role_assignment" "adf_lake" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_data_factory.adf.identity[0].principal_id
}

resource "azurerm_role_assignment" "adf_kv" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_data_factory.adf.identity[0].principal_id
}

resource "azurerm_data_factory_integration_runtime_self_hosted" "shir" {
  name            = "shir-onprem"
  data_factory_id = azurerm_data_factory.adf.id
}

# ---------- Linked services ----------

resource "azurerm_data_factory_linked_service_key_vault" "kv" {
  name            = "ls_keyvault"
  data_factory_id = azurerm_data_factory.adf.id
  key_vault_id    = var.key_vault_id
}

resource "azurerm_data_factory_linked_service_data_lake_storage_gen2" "lake" {
  name                 = "ls_datalake"
  data_factory_id      = azurerm_data_factory.adf.id
  url                  = var.storage_dfs_endpoint
  use_managed_identity = true
}

resource "azurerm_data_factory_linked_custom_service" "outbox" {
  name            = "ls_outbox"
  data_factory_id = azurerm_data_factory.adf.id
  type            = "FileServer"

  integration_runtime {
    name = azurerm_data_factory_integration_runtime_self_hosted.shir.name
  }

  type_properties_json = jsonencode({
    host   = var.outbox_path
    userId = var.outbox_user
    # Pulled from Key Vault at run time; never stored in ADF or in Terraform state.
    password = {
      type       = "AzureKeyVaultSecret"
      secretName = var.outbox_password_secret_name
      store = {
        referenceName = azurerm_data_factory_linked_service_key_vault.kv.name
        type          = "LinkedServiceReference"
      }
    }
  })
}

# ---------- Datasets (Binary = copy files byte for byte, no parsing) ----------

locals {
  file_name_expr = { value = "@dataset().fileName", type = "Expression" }
  item_name_ref  = { fileName = { value = "@item().name", type = "Expression" } }
}

resource "azurerm_data_factory_custom_dataset" "outbox_folder" {
  name            = "ds_outbox_folder"
  data_factory_id = azurerm_data_factory.adf.id
  type            = "Binary"

  linked_service {
    name = azurerm_data_factory_linked_custom_service.outbox.name
  }

  type_properties_json = jsonencode({
    location = { type = "FileServerLocation" }
  })
}

resource "azurerm_data_factory_custom_dataset" "outbox_file" {
  name            = "ds_outbox_file"
  data_factory_id = azurerm_data_factory.adf.id
  type            = "Binary"
  parameters      = { fileName = "" }

  linked_service {
    name = azurerm_data_factory_linked_custom_service.outbox.name
  }

  type_properties_json = jsonencode({
    location = { type = "FileServerLocation", fileName = local.file_name_expr }
  })
}

resource "azurerm_data_factory_custom_dataset" "outbox_archive" {
  name            = "ds_outbox_archive"
  data_factory_id = azurerm_data_factory.adf.id
  type            = "Binary"
  parameters      = { fileName = "" }

  linked_service {
    name = azurerm_data_factory_linked_custom_service.outbox.name
  }

  type_properties_json = jsonencode({
    location = { type = "FileServerLocation", folderPath = "archive", fileName = local.file_name_expr }
  })
}

resource "azurerm_data_factory_custom_dataset" "landing_file" {
  name            = "ds_landing_file"
  data_factory_id = azurerm_data_factory.adf.id
  type            = "Binary"
  parameters      = { fileName = "" }

  linked_service {
    name = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name
  }

  type_properties_json = jsonencode({
    location = { type = "AzureBlobFSLocation", fileSystem = "landing", fileName = local.file_name_expr }
  })
}

# ---------- Pipeline: list -> keep *.csv -> per file: upload, then move to archive ----------

resource "azurerm_data_factory_pipeline" "ingest" {
  name            = "pl_outbox_to_landing"
  data_factory_id = azurerm_data_factory.adf.id

  depends_on = [
    azurerm_data_factory_custom_dataset.outbox_folder,
    azurerm_data_factory_custom_dataset.outbox_file,
    azurerm_data_factory_custom_dataset.outbox_archive,
    azurerm_data_factory_custom_dataset.landing_file,
  ]

  activities_json = jsonencode([
    {
      name = "ListOutbox"
      type = "GetMetadata"
      typeProperties = {
        dataset   = { referenceName = azurerm_data_factory_custom_dataset.outbox_folder.name, type = "DatasetReference" }
        fieldList = ["childItems"]
      }
    },
    {
      name      = "OnlyCsv"
      type      = "Filter"
      dependsOn = [{ activity = "ListOutbox", dependencyConditions = ["Succeeded"] }]
      typeProperties = {
        items     = { value = "@activity('ListOutbox').output.childItems", type = "Expression" }
        condition = { value = "@and(equals(item().type, 'File'), endswith(toLower(item().name), '.csv'))", type = "Expression" }
      }
    },
    {
      name      = "EachFile"
      type      = "ForEach"
      dependsOn = [{ activity = "OnlyCsv", dependencyConditions = ["Succeeded"] }]
      typeProperties = {
        items        = { value = "@activity('OnlyCsv').output.value", type = "Expression" }
        isSequential = false
        batchCount   = 4
        activities = [
          {
            name    = "CopyToLanding"
            type    = "Copy"
            inputs  = [{ referenceName = azurerm_data_factory_custom_dataset.outbox_file.name, type = "DatasetReference", parameters = local.item_name_ref }]
            outputs = [{ referenceName = azurerm_data_factory_custom_dataset.landing_file.name, type = "DatasetReference", parameters = local.item_name_ref }]
            typeProperties = {
              source = { type = "BinarySource", storeSettings = { type = "FileServerReadSettings" } }
              sink   = { type = "BinarySink", storeSettings = { type = "AzureBlobFSWriteSettings" } }
            }
          },
          {
            # Runs only if the upload succeeded: copy to C:\outbox\archive, then delete the original (a move).
            name      = "ArchiveSource"
            type      = "Copy"
            dependsOn = [{ activity = "CopyToLanding", dependencyConditions = ["Succeeded"] }]
            inputs    = [{ referenceName = azurerm_data_factory_custom_dataset.outbox_file.name, type = "DatasetReference", parameters = local.item_name_ref }]
            outputs   = [{ referenceName = azurerm_data_factory_custom_dataset.outbox_archive.name, type = "DatasetReference", parameters = local.item_name_ref }]
            typeProperties = {
              source = { type = "BinarySource", storeSettings = { type = "FileServerReadSettings", deleteFilesAfterCompletion = true } }
              sink   = { type = "BinarySink", storeSettings = { type = "FileServerWriteSettings" } }
            }
          },
        ]
      }
    },
  ])
}
