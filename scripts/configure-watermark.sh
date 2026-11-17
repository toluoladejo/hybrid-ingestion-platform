#!/usr/bin/env bash
# Fills the __PLACEHOLDER__ tokens in synapse/ and sql/watermark/ with this environment's
# resource names. Synapse Studio reads synapse/ straight from Git, so commit the result
# on the branch you debug from.
#
#   scripts/configure-watermark.sh --from-terraform [env]   # names from `terraform output` (default env: dev)
#   scripts/configure-watermark.sh                          # names from watermark.env
#   scripts/configure-watermark.sh --check                  # list tokens still unreplaced
#
# --from-terraform needs `terraform init` done in infra/ for that environment (see README).
set -euo pipefail
cd "$(dirname "$0")/.."
TARGETS=(synapse sql/watermark)

if [[ "${1:-}" == "--check" ]]; then
  grep -rnoE '__[A-Z_]+__' "${TARGETS[@]}" || echo "No placeholders left."
  exit 0
fi

if [[ "${1:-}" == "--from-terraform" ]]; then
  out() { terraform -chdir=infra output -raw "$1" 2>/dev/null || true; }
  SQL_SERVER=$(out watermark_sql_server_name)
  SQL_DB=$(out watermark_sql_database)
  STORAGE_ACCOUNT=$(out storage_account_name)
  SYNAPSE_WORKSPACE=$(out synapse_workspace_name)
  ALERT_URL=${ALERT_URL:-}
  if [[ -z "$SQL_SERVER" || "$SQL_SERVER" == "null" ]]; then
    echo "watermark_sql_server_name is empty: deploy with deploy_watermark_test = true first." >&2
    exit 1
  fi
else
  [[ -f watermark.env ]] || { echo "watermark.env not found. Copy watermark.env.example or use --from-terraform." >&2; exit 1; }
  # shellcheck disable=SC1091
  source watermark.env
fi

declare -A MAP=(
  [__SQL_SERVER__]="$SQL_SERVER"
  [__SQL_DB__]="$SQL_DB"
  [__STORAGE_ACCOUNT__]="$STORAGE_ACCOUNT"
  [__SYNAPSE_WORKSPACE__]="$SYNAPSE_WORKSPACE"
)
# The alert URL is optional (it carries a SAS signature); without it the token stays and
# you supply the URL as a pipeline parameter at Debug time.
[[ -n "${ALERT_URL:-}" ]] && MAP[__ALERT_URL__]="$ALERT_URL"

mapfile -t files < <(grep -rlE '__[A-Z_]+__' "${TARGETS[@]}" || true)
[[ ${#files[@]} -eq 0 ]] && { echo "Nothing to replace."; exit 0; }

for f in "${files[@]}"; do
  for token in "${!MAP[@]}"; do
    esc=$(printf '%s' "${MAP[$token]}" | sed -e 's/[\/&|]/\\&/g')
    sed -i "s|$token|$esc|g" "$f"
  done
  echo "configured $f"
done
"$0" --check
