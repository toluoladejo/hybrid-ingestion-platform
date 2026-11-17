# Watermark incremental pipeline: test replica

This branch (`feature/watermark-incremental-test`) adds a working replica of a client's
**"RTO Watermark Incremental"** Azure Synapse pipeline. We rebuilt it from two Synapse Studio
canvas screenshots (2026-11-17) so the workflow can be run end to end on this platform's
infrastructure, and its behaviour checked, especially on failure.

Longer versions: `synapse-watermark-pipeline-guide.pdf` (pipeline walkthrough, how it works, troubleshooting)
and `synapse-watermark-terraform-guide.pdf` (each Terraform resource, identities, plan, teardown).

It uses **synthetic data only**. The rest of the platform keeps its rule that ADF moves
data and Synapse queries it. This replica is the one place where Synapse runs pipelines,
and it does so because the client's version runs in Synapse.

## What gets added

| Path | What it is |
|---|---|
| `synapse/` | Synapse Git root: 5 pipelines, 2 notebooks, 4 datasets, 2 linked services, 1 trigger (Stopped) |
| `synapse/pipeline/pl_watermark_incremental_parent.json` | The 19-activity pipeline from the screenshots, with the same names and dependency conditions |
| `synapse/pipeline/pl_watermark_incremental_single.json` | Child: per-table watermark delta copy (called by `ForEach1`) |
| `synapse/pipeline/pl_watermark_incremental_large.json` | Child: same, with `DynamicRange` partitioned copy (called by `ForEach1_copy2`) |
| `synapse/pipeline/pl_static_load_child.json` | Child for the **deactivated** `ForEach1_copy1` branch |
| `synapse/pipeline/pl_archiving.json` | Target of `Execute Archiving` |
| `synapse/notebook/Run Loop Static Load.json`, `Notebook1.json` | Static full-load loop, and post-load reconciliation (rows copied vs rows in the lake) |
| `sql/watermark/01–04*.sql` | Control schema (`etl`), procedures, synthetic source (`src`), grants for the workspace identity |
| `sql/watermark/90_test_scenarios.sql` | Scenarios S1–S7, resets and check queries |
| `infra/modules/sqldb/` | Azure SQL server and Basic DB (Entra-only auth), created when `deploy_watermark_test = true` |
| `infra/modules/synapse` → `git_repo` | Optional GitHub link for Studio (`synapse_git_repo`) |
| `scripts/configure-watermark.sh` | Fills resource names into `synapse/` and `sql/watermark/` from `terraform output` |
| `tests/test_synapse_artifacts.py` | Static checks: JSON valid, references resolve, unique names, parent still matches the client canvas |

The lake paths are all in the existing **`synapse`** container (`raw/incremental/…`,
`raw/static/…`, `archive/…`). They don't touch the platform's `raw`, `curated` or `archive`
containers.

## How it maps to the client canvas

| Client activity | Runs when | Replica behaviour |
|---|---|---|
| Copy New Tables Metadata | start | `etl.vw_SourceTableCatalog` (tables in `src`) → `etl.NewTablesStaging` |
| Insert New Tables | success | `EXEC etl.usp_InsertNewTables`: no watermark column ⇒ Static, ≥100k rows ⇒ IsLarge |
| Lookup1 → ForEach1 | success | Standard tables → `pl_watermark_incremental_single` (batch 4). Failure ⇒ `Error Report Email` |
| Lookup_Large_Tables → ForEach1_copy2 | **completion** of ForEach1 | Large tables → `pl_watermark_incremental_large` (sequential). Failure ⇒ `Error Report Email copy2` |
| Run Loop Static Load | **success** of ForEach1_copy2 | Spark notebook. Failure ⇒ `Error Report Email copy1` |
| Lookup1_copy1 → ForEach1_copy1 | completion | **Deactivated** (`onInactiveMarkAs: Succeeded`) |
| Notebook1 | Static Load succeeded **AND** ForEach1_copy1 succeeded | Writes `LakeRowCount` / `Validated` to `etl.LoadAudit` |
| Lookup Row Counts → If Condition1 | success | Incremental rows copied this run > 0 ⇒ `Execute Archiving` |

Synapse requires unique activity names across a pipeline, so the nested copies are named
`Execute Pipeline1_copy2` / `_copy1` and `Error Report Email` / `Error Report Email copy2`.
The screenshot previews were truncated, so check these names against the client JSON.

## Deploy and run

1. **Variables.** In `infra/env/dev.tfvars` set:
   ```hcl
   reader_object_id      = "<az ad signed-in-user show --query id -o tsv>"  # also the SQL Entra admin
   deploy_spark          = true
   deploy_watermark_test = true
   synapse_git_repo      = { account_name = "Starlyvil", repository_name = "hybrid-ingestion-platform", branch_name = "dev" }
   ```
   Deploy through a PR into `dev` as usual. The `deploy_watermark_test` validation stops the
   plan if Spark or `reader_object_id` is missing. The SQL server goes in `synapse_location`
   (westus2), because the default region refuses new SQL servers for this subscription.
2. **Fill in resource names** (locally, after `terraform init` for dev as in the README):
   ```bash
   scripts/configure-watermark.sh --from-terraform
   git commit -am "Configure watermark test for dev" && git push
   ```
   Synapse reads `synapse/` straight from Git, so the names have to be committed. They're
   resource names, not secrets. The alert URL is left as a token unless you export
   `ALERT_URL`. Leave it out and paste the URL into the Debug dialog instead.
3. **SQL.** Connect to `<watermark_sql_server_name>.database.windows.net` / `rto_watermark_test`
   with Entra ID (Azure Data Studio, VS Code mssql or `sqlcmd -G`) and run
   `sql/watermark/01` → `02` → `03` → `04`.
4. **Alerts (optional).** Create a Logic App with an HTTP request trigger and an e-mail action, or
   use any request-bin URL. This is the `AlertWebhookUrl` parameter.
5. **Run.** In Synapse Studio, authorise GitHub when asked, switch the branch picker to
   `feature/watermark-incremental-test`, open `pl_watermark_incremental_parent` → **Debug**.
   Debug runs don't need Publish.

Cost: the SQL DB is Basic (a few dollars a month). Spark bills only while a session runs and
pauses after 15 minutes. Set `deploy_watermark_test = false` (and `deploy_spark = false`) when you finish.

## Test plan

Run one block of `sql/watermark/90_test_scenarios.sql`, then a Debug run, then the check queries.

| # | Scenario | What it proves |
|---|---|---|
| S1 | First run | Discovery and classification (Bids ⇒ Large; Markets, StatusCodes ⇒ Static), full initial load, archiving |
| S2 | Re-run, no changes | Watermark works (0 delta rows); If ⇒ False, so no archiving |
| S3 | Insert/update rows | Only changed rows copied |
| S4 | New source table | Picked up and loaded in the same run |
| S5 | Standard table fails | Per-table alert. **Does ForEach1 report Failed?** Does Stage 3 still run (Completed link)? |
| S6 | Large table fails | **Key question:** are static load, Notebook1 and archiving all skipped? |
| S7 | Static notebook fails | `Error Report Email copy1` fires; downstream skipped |

S5 and S6 resolve the "[verify]" items in the pipeline breakdown PDF.

## Known differences from the client

- Source is one Azure SQL DB (`src` schema), not their market or on-prem sources. There is no self-hosted IR.
- The control-table design, notebook logic, If expression and archiving are inferred. Theirs are unknown until we get the JSON.
- One trigger (Stopped) instead of their 8.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Lookup / Copy: login failed for `<token-identified principal>` | Run `sql/watermark/04_permissions.sql` (configured with the workspace name) as the Entra admin |
| Notebook: `Login failed` on JDBC | Same grants. When run interactively, the notebook uses *your* identity, so you need DB access too (you're the admin) |
| Copy to lake: 403 | The workspace identity's Storage Blob Data Contributor role is created by Terraform; wait a few minutes after deploy |
| Studio shows no Git / old artifacts | `synapse_git_repo` not set, or the branch picker is still on `dev` |
| Notebook: pool `sparksmall` not found | `deploy_spark = true` and redeploy |
