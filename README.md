# Hybrid File Ingestion Platform

Portfolio project for the *Azure Data Platform & DevOps 8-week learning plan*
(`../Azure-Data-Platform-Learning-Plan.pdf`).

A simulated on-prem server drops CSV files. They are copied to Azure Storage,
trigger a Data Factory pipeline, get validated, and are moved to `raw/` or
`quarantine/`. Every step is logged, alerted on and shown on a dashboard, and
everything is deployed from this repository by GitHub Actions.

```
On-prem files ──(SHIR)──► Storage landing/ ──(Event Grid)──► ADF pipeline ──► raw / quarantine
                                                                                 │ (Event Grid)
                                    Power BI ◄── serverless SQL dbo.orders ◄── Synapse pl_curate ──► curated/ (Parquet)
                               │                                   │
                               └────── diagnostic logs ──► Log Analytics ──► alerts + dashboards
All of it: Terraform + GitHub Actions (OIDC) ── PR plan ──► dev ──(approval)──► prod
```

## Layout

| Path | What it is |
|---|---|
| `infra/main.tf` | Entry point: Log Analytics, Storage (ADLS Gen2 + containers + diagnostics), Key Vault |
| `infra/versions.tf` | Terraform and `azurerm` provider versions, remote state backend |
| `infra/modules/` | One Terraform module per resource |
| `infra/modules/synapse/` | Week 5: Synapse workspace, managed identity, firewall, lake roles, Git link, optional Spark pool |
| `synapse/` | Synapse artifacts (linked service, datasets, `pl_curate` pipeline, `tr_raw_orders` trigger), published from Studio |
| `sql/serverless/` | Serverless SQL database `ingest`, view `dbo.orders`, and reader grants. Run by hand or `sqlcmd`, not by Publish |
| `infra/env/dev.tfvars`, `prod.tfvars` | Per-environment variables |
| `.github/workflows/infra.yml` | PR: fmt + validate + plan. Push to `main`: apply dev, then prod after approval |
| `.github/workflows/deploy.yml` | Reusable deploy job, one per environment |
| `.github/workflows/tests.yml` | Unit and data-quality tests on every PR |
| `pipelines/validate.py` | File validation logic used by the pipeline |
| `tests/` | `pytest` tests and `integration.sh` (end-to-end against dev) |
| `samples/` | A good and a bad sample file |
| `scripts/synapse-fill.sh` | Fills the storage account and subscription placeholders in `synapse/` after the first deploy |
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

## Synapse curate pipeline (week 5)

When a validated CSV lands in `raw/orders/`, the storage event trigger `tr_raw_orders` starts
`pl_curate`. The pipeline copies that file to Snappy Parquet under
`curated/orders/ingest_date=yyyy-MM-dd/`. If the copy fails, a Fail activity ends the run with
`CURATE_FAILED`. The serverless view `ingest.dbo.orders` reads the Parquet and owns the column types.

1. In `infra/env/dev.tfvars`, set `github_owner`, `allowed_ip` and `reader_object_id`, then deploy
   through a PR as usual. Terraform generates the required SQL admin password; it is never in the repo.
   If the workspace fails with `SqlServerRegionDoesNotAllowProvisioning`, also set `synapse_location`
   (see [Synapse troubleshooting](#synapse-troubleshooting)).
2. Set `gh variable set SYNAPSE_ADMIN_OBJECT_ID --body "$(az ad signed-in-user show --query id -o tsv)"`.
   The deploy job then grants you **Synapse Administrator**. Being Azure Owner does not give access inside the workspace.
3. Run `scripts/synapse-fill.sh dev` to fill the placeholders in `ls_lake.json` and `tr_raw_orders.json`. Commit the result.
4. In Synapse Studio, open a working branch, check the artifacts, merge to `main`, and **Publish**.
   Triggers fire only after they are published.
5. Run `sql/serverless/01_ingest.sql` against the `-ondemand` endpoint, then `02_readers.sql` for other readers.
6. Upload `samples/orders.csv` to `raw/orders/`. A Parquet file appears in `curated/orders/` and its rows
   show up in `SELECT * FROM dbo.orders`.

### Where is the SQL server?

There is no separate SQL server resource. Serverless SQL is built into the workspace, so
`rg-ingest-<env>` shows only the Synapse workspace (plus `rg-ingest-<env>-synapse-managed`, which
Synapse owns; never edit it). To connect:

- **Endpoint:** workspace → **Overview** → **Serverless SQL endpoint**, or the Terraform output
  `synapse_serverless_endpoint` (`syn-ingest-<env>-<suffix>-ondemand.sql.azuresynapse.net`).
- **Sign-in:** Microsoft Entra ID. Connect to `master` until `01_ingest.sql` has created `ingest`.
- **Without a client:** Synapse Studio → **Develop** → new SQL script, connected to **Built-in**.

Before any of that works you need steps 1 and 2 above: your IP in `allowed_ip` (firewall),
your object ID in `reader_object_id` (lake reads) and `SYNAPSE_ADMIN_OBJECT_ID` (Studio access).

### Synapse troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `SqlServerRegionDoesNotAllowProvisioning`: "Location '…' is not accepting creation of new Windows Azure SQL Database servers for the subscription" | Every workspace contains a hidden SQL server, and Azure has no SQL capacity in that region for your subscription (common on student and trial subscriptions) | Set `synapse_location` in `infra/env/<env>.tfvars` to a region that accepts SQL servers; only the workspace moves, the lake stays put. Test a region first by creating and deleting an empty SQL server (free): `az sql server create -g rg-ingest-dev -n sqlprobe-$RANDOM -l <region> -u probeadmin -p '<strong password>'`. Or request region access: Help + support → Service and subscription limits (quotas) → SQL Database → Region access |
| No SQL server in the resource group | Expected: serverless SQL is part of the workspace | Use the `-ondemand` endpoint (see above) |
| Studio or SQL client can't connect | Your IP isn't in the workspace firewall, or it changed | Update `allowed_ip` and redeploy |
| Studio: "You do not have the required permissions" | No Synapse RBAC role; Azure Owner isn't enough | Set `SYNAPSE_ADMIN_OBJECT_ID` (step 2) and redeploy |

This project's dev workspace runs in `westus2`, because `eastus` and `eastus2` refused it. A
workspace in a different region from its lake works; expect a little extra latency and egress cost.

Full walkthrough: `../Week5-Azure-Synapse-Analytics-Tutorial.pdf`. That tutorial uses Bicep; this repo
implements the same resources in Terraform. Its troubleshooting table doesn't cover the region error above.

## Roadmap

- [x] **Week 0** — Setup: repo layout, resource groups, budget
- [x] **Week 1** — Terraform: storage, Key Vault, Log Analytics modules
- [x] **Week 2** — GitHub Actions: OIDC, PR plan, gated dev → prod
- [ ] **Week 3** — Data Factory + self-hosted IR: copy on-prem files to `landing/`
- [ ] **Week 4** — Storage event trigger, validation, archive / quarantine
- [ ] **Week 5** — Synapse: workspace (Terraform), `pl_curate` raw → curated Parquet, serverless `dbo.orders` *(scaffolded: deploy, publish and run the checkpoint to tick)*
- [ ] **Week 6** — Alerts: pipeline failed (ADF + Synapse), file late, quarantine not empty
- [ ] **Week 7** — Data-quality and integration tests in CI; ADF + Synapse CI/CD; Workbook + Power BI report
- [ ] **Week 8** — README polish, RBAC review, teardown and redeploy

Weeks 0–2 and the Week 5 Synapse pieces are scaffolded here. The remaining weeks are left for you to build.
