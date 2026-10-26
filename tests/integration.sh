#!/usr/bin/env bash
# End-to-end test against dev (week 6): upload a sample, run the pipeline, wait for the result.
# Needs: az login, `az extension add --name datafactory`, and the ADF pipeline from weeks 3-4.
set -euo pipefail
RG=${RG:-rg-ingest-dev}
ADF=${ADF:-adf-ingest-dev}
PIPELINE=${PIPELINE:-pl_ingest}
ACCOUNT=${ACCOUNT:?set ACCOUNT to the dev storage account name}

az storage blob upload --account-name "$ACCOUNT" --container-name landing \
    --name "it/orders_$(date +%s).csv" --file samples/orders.csv --auth-mode login --only-show-errors

RUN_ID=$(az datafactory pipeline create-run -g "$RG" \
    --factory-name "$ADF" --name "$PIPELINE" --query runId -o tsv)
echo "run $RUN_ID"
for _ in $(seq 1 30); do
  STATUS=$(az datafactory pipeline-run show -g "$RG" \
      --factory-name "$ADF" --run-id "$RUN_ID" --query status -o tsv)
  echo "status: $STATUS"
  case "$STATUS" in Succeeded) exit 0 ;; Failed|Cancelled) exit 1 ;; esac
  sleep 20
done
echo "timed out" >&2
exit 1
