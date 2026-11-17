# Hybrid File Ingestion Platform

Portfolio project for the *Azure Data Platform & DevOps 8-week learning plan*
(`../Azure-Data-Platform-Learning-Plan.pdf`).

A simulated on-prem server drops CSV files. They are copied to Azure Storage,
trigger a Data Factory pipeline, get validated, and are moved to `raw/` or
`quarantine/`; good files are converted to Parquet in `curated/`, which Synapse
serverless SQL serves as a view. Every step is logged, alerted on and shown on a
dashboard, and everything is deployed from this repository by GitHub Actions.

**ADF moves the data, Synapse queries it.** Data Factory owns every step that copies,
validates or converts a file. The Synapse workspace runs no pipelines; its built-in
serverless SQL pool reads `curated/` in place.

```
                 ┌──────────────── Azure Data Factory (all pipelines in Terraform) ────────────────┐
On-prem files ──►│ pl_outbox_to_landing ─► landing/ ─(Event Grid: tr_landing_csv)─► pl_landing_to_curated │
  (SHIR)         └───────────────────────────────────────────────┬───────────────┬─────────────────┘
                                                        good ─► raw/orders/     bad ─► quarantine/orders/
                                                                  └─► curated/orders/ingest_date=…/*.parquet
                                                                                   │ OPENROWSET
                         Power BI / SQL clients ◄── Synapse serverless SQL: ingest.dbo.orders
ADF + storage diagnostic logs ──► Log Analytics ──► alerts + dashboards
All of it: Terraform + GitHub Actions (OIDC) ── PR plan ──► dev ──(approval)──► prod
```

## Layout

| Path | What it is |
|---|---|
| `infra/main.tf` | Entry point: Log Analytics, Storage (ADLS Gen2 + containers + diagnostics), Key Vault |
| `infra/versions.tf` | Terraform and `azurerm` provider versions, remote state backend |
| `infra/modules/` | One Terraform module per resource |
| `infra/modules/datafactory/main.tf` | Week 3: factory, SHIR, linked services, `pl_outbox_to_landing` (on-prem → `landing/`) |
| `infra/modules/datafactory/curate.tf` | Weeks 4–5: `tr_landing_csv` trigger and `pl_landing_to_curated` (validate → raw / quarantine → curated Parquet) |
| `infra/modules/synapse/` | Week 5: Synapse workspace, managed identity, firewall, lake roles, optional Spark pool. Query layer only |
| `sql/serverless/` | Serverless SQL database `ingest`, view `dbo.orders`, and reader grants. Run by hand or with `sqlcmd` |
| `infra/env/dev.tfvars`, `prod.tfvars` | Per-environment variables |
| `.github/workflows/infra.yml` | PR: fmt + validate + plan. Push to `main`: apply dev, then prod after approval |
| `.github/workflows/deploy.yml` | Reusable deploy job, one per environment |
| `.github/workflows/tests.yml` | Unit and data-quality tests on every PR |
| `pipelines/validate.py` | Full validation rules (stricter than the pipeline's), run by the data-quality tests |
| `tests/` | `pytest` tests and `integration.sh` (drops files in `landing/` and checks where they end up) |
| `samples/` | A good and a bad sample file |
| `synapse/`, `sql/watermark/` | **Watermark test** (branch `feature/watermark-incremental-test`): Synapse replica of a client's watermark incremental pipeline, with its SQL. See `docs/watermark-test-guide.md` |
| `infra/modules/sqldb/` | Azure SQL DB for the watermark test, only when `deploy_watermark_test = true` |
| `scripts/configure-watermark.sh` | Writes this environment's resource names into `synapse/` and `sql/watermark/` |
| `scripts/bootstrap.sh` | One-time setup: resource groups, Terraform state storage, OIDC app, repo variables, environments |

## Getting started

```bash
# 1. Tools: Azure CLI, Terraform >= 1.9, GitHub CLI, Python 3.12
az login
gh auth login

# 2. Push this repo to GitHub, then run the one-time bootstrap
gh repo create <owner>/hybrid-ingestion-platform --private --source . --push
scripts/bootstrap.sh <owner>/hybrid-ingestion-platform

# 3. Run the tests locally
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q

# 4. Preview the infrastructure (uses your az login; state lives in rg-ingest-tfstate)
cd infra
terraform init -backend-config="storage_account_name=$(gh variable get TFSTATE_STORAGE_ACCOUNT)" \
  -backend-config="key=dev.tfstate"
terraform plan -var-file=env/dev.tfvars
```

Each environment has its own state file (`dev.tfstate`, `prod.tfstate`). To switch
environments locally, re-run `terraform init -reconfigure` with the other `key`.

Set a **budget alert** on the subscription before deploying anything, and tear
down when you finish each week (`terraform destroy -var-file=env/dev.tfvars`)
— the point is that everything redeploys from this repo. Keep `rg-ingest-tfstate`
and the `rg-ingest-<env>` groups themselves; bootstrap created them, Terraform does not.

## Validate and curate pipeline (weeks 4–5)

Every CSV written to `landing/` (by `pl_outbox_to_landing` or by hand) fires the storage event
trigger `tr_landing_csv`, which starts `pl_landing_to_curated`:

| Step | Activity | Result |
|---|---|---|
| Read | `ReadFile` (Lookup, whole file) | Unreadable or too big → `quarantine/orders/`, fails with `UNREADABLE_FILE` |
| Check | `BadRows` (Filter) + `CheckFile` (If) | Valid = at least one data row, header has `order_id` and `amount`, no row with a blank `order_id`, blank `amount` or negative `amount` |
| Good | `MoveToRaw` → `CurateToParquet` | `raw/orders/<file>.csv` and `curated/orders/ingest_date=yyyy-MM-dd/<file>.parquet`. A failed conversion fails with `CURATE_FAILED` |
| Bad | `MoveToQuarantine` → `ValidationFailed` | `quarantine/orders/<file>.csv`; the run fails with `VALIDATION_FAILED` and a message giving the row counts (the error note) |

Moves are a copy followed by deleting the source, so `landing/` is empty once a file is processed.

**What the pipeline does not check.** The checks are ADF expressions only (no extra compute), and
these cannot detect duplicate `order_id`s or malformed numbers and dates. Those rows reach `curated/`.
The view `dbo.orders` uses `TRY_CAST`, so bad values show up as `NULL`. `pipelines/validate.py`
keeps the full rule set for the data-quality tests. The Lookup reads at most 5,000 rows / 4 MB per
file; larger files are quarantined as `UNREADABLE_FILE`.

### Deploy and run it

1. Register the Event Grid provider once (storage event triggers need it; the pipeline identity can't register providers):
   `az provider register -n Microsoft.EventGrid --wait`
2. In `infra/env/dev.tfvars`, set `allowed_ip` and `reader_object_id`, then deploy through a PR as usual.
   Terraform creates the datasets, the pipeline and the trigger, and starts the trigger. Terraform also
   generates the Synapse SQL admin password, which never appears in the repo. If the workspace fails
   with `SqlServerRegionDoesNotAllowProvisioning`, also set `synapse_location`
   (see [Synapse troubleshooting](#synapse-troubleshooting)).
3. Set `gh variable set SYNAPSE_ADMIN_OBJECT_ID --body "$(az ad signed-in-user show --query id -o tsv)"`.
   The deploy job then grants you **Synapse Administrator**. Being Azure Owner does not give access inside the workspace.
4. Run `sql/serverless/01_ingest.sql` against the `-ondemand` endpoint, then `02_readers.sql` for other readers.
5. Checkpoint: upload `samples/orders.csv` and `samples/orders_bad.csv` to `landing/`
   (or drop them in `C:\outbox` and run `pl_outbox_to_landing`). Within a minute or two the good file is in
   `raw/orders/`, its Parquet in `curated/orders/`, its rows in `SELECT * FROM dbo.orders`, and the bad file in
   `quarantine/orders/`. ADF Studio → **Monitor** shows one run per file. `ACCOUNT=<storage account> tests/integration.sh`
   does the same check from the command line.

To reprocess a file, copy it back into `landing/`. To change the pipeline, edit `curate.tf`
and deploy; don't edit it in ADF Studio, because the next `terraform apply` overwrites Studio changes.

### Where is the SQL server?

There is no separate SQL server resource. Serverless SQL is built into the workspace, so
`rg-ingest-<env>` shows only the Synapse workspace (plus `rg-ingest-<env>-synapse-managed`, which
Synapse owns; never edit it). To connect:

- **Endpoint:** workspace → **Overview** → **Serverless SQL endpoint**, or the Terraform output
  `synapse_serverless_endpoint` (`syn-ingest-<env>-<suffix>-ondemand.sql.azuresynapse.net`).
- **Sign-in:** Microsoft Entra ID. Connect to `master` until `01_ingest.sql` has created `ingest`.
- **Without a client:** Synapse Studio → **Develop** → new SQL script, connected to **Built-in**.

Before any of that works you need steps 2 and 3 above: your IP in `allowed_ip` (firewall),
your object ID in `reader_object_id` (lake reads) and `SYNAPSE_ADMIN_OBJECT_ID` (Studio access).

### Synapse troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `SqlServerRegionDoesNotAllowProvisioning`: "Location '…' is not accepting creation of new Windows Azure SQL Database servers for the subscription" | Every workspace contains a hidden SQL server, and Azure has no SQL capacity in that region for your subscription (common on student and trial subscriptions) | Set `synapse_location` in `infra/env/<env>.tfvars` to a region that accepts SQL servers; only the workspace moves, the lake stays put. Test a region first by creating and deleting an empty SQL server (free): `az sql server create -g rg-ingest-dev -n sqlprobe-$RANDOM -l <region> -u probeadmin -p '<strong password>'`. Or request region access: Help + support → Service and subscription limits (quotas) → SQL Database → Region access |
| No SQL server in the resource group | Expected: serverless SQL is part of the workspace | Use the `-ondemand` endpoint (see above) |
| Studio or SQL client can't connect | Your IP isn't in the workspace firewall, or it changed | Update `allowed_ip` and redeploy |
| Studio: "You do not have the required permissions" | No Synapse RBAC role; Azure Owner isn't enough | Set `SYNAPSE_ADMIN_OBJECT_ID` (step 3) and redeploy |
| Files stay in `landing/`, no ADF runs | Trigger not started, or `Microsoft.EventGrid` not registered | Register the provider (step 1); in ADF Studio → **Manage** → **Triggers**, `tr_landing_csv` must be **Started** |

This project's dev workspace runs in `westus2`, because `eastus` and `eastus2` refused it. A
workspace in a different region from its lake works; expect a little extra latency and egress cost.

Full walkthrough: `../Week5-Azure-Synapse-Analytics-Tutorial.pdf`. That tutorial uses Bicep; this repo
implements the same resources in Terraform. The tutorial builds `pl_curate` as a Synapse pipeline; this repo
runs that step in ADF instead (`CurateToParquet` in `pl_landing_to_curated`), so skip its Studio Publish steps.
Its troubleshooting table doesn't cover the region error above.

## Watermark incremental test (side project)

`synapse/` holds a Synapse replica of a client's metadata-driven **watermark incremental** pipeline
(19 activities: new-table discovery, standard and large incremental loops with per-table alerts,
Spark static load, reconciliation, conditional archiving). It runs on this platform's workspace
and lake, with synthetic data in an optional Azure SQL DB. It is the one exception to
"Synapse runs no pipelines". Everything is off by default (`deploy_watermark_test = false`).
Setup and test scenarios: [`docs/watermark-test-guide.md`](docs/watermark-test-guide.md). Full walkthroughs:
[`docs/synapse-watermark-pipeline-guide.pdf`](docs/synapse-watermark-pipeline-guide.pdf) (the pipeline, step by step) and
[`docs/synapse-watermark-terraform-guide.pdf`](docs/synapse-watermark-terraform-guide.pdf) (every Terraform resource it adds).

## Roadmap

- [x] **Week 0** — Setup: repo layout, resource groups, budget
- [x] **Week 1** — Terraform: storage, Key Vault, Log Analytics modules
- [x] **Week 2** — GitHub Actions: OIDC, PR plan, gated dev → prod
- [ ] **Week 3** — Data Factory + self-hosted IR: copy on-prem files to `landing/`
- [ ] **Week 4** — Storage event trigger `tr_landing_csv`, validation, raw / quarantine *(in `curate.tf`: deploy and run the checkpoint to tick)*
- [ ] **Week 5** — Synapse: workspace (Terraform), serverless `dbo.orders` over the curated Parquet that ADF writes *(scaffolded: deploy and run the checkpoint to tick)*
- [ ] **Week 6** — Alerts: ADF pipeline failed (split by `VALIDATION_FAILED` / `CURATE_FAILED` / `UNREADABLE_FILE`), file late, quarantine not empty
- [ ] **Week 7** — Data-quality and integration tests in CI; Workbook + Power BI report
- [ ] **Week 8** — README polish, RBAC review, teardown and redeploy

Weeks 0–2 and the Weeks 4–5 pipeline and Synapse pieces are scaffolded here. The remaining weeks are left for you to build.
