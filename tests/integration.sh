#!/usr/bin/env bash
# End-to-end test against an environment (week 7): drop a good and a bad file in landing/ and
# wait for tr_landing_csv -> pl_landing_to_curated to route them. No manual pipeline run:
# the storage event trigger is what is being tested.
#   good: curated/orders/ingest_date=<today>/<name>.parquet (and raw/orders/<name>.csv)
#   bad:  quarantine/orders/<name>.csv
# Needs: az login with Storage Blob Data Contributor on the account.
set -euo pipefail
ACCOUNT=${ACCOUNT:?set ACCOUNT to the storage account name (terraform output -raw storage_account_name)}
TS=$(date +%s)
GOOD="orders_it_${TS}.csv"
BAD="orders_bad_it_${TS}.csv"

upload() {
  az storage blob upload --account-name "$ACCOUNT" --container-name landing \
      --name "it/$2" --file "$1" --auth-mode login --only-show-errors -o none
}

exists() {
  [ "$(az storage blob exists --account-name "$ACCOUNT" --container-name "$1" \
        --name "$2" --auth-mode login --query exists -o tsv)" = "true" ]
}

wait_for() {
  for _ in $(seq 1 30); do
    if exists "$1" "$2"; then echo "ok: $1/$2"; return 0; fi
    sleep 20
  done
  echo "timed out waiting for $1/$2" >&2
  return 1
}

upload samples/orders.csv "$GOOD"
upload samples/orders_bad.csv "$BAD"

# The date is the pipeline's UTC run date; a run that crosses midnight lands in the next folder.
wait_for curated "orders/ingest_date=$(date -u +%F)/${GOOD%.csv}.parquet"
wait_for quarantine "orders/$BAD"
exists raw "orders/$GOOD" || { echo "missing raw/orders/$GOOD" >&2; exit 1; }
! exists landing "it/$GOOD" || { echo "landing/it/$GOOD was not removed" >&2; exit 1; }
echo "integration test passed"
