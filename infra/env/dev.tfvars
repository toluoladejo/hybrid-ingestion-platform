env = "dev"

outbox_path = "C:\\outbox"
outbox_user = "VILSHUB-NET\\adfreader" # run `hostname` in PowerShell

# Synapse (week 5)
# eastus and eastus2 refuse new SQL servers for this subscription (SqlServerRegionDoesNotAllowProvisioning)
synapse_location = "uksouth"
github_owner     = ""    # your GitHub user: links Synapse Studio to this repo
allowed_ip       = ""    # curl -s https://api.ipify.org
reader_object_id = ""    # az ad signed-in-user show --query id -o tsv
deploy_spark     = false # true for the optional Lab 6

