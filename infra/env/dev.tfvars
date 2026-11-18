env = "dev"

outbox_path = "C:\\outbox"
outbox_user = "VILSHUB-NET\\adfreader" # run `hostname` in PowerShell

# Synapse (week 5)
# eastus and eastus2 refuse new SQL servers for this subscription (SqlServerRegionDoesNotAllowProvisioning)
synapse_location = "westus2"
allowed_ip       = "102.88.167.62" # curl -s https://api.ipify.org
reader_object_id = ""              # az ad signed-in-user show --query id -o tsv
deploy_spark     = false           # true for the optional Lab 6

# tr_landing_csv was created by a failed apply on 2026-11-13; adopt it instead of recreating it.
import_landing_trigger = true

# Watermark test (feature/watermark-incremental-test, see docs/watermark-test-guide.md).
# true also needs deploy_spark = true and reader_object_id set.
deploy_watermark_test = false
# synapse_git_repo = { account_name = "Starlyvil", repository_name = "hybrid-ingestion-platform", branch_name = "dev" }
