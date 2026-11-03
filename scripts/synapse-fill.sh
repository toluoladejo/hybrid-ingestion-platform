#!/usr/bin/env bash
# Fill the <storage-account> and <subscription-id> placeholders in the Synapse artifacts
# (ls_lake, tr_raw_orders) and print the serverless endpoint. Run after the first deploy.
#
# usage: scripts/synapse-fill.sh [env]      (needs az login and terraform init for that env)
set -euo pipefail
ENV=${1:-dev}
cd "$(dirname "$0")/.."

ACCOUNT=$(terraform -chdir=infra output -raw storage_account_name)
SUB_ID=$(az account show --query id -o tsv)

sed -i "s/<storage-account>/$ACCOUNT/g; s/<subscription-id>/$SUB_ID/g; s/rg-ingest-dev/rg-ingest-$ENV/g" \
  synapse/linkedService/ls_lake.json synapse/trigger/tr_raw_orders.json

echo "Storage account: $ACCOUNT"
echo "Workspace:       $(terraform -chdir=infra output -raw synapse_workspace_name)"
echo "Serverless SQL:  $(terraform -chdir=infra output -raw synapse_serverless_endpoint)  (database: ingest)"
echo "Now run sql/serverless/01_ingest.sql, e.g.:"
echo "  sqlcmd -S <endpoint> -d master --authentication-method ActiveDirectoryDefault \\"
echo "    -v StorageAccount=$ACCOUNT MasterKeyPassword='<strong password>' -i sql/serverless/01_ingest.sql"
