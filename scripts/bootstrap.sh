#!/usr/bin/env bash
# One-time setup (weeks 0 and 2): resource groups, a storage account for Terraform state,
# an Entra ID app that GitHub Actions logs in as via OIDC (no secrets), and the
# repository variables the workflows read.
#
# usage: scripts/bootstrap.sh <github-owner>/<repo> [location]
# Needs: az login (Owner or User Access Administrator on the subscription), gh auth login.
set -euo pipefail
REPO=${1:?usage: scripts/bootstrap.sh <owner>/<repo> [location]}
LOCATION=${2:-westeurope}
APP_NAME="gh-${REPO//\//-}"

SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
TFSTATE_RG=rg-ingest-tfstate
TFSTATE_ACCOUNT="sttfstate$(echo -n "$SUB_ID" | sha1sum | cut -c1-12)"

for env in dev prod; do
  az group create -n "rg-ingest-$env" -l "$LOCATION" --tags project=hybrid-ingestion-platform env=$env -o none
done

# Terraform state: kept in its own resource group so tearing down an environment keeps it.
az group create -n "$TFSTATE_RG" -l "$LOCATION" --tags project=hybrid-ingestion-platform -o none
az storage account create -n "$TFSTATE_ACCOUNT" -g "$TFSTATE_RG" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 \
  --allow-blob-public-access false --allow-shared-key-access false -o none
az storage account blob-service-properties update -n "$TFSTATE_ACCOUNT" -g "$TFSTATE_RG" \
  --enable-versioning true -o none
az storage container-rm create -n tfstate --storage-account "$TFSTATE_ACCOUNT" -g "$TFSTATE_RG" -o none
TFSTATE_ID=$(az storage account show -n "$TFSTATE_ACCOUNT" -g "$TFSTATE_RG" --query id -o tsv)

APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)
if [ -z "$APP_ID" ]; then
  APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
  az ad sp create --id "$APP_ID" -o none
fi

# The subject must match how each job runs (see the "Common trap" note in week 2).
for pair in "pr:pull_request" "env-dev:environment:dev" "env-prod:environment:prod"; do
  name=${pair%%:*}; subject="repo:$REPO:${pair#*:}"
  az ad app federated-credential create --id "$APP_ID" -o none --parameters "{
    \"name\": \"$name\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$subject\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" || echo "federated credential $name already exists"
done

for env in dev prod; do
  az role assignment create --assignee "$APP_ID" --role Contributor \
    --scope "/subscriptions/$SUB_ID/resourceGroups/rg-ingest-$env" -o none
done

# State access is data-plane RBAC (no account keys), for the pipeline and for you.
for principal in "$APP_ID" "$(az ad signed-in-user show --query id -o tsv)"; do
  az role assignment create --assignee "$principal" --role "Storage Blob Data Contributor" \
    --scope "$TFSTATE_ID" -o none
done

gh variable set AZURE_CLIENT_ID --repo "$REPO" --body "$APP_ID"
gh variable set AZURE_TENANT_ID --repo "$REPO" --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUB_ID"
gh variable set TFSTATE_STORAGE_ACCOUNT --repo "$REPO" --body "$TFSTATE_ACCOUNT"
for env in dev prod; do gh api -X PUT "repos/$REPO/environments/$env" --silent; done

echo "Done. Now add yourself as a required reviewer on the 'prod' environment:"
echo "  https://github.com/$REPO/settings/environments"
