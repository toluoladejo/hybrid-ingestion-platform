# Weeks 4-5: every CSV that lands in landing/ is validated, moved to raw/orders/ or
# quarantine/orders/, and good files are converted to Parquet in curated/orders/.
# ADF owns every data step; Synapse only reads curated/ through serverless SQL (dbo.orders).
#
#   tr_landing_csv (BlobCreated on landing/*.csv)
#     -> pl_landing_to_curated
#          ReadFile (Lookup) --failed--> QuarantineUnreadable -> Fail UNREADABLE_FILE
#            -> BadRows (Filter)
#            -> CheckFile (If)
#                 true:  MoveToRaw -> CurateToParquet --failed--> Fail CURATE_FAILED
#                 false: MoveToQuarantine -> Fail VALIDATION_FAILED
#
# Validation is done with ADF expressions only (no extra compute). They check what the
# learning plan asks for (header and row count) plus blank order_id / amount and negative
# amounts. They cannot catch duplicate IDs or malformed numbers and dates: the view
# ingest.dbo.orders uses TRY_CAST, so those arrive as NULLs, and pipelines/validate.py keeps
# the full rule set for the data-quality tests in CI.

locals {
  lake_ls = azurerm_data_factory_linked_service_data_lake_storage_gen2.lake.name

  # One parameterised location shared by the three lake datasets.
  lake_location = {
    type       = "AzureBlobFSLocation"
    fileSystem = { value = "@dataset().container", type = "Expression" }
    folderPath = { value = "@dataset().folder", type = "Expression" }
    fileName   = { value = "@dataset().fileName", type = "Expression" }
  }
  lake_params = { container = "", folder = "", fileName = "" }

  # Trigger folderPath is "landing" or "landing/sub/dir"; datasets want the part after the container.
  landing_folder = { value = "@join(skip(split(pipeline().parameters.folderPath, '/'), 1), '/')", type = "Expression" }
  file_name      = { value = "@pipeline().parameters.fileName", type = "Expression" }

  landing_ref = {
    container = "landing"
    folder    = local.landing_folder
    fileName  = local.file_name
  }

  # A move = binary copy, then delete the source once the copy has succeeded.
  move_source = { type = "BinarySource", storeSettings = { type = "AzureBlobFSReadSettings", deleteFilesAfterCompletion = true } }
  move_sink   = { type = "BinarySink", storeSettings = { type = "AzureBlobFSWriteSettings" } }

  retry_policy = { timeout = "0.00:30:00", retry = 2, retryIntervalInSeconds = 60 }
}

# ---------- Datasets (generic: container, folder and file are parameters) ----------

resource "azurerm_data_factory_custom_dataset" "lake_binary" {
  name            = "ds_lake_binary"
  data_factory_id = azurerm_data_factory.adf.id
  type            = "Binary"
  parameters      = local.lake_params

  linked_service {
    name = local.lake_ls
  }

  type_properties_json = jsonencode({ location = local.lake_location })
}

resource "azurerm_data_factory_custom_dataset" "lake_csv" {
  name            = "ds_lake_csv"
  data_factory_id = azurerm_data_factory.adf.id
  type            = "DelimitedText"
  parameters      = local.lake_params

  linked_service {
    name = local.lake_ls
  }

  type_properties_json = jsonencode({
    location         = local.lake_location
    columnDelimiter  = ","
    quoteChar        = "\""
    escapeChar       = "\\"
    encodingName     = "UTF-8"
    firstRowAsHeader = true
  })
}

resource "azurerm_data_factory_custom_dataset" "lake_parquet" {
  name            = "ds_lake_parquet"
  data_factory_id = azurerm_data_factory.adf.id
  type            = "Parquet"
  parameters      = local.lake_params

  linked_service {
    name = local.lake_ls
  }

  type_properties_json = jsonencode({
    location         = local.lake_location
    compressionCodec = "snappy"
  })
}

# ---------- Pipeline ----------

resource "azurerm_data_factory_pipeline" "curate" {
  name            = "pl_landing_to_curated"
  data_factory_id = azurerm_data_factory.adf.id
  description     = "Validate one CSV from landing/, move it to raw/orders/ or quarantine/orders/, and write good files as Parquet to curated/orders/ingest_date=yyyy-MM-dd/. Started by tr_landing_csv."

  parameters = {
    folderPath = "landing"
    fileName   = ""
  }

  depends_on = [
    azurerm_data_factory_custom_dataset.lake_binary,
    azurerm_data_factory_custom_dataset.lake_csv,
    azurerm_data_factory_custom_dataset.lake_parquet,
  ]

  activities_json = jsonencode([
    {
      # Reads the whole file into memory. Lookup caps at 5,000 rows / 4 MB: bigger files fail
      # here and are quarantined as UNREADABLE_FILE (split them upstream, or switch to a data flow).
      name   = "ReadFile"
      type   = "Lookup"
      policy = local.retry_policy
      typeProperties = {
        source = {
          type           = "DelimitedTextSource"
          storeSettings  = { type = "AzureBlobFSReadSettings" }
          formatSettings = { type = "DelimitedTextReadSettings" }
        }
        dataset = {
          referenceName = azurerm_data_factory_custom_dataset.lake_csv.name
          type          = "DatasetReference"
          parameters    = local.landing_ref
        }
        firstRowOnly = false
      }
    },
    {
      name      = "QuarantineUnreadable"
      type      = "Copy"
      dependsOn = [{ activity = "ReadFile", dependencyConditions = ["Failed"] }]
      policy    = local.retry_policy
      inputs    = [{ referenceName = azurerm_data_factory_custom_dataset.lake_binary.name, type = "DatasetReference", parameters = local.landing_ref }]
      outputs = [{
        referenceName = azurerm_data_factory_custom_dataset.lake_binary.name
        type          = "DatasetReference"
        parameters    = { container = "quarantine", folder = "orders", fileName = local.file_name }
      }]
      typeProperties = { source = local.move_source, sink = local.move_sink }
    },
    {
      name      = "UnreadableFile"
      type      = "Fail"
      dependsOn = [{ activity = "QuarantineUnreadable", dependencyConditions = ["Completed"] }]
      typeProperties = {
        message   = { value = "@{pipeline().parameters.fileName} could not be read as CSV and was moved to quarantine/orders/: @{activity('ReadFile').error.message}", type = "Expression" }
        errorCode = "UNREADABLE_FILE"
      }
    },
    {
      # Rows that break a rule: blank order_id, blank amount, or a negative amount.
      name      = "BadRows"
      type      = "Filter"
      dependsOn = [{ activity = "ReadFile", dependencyConditions = ["Succeeded"] }]
      typeProperties = {
        items = { value = "@activity('ReadFile').output.value", type = "Expression" }
        condition = {
          value = "@or(or(empty(trim(coalesce(item()?['order_id'], ''))), empty(trim(coalesce(item()?['amount'], '')))), startsWith(trim(coalesce(item()?['amount'], '')), '-'))"
          type  = "Expression"
        }
      }
    },
    {
      # Valid = at least one data row, header has order_id and amount, and no bad rows.
      # first() of an empty array is null, so coalesce to {} before checking the header.
      name      = "CheckFile"
      type      = "IfCondition"
      dependsOn = [{ activity = "BadRows", dependencyConditions = ["Succeeded"] }]
      typeProperties = {
        expression = {
          value = "@and(and(greater(activity('ReadFile').output.count, 0), equals(activity('BadRows').output.FilteredItemsCount, 0)), and(contains(coalesce(first(activity('ReadFile').output.value), json('{}')), 'order_id'), contains(coalesce(first(activity('ReadFile').output.value), json('{}')), 'amount')))"
          type  = "Expression"
        }
        ifTrueActivities = [
          {
            name   = "MoveToRaw"
            type   = "Copy"
            policy = local.retry_policy
            inputs = [{ referenceName = azurerm_data_factory_custom_dataset.lake_binary.name, type = "DatasetReference", parameters = local.landing_ref }]
            outputs = [{
              referenceName = azurerm_data_factory_custom_dataset.lake_binary.name
              type          = "DatasetReference"
              parameters    = { container = "raw", folder = "orders", fileName = local.file_name }
            }]
            typeProperties = { source = local.move_source, sink = local.move_sink }
          },
          {
            # Every column is written as a string; the serverless view owns the types.
            name      = "CurateToParquet"
            type      = "Copy"
            dependsOn = [{ activity = "MoveToRaw", dependencyConditions = ["Succeeded"] }]
            policy    = local.retry_policy
            inputs = [{
              referenceName = azurerm_data_factory_custom_dataset.lake_csv.name
              type          = "DatasetReference"
              parameters    = { container = "raw", folder = "orders", fileName = local.file_name }
            }]
            outputs = [{
              referenceName = azurerm_data_factory_custom_dataset.lake_parquet.name
              type          = "DatasetReference"
              parameters = {
                container = "curated"
                folder    = { value = "@concat('orders/ingest_date=', formatDateTime(utcnow(), 'yyyy-MM-dd'))", type = "Expression" }
                fileName  = { value = "@replace(pipeline().parameters.fileName, '.csv', '.parquet')", type = "Expression" }
              }
            }]
            typeProperties = {
              source = {
                type           = "DelimitedTextSource"
                storeSettings  = { type = "AzureBlobFSReadSettings" }
                formatSettings = { type = "DelimitedTextReadSettings" }
              }
              sink = {
                type           = "ParquetSink"
                storeSettings  = { type = "AzureBlobFSWriteSettings" }
                formatSettings = { type = "ParquetWriteSettings" }
              }
            }
          },
          {
            name      = "CurateFailed"
            type      = "Fail"
            dependsOn = [{ activity = "CurateToParquet", dependencyConditions = ["Failed"] }]
            typeProperties = {
              message   = { value = "Curate failed for raw/orders/@{pipeline().parameters.fileName}: @{activity('CurateToParquet').error.message}", type = "Expression" }
              errorCode = "CURATE_FAILED"
            }
          },
        ]
        ifFalseActivities = [
          {
            name   = "MoveToQuarantine"
            type   = "Copy"
            policy = local.retry_policy
            inputs = [{ referenceName = azurerm_data_factory_custom_dataset.lake_binary.name, type = "DatasetReference", parameters = local.landing_ref }]
            outputs = [{
              referenceName = azurerm_data_factory_custom_dataset.lake_binary.name
              type          = "DatasetReference"
              parameters    = { container = "quarantine", folder = "orders", fileName = local.file_name }
            }]
            typeProperties = { source = local.move_source, sink = local.move_sink }
          },
          {
            # The error note: shows in ADF Monitor and in ADFPipelineRun / ADFActivityRun (week 6 alerts).
            name      = "ValidationFailed"
            type      = "Fail"
            dependsOn = [{ activity = "MoveToQuarantine", dependencyConditions = ["Completed"] }]
            typeProperties = {
              message = {
                value = "@{pipeline().parameters.fileName} moved to quarantine/orders/: @{activity('ReadFile').output.count} data rows, @{activity('BadRows').output.FilteredItemsCount} with a blank order_id, blank amount or negative amount (a missing order_id or amount column makes every row bad)."
                type  = "Expression"
              }
              errorCode = "VALIDATION_FAILED"
            }
          },
        ]
      }
    },
  ])
}

# ---------- Trigger ----------

# Needs the Microsoft.EventGrid resource provider registered on the subscription (once, by a human).
resource "azurerm_data_factory_trigger_blob_event" "landing" {
  name                  = "tr_landing_csv"
  data_factory_id       = azurerm_data_factory.adf.id
  storage_account_id    = var.storage_account_id
  events                = ["Microsoft.Storage.BlobCreated"]
  blob_path_begins_with = "/landing/blobs/"
  blob_path_ends_with   = ".csv"
  ignore_empty_blobs    = true
  activated             = true
  description           = "Starts pl_landing_to_curated for every CSV written to landing/."

  pipeline {
    name = azurerm_data_factory_pipeline.curate.name
    parameters = {
      folderPath = "@triggerBody().folderPath"
      fileName   = "@triggerBody().fileName"
    }
  }
}
