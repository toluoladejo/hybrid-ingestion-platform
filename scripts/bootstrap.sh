#!/usr/bin/env bash
# One-time setup (weeks 0 and 2): resource groups, an Entra ID app that GitHub Actions
# logs in as via OIDC (no secrets), and the repository variables the workflows read.
#
# usage: scripts/bootstrap.sh <github-owner>/<repo> [location]
# Needs: az login (Owner or User Access Administrator on the subscription), gh auth login.
set -euo pipefail
REPO=${1:?usage: scripts/bootstrap.sh <owner>/<repo> [location]}
LOCATION=${2:-westeurope}
APP_NAME="gh-${REPO//\//-}"

SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)

for env in dev prod; do
  az group create -n "rg-ingest-$env" -l "$LOCATION" --tags project=hybrid-ingestion-platform env=$env -o none
done

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

gh variable set AZURE_CLIENT_ID --repo "$REPO" --body "$APP_ID"
gh variable set AZURE_TENANT_ID --repo "$REPO" --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUB_ID"
for env in dev prod; do gh api -X PUT "repos/$REPO/environments/$env" --silent; done

echo "Done. Now add yourself as a required reviewer on the 'prod' environment:"
echo "  https://github.com/$REPO/settings/environments"
