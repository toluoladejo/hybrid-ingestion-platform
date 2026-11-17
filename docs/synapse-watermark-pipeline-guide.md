# Watermark Incremental Loads with Synapse Pipelines

Nov 17, 2026

## What you're building

A Synapse pipeline keeps a copy of a source database in the data lake up to date, **without reloading every table on every run**. A control table records, for each source table, the last value of its "watermark" column (`ModifiedDate`). Each run copies only the rows newer than that value, then moves the watermark forward.

It's a replica of a client's **"RTO Watermark Incremental"** pipeline, rebuilt from two Synapse Studio canvas screenshots. The aim is to run the same workflow on this platform and see how it behaves, above all when something fails. All data is synthetic.

```
Azure SQL DB   sql-wm-<env>-<suffix> / rto_watermark_test
+----------------------------------------------+
| src.Submissions    500 rows,  ModifiedDate   |   simulated source
| src.Bids           200k rows, ModifiedDate   |
| src.Markets, src.StatusCodes  (no watermark) |
| etl.WatermarkControl, etl.LoadAudit, ...     |   control tables
+-----------------------+----------------------+
                        ^  ls_sql_rto  (workspace managed identity)
                        |
Synapse workspace   syn-ingest-<env>-<suffix>
+----------------------------------------------+
| pl_watermark_incremental_parent  (19 acts)   |
|   +- children: ..._single / ..._large        |
|   +- 2 notebooks on Spark pool sparksmall    |
|   +- pl_archiving                            |
+-----------------------+----------------------+
                        |  ls_adls_lake  (workspace managed identity)
                        v
ADLS Gen2   stingest<env><suffix>, container "synapse"
    raw/incremental/<schema>_<table>/yyyy/MM/dd/<runId>.parquet
    raw/static/<schema>_<table>/
    archive/yyyyMMdd_HHmm/
```

The Azure SQL database plays two parts: the **source system** (schema `src`) and the **control database** (schema `etl`). In the client's world these are separate systems. Here one Basic database keeps the cost at a few dollars a month.

### The pipeline: `pl_watermark_incremental_parent`

```
STAGE 1  register new tables
Copy New Tables Metadata (Copy: etl.vw_SourceTableCatalog -> etl.NewTablesStaging)
   | Succeeded
Insert New Tables (Lookup: EXEC etl.usp_InsertNewTables)
   | Succeeded
STAGE 2  standard tables
Lookup1 (Lookup: Incremental, not large)
   | Succeeded
ForEach1 (batch 4) --+--> Execute Pipeline1 -> pl_watermark_incremental_single
   |                 +--(Failed)--> Error Report Email (Web)
   | Completed   <-- runs even if some tables failed
STAGE 3  large tables
Lookup_Large_Tables (Lookup: Incremental, IsLarge = 1)
   | Succeeded
ForEach1_copy2 (sequential) --+--> Execute Pipeline1_copy2 -> pl_watermark_incremental_large
   |                          +--(Failed)--> Error Report Email copy2 (Web)
   +--------------------------------+
   | Succeeded                      | Completed
STAGE 4  static tables              |
Run Loop Static Load (Notebook)     Lookup1_copy1 (DEACTIVATED)
   |          |(Failed)                 |
   |          +--> Error Report         ForEach1_copy1 (DEACTIVATED) -> pl_static_load_child
   |               Email copy1           |
   | Succeeded                           | Succeeded (reported automatically, never runs)
   +----------------+--------------------+
STAGE 5          Notebook1 (Notebook: reconcile rows copied vs rows in the lake)
                    | Succeeded
STAGE 6          Lookup Row Counts (Lookup: incremental rows copied in this run)
                    | Succeeded
                 If Condition1  TotalRows > 0 ?
                    +-- True  --> Execute Archiving -> pl_archiving
                    +-- False --> (nothing)
```

### The child pipeline: one table, one delta

`ForEach1` and `ForEach1_copy2` call a child pipeline once per table. It's the classic watermark pattern:

```
OldWatermark  (Lookup)  SELECT WatermarkValue FROM etl.WatermarkControl WHERE ControlId = <id>
   |
NewWatermark  (Lookup)  SELECT MAX(ModifiedDate) FROM src.<table>      -- fixes the upper bound
   |
Delta copy    (Copy)    SELECT * FROM src.<table>
   |                    WHERE ModifiedDate >  <old>  AND  ModifiedDate <= <new>
   |                    --> raw/incremental/src_<table>/yyyy/MM/dd/<runId>.parquet
   |
Update watermark (Stored procedure)  etl.usp_UpdateWatermark
                        writes an etl.LoadAudit row, then WatermarkValue = <new>
```

The large-table child (`pl_watermark_incremental_large`) is the same, except that the copy uses **`DynamicRange` partitioning** on the watermark column with 4 parallel copies, so one big table is read in slices instead of a single query.

### Why the design looks like this

- **The upper bound is fixed before copying.** `NewWatermark` reads `MAX(ModifiedDate)` *first*, and the copy uses `<= new`. Rows written while the copy is running are left for the next run. They aren't lost, and they aren't copied twice.
- **The watermark only moves after a successful copy.** `Update watermark` depends on `Delta copy` succeeding. If the copy fails, the next run retries the same window.
- **New tables register themselves.** Stage 1 compares the source catalogue with the control table, so a new table in `src` is picked up and loaded in the same run, with no manual edits.
- **Errors are reported per table, inside the loop.** One bad table sends one e-mail naming that table, and the other iterations carry on.
- **Large tables get their own, gentler loop.** They run sequentially and partitioned, so they don't hold up or overload the standard loop.
- **Archiving is gated.** Data is archived only after it has loaded, been reconciled and the row-count check passed.

## Where it lives in the repo

Unlike the ADF pipelines, which Terraform defines, **the Synapse pipeline is plain JSON in `synapse/`**, which Synapse Studio reads from Git. Terraform only provides the infrastructure it runs on.

| File | What it holds |
| --- | --- |
| `synapse/pipeline/pl_watermark_incremental_parent.json` | The 19-activity pipeline above |
| `synapse/pipeline/pl_watermark_incremental_single.json` | Child for standard tables |
| `synapse/pipeline/pl_watermark_incremental_large.json` | Child for large tables (partitioned copy) |
| `synapse/pipeline/pl_static_load_child.json` | Child for the deactivated `ForEach1_copy1` branch |
| `synapse/pipeline/pl_archiving.json` | Copies `raw/incremental/` to `archive/<timestamp>/` and logs it |
| `synapse/notebook/Run Loop Static Load.json` | PySpark: full reload of every Static table |
| `synapse/notebook/Notebook1.json` | PySpark: counts the rows that landed in the lake and writes them to `etl.LoadAudit` |
| `synapse/linkedService/ls_sql_rto.json`, `ls_adls_lake.json` | Azure SQL DB and the lake, both via the workspace managed identity |
| `synapse/dataset/*.json` | `ds_sql_query`, `ds_sql_table`, `ds_adls_parquet`, `ds_adls_binary` (generic, parameterised) |
| `synapse/trigger/tr_watermark_daily.json` | Daily 06:00 UTC schedule, created **Stopped** |
| `sql/watermark/01_control_schema.sql` | `etl.WatermarkControl`, `NewTablesStaging`, `LoadAudit`, `ArchiveLog`, `vw_SourceTableCatalog` |
| `sql/watermark/02_procedures.sql` | `usp_InsertNewTables`, `usp_UpdateWatermark`, `usp_RecordStaticLoad`, `usp_LogArchive` |
| `sql/watermark/03_source_seed.sql` | The synthetic source tables |
| `sql/watermark/04_permissions.sql` | Database user and grants for the workspace identity |
| `sql/watermark/90_test_scenarios.sql` | Scenarios S1–S7, resets, check queries |
| `scripts/configure-watermark.sh` | Writes this environment's resource names into `synapse/` and `sql/watermark/` |
| `tests/test_synapse_artifacts.py` | Checks the JSON on every PR: references resolve, names unique, canvas still matches |
| `infra/modules/sqldb/` | The Azure SQL server and database (see the Terraform guide) |

How the control table drives everything:

| Column | Set by | Used by |
| --- | --- | --- |
| `SchemaName`, `TableName` | Stage 1 (catalogue view) | Every loop and child |
| `WatermarkColumn` | Stage 1: the first `datetime`/`datetime2` column named `ModifiedDate`, `LastModified` or `UpdatedAt`, otherwise NULL | Child pipelines |
| `LoadType` | Stage 1: NULL watermark ⇒ `Static`, otherwise `Incremental` | `Lookup1`, `Lookup_Large_Tables`, static notebook |
| `IsLarge` | Stage 1: Incremental and ≥ 100,000 rows | Which loop the table goes to |
| `WatermarkValue` | `usp_UpdateWatermark` after each successful copy (starts at `1900-01-01`) | `OldWatermark` |
| `IsActive` | You (default 1) | All lookups; set to 0 to skip a table |

Classification happens **once**, when a table is first registered. If a table grows past 100k rows later, set `IsLarge = 1` yourself.

## Step 0: Prerequisites (once)

1. **The platform is deployed**, at least through week 5: storage, Synapse workspace, and you as Synapse Administrator (`SYNAPSE_ADMIN_OBJECT_ID`). See the README.
2. **Your object ID** (it becomes the SQL admin): `az ad signed-in-user show --query id -o tsv`
3. **Register the SQL provider** if it isn't already (the pipeline identity can't register providers): `az provider register -n Microsoft.Sql --wait`
4. **No new rights for the CI identity.** The SQL module creates no role assignments, so the Role Based Access Control Administrator condition from week 3 stays as it is.
5. **Optional: an alert endpoint.** A Logic App with an HTTP request trigger and an e-mail action (*When an HTTP request is received* → *Send an email*), or any request-bin URL for a quick test. Copy its URL.

## Step 1: Deploy the Terraform

In `infra/env/dev.tfvars`:

```hcl
reader_object_id      = "<your object id>"   # Step 0.2; also gets lake read access
deploy_spark          = true                 # the notebooks run on sparksmall
deploy_watermark_test = true                 # Azure SQL server + rto_watermark_test
synapse_git_repo = {
  account_name    = "Starlyvil"
  repository_name = "hybrid-ingestion-platform"
  branch_name     = "dev"                     # collaboration branch; Debug from any branch
}
```

Open a PR into `dev`. The plan should add the SQL server, database and two firewall rules, add the Spark pool, and change the workspace in place (the Git link). Merge, and the `infra` workflow applies it.

If you forget `deploy_spark` or `reader_object_id`, the plan stops with *"deploy_watermark_test needs deploy_spark = true ... and reader_object_id set"*. That's the variable validation doing its job.

## Step 2: Write the resource names into the artifacts

Synapse reads `synapse/` straight from GitHub, so the server, database and storage names have to be in the committed JSON. Locally, with `terraform init` done for dev (as in the README):

```bash
scripts/configure-watermark.sh --from-terraform
git commit -am "Configure watermark test for dev"
git push
```

The script replaces `__SQL_SERVER__`, `__SQL_DB__`, `__STORAGE_ACCOUNT__` and `__SYNAPSE_WORKSPACE__`, then lists anything left. These are resource names, not secrets. **The alert URL stays a token** unless you `export ALERT_URL=...` first, because it contains a SAS signature. Leave it out and paste it into the Debug dialog instead (Step 5).

No Terraform access? Copy `watermark.env.example` to `watermark.env` (git-ignored), fill it in from the portal, and run the script without arguments.

## Step 3: Create the database objects (manual, once)

Connect to `<watermark_sql_server_name>.database.windows.net`, database `rto_watermark_test`, with **Microsoft Entra ID** (Azure Data Studio, VS Code *mssql*, or `sqlcmd -G`). Your IP is already in the firewall through `allowed_ip`. Run, in order:

| Script | Creates |
| --- | --- |
| `01_control_schema.sql` | Schema `etl`, the four tables, the catalogue view |
| `02_procedures.sql` | The four stored procedures |
| `03_source_seed.sql` | Schema `src` with Submissions (500), Bids (200,000), Markets (7), StatusCodes (9) |
| `04_permissions.sql` | User `[syn-ingest-dev-…]` FROM EXTERNAL PROVIDER, reader/writer, EXECUTE on `etl`, ALTER on the staging table (for TRUNCATE) |

`etl.WatermarkControl` starts **empty** on purpose. The first pipeline run fills it.

## Step 4: Open the branch in Synapse Studio

1. Synapse Studio. The first time, it asks you to **authorise GitHub**: sign in and grant access to the repository.
2. Top-left branch picker: switch from `dev` to **`feature/watermark-incremental-test`**.
3. **Integrate > Pipelines > RTO Modernization Test**: `pl_watermark_incremental_parent` should open with the same layout as the client canvas.
4. **Manage > Linked services**: test `ls_sql_rto` and `ls_adls_lake`. Both should succeed.

## Step 5: Run it and work through the scenarios

Click **Debug**. The parameter dialog shows `AlertWebhookUrl`; paste the URL from Step 0.5 (or leave the token if you don't care about alert e-mails yet). The first run takes a few minutes longer, because the Spark pool has to start.

Then work through `sql/watermark/90_test_scenarios.sql` one block at a time. Run a Debug run after each block, then the check queries at the bottom.

| # | Change | Expected |
| --- | --- | --- |
| S1 | none (fresh seed) | 4 tables registered: Bids `IsLarge = 1`, Markets/StatusCodes `Static`. 500 + 200,000 rows copied, 16 static rows. If ⇒ **True**, archiving runs |
| S2 | none | 0 incremental rows, static tables reload, If ⇒ **False**, no archiving |
| S3 | 3 new + 5 updated Submissions, 1,000 new Bids | Exactly 8 + 1,000 rows copied |
| S4 | create `src.Outages` | Registered and loaded in the same run |
| S5 | Submissions' watermark column broken | `Error Report Email` for Submissions. **Record ForEach1's status.** Stage 3 still runs (Completed link) |
| S6 | Bids' watermark column broken | `Error Report Email copy2`. **Record whether Static Load, Notebook1 and archiving are skipped** |
| S7 | Markets renamed in the control table | `Error Report Email copy1`. Notebook1 and archiving skipped |

Run the **RESET** block after S5–S7. Results from S5 and S6 answer the open "[verify]" questions in the pipeline breakdown.

Where to look:

- **Monitor > Pipeline runs**, switch to **Debug**. Click a run to see each activity's status, input and output. A child pipeline run opens from its Execute Pipeline activity.
- **The lake**: `synapse` container, `raw/incremental/…`, `raw/static/…`, `archive/…`.
- **The database**: `etl.LoadAudit` (one row per table per run, with `RowsCopied`, `LakeRowCount`, `Validated`) and `etl.WatermarkControl`.

## Understanding what you built

### Where the pipeline lives: Git defines it, Synapse runs it

The ADF pipelines in this repo are Terraform resources: change `curate.tf`, deploy, and Studio edits get overwritten. **The Synapse pipeline works the other way round.**

| | ADF pipelines (`pl_outbox_to_landing`, `pl_landing_to_curated`) | Synapse watermark pipeline |
| --- | --- | --- |
| Defined in | `infra/modules/datafactory/*.tf` (`jsonencode`) | `synapse/**/*.json` |
| How it reaches Azure | `terraform apply` from GitHub Actions | Studio reads the Git branch; **Publish** copies it to the live workspace |
| Edit in Studio? | No (Terraform overwrites it) | **Yes.** Studio commits your edit to the branch |
| Run without deploying | No | Yes: **Debug** runs the branch version |
| Live/triggered version | What Terraform last applied | What was last **Published** (branch `workspace_publish`) |

Rule: **edit on a branch, Debug from the branch, and only Publish when you want triggers to use it.** This test never needs Publish. If you do Publish, Synapse creates a `workspace_publish` branch in the GitHub repo holding ARM templates. That's normal.

Terraform still owns the **Git link itself** (`synapse_git_repo`). If you connected Git by hand in Studio, the next `terraform apply` would remove the link, because Terraform doesn't know about it.

### Activity names and the client canvas

Activity names are the client's: `Lookup1`, `Notebook1`, `ForEach1_copy2` and so on. Default names make the mapping easy to check, though they're poor practice for a real pipeline. Synapse requires every activity name to be **unique across the whole pipeline**, nested ones included. That's why the copies inside the loops are `Execute Pipeline1_copy2` / `_copy1` and `Error Report Email` / `Error Report Email copy2`. The screenshot previews were cut off, so these four names are a guess.

### Dependency conditions: the four arrow colours

| Condition | Arrow | Downstream runs when upstream… | Used here |
| --- | --- | --- | --- |
| Succeeded | green | succeeded | most of the chain |
| Failed | red | failed | every `Error Report` Web activity |
| Completed | blue | finished either way | ForEach1 → Lookup_Large_Tables; ForEach1_copy2 → Lookup1_copy1 |
| Skipped | grey | was skipped | not used |

**Several arrows into one activity are ANDed.** `Notebook1` needs *Run Loop Static Load = Succeeded* **and** *ForEach1_copy1 = Succeeded*. There's no OR on a single activity. To build an OR you add an extra activity, or use Completed plus an If.

**A deactivated activity** (`"state": "Inactive"`) doesn't run and reports the status in `onInactiveMarkAs`, `Succeeded` here. That's why `ForEach1_copy1` never blocks `Notebook1`. If someone reactivates that branch, Notebook1 will wait for it too.

**A ForEach whose iteration failed** is generally reported as Failed, even when an error-path activity handled the failure inside the loop. S5 and S6 confirm this on a real run. It's the reason S6 matters: if `ForEach1_copy2` is Failed, its green arrow to *Run Loop Static Load* doesn't fire, and everything after it is skipped for that run.

### The expressions in this pipeline

Same `@` language as the ADF guide. The new ones:

| Expression | Meaning |
| --- | --- |
| `@activity('Lookup1').output.value` | All rows a Lookup returned (*First row only* off). ForEach loops over it |
| `@item().TableName` | A column of the current row inside the ForEach |
| `@activity('OldWatermark').output.firstRow.WatermarkValue` | One column of a Lookup with *First row only* on |
| `@concat('SELECT * FROM [', pipeline().parameters.SchemaName, '].[', ...)` | Builds SQL at run time. In a string, `''` is one literal quote |
| `@activity('Delta copy').output.rowsCopied` | Copy activity metric, passed to the stored procedure |
| `@pipeline().RunId` | This run's ID. The parent passes it to children as `ParentRunId`, to group audit rows |
| `@greater(int(activity('Lookup Row Counts').output.firstRow.TotalRows), 0)` | The If condition. Lookup values arrive as strings or numbers, so `int()` makes the comparison safe |
| `?AdfDynamicRangePartitionCondition` | Placeholder that the partitioned copy replaces with each slice's `WHERE` range |

### Why a Lookup runs `EXEC`, and the Lookup limits

`Insert New Tables` is a **Lookup**, not a Stored Procedure activity, although it writes. A Lookup can return a result, and the procedure ends with `SELECT @inserted AS NewTablesInserted, …`, so the run output shows how many tables were added. A Lookup **must** get a result set back, or it fails. Remember that if you change the procedure.

Lookups return at most **5,000 rows / 4 MB**. That's fine for table lists, but don't point one at data.

### The notebooks: Spark and identity

Both notebooks start with a **parameters cell** (tagged `parameters`). The pipeline's Notebook activity overrides those values with `SqlServer`, `SqlDatabase`, `StorageAccount`, `Container` and the run ID.

They reach SQL over JDBC with an **Entra token**, not a password:

```python
token = mssparkutils.credentials.getToken("DW")   # audience https://database.windows.net/
spark.read.format("jdbc").option("accessToken", token).option("query", q).load()
```

| Run from | Token belongs to | Needs |
| --- | --- | --- |
| Pipeline (Debug or trigger) | The **workspace managed identity** | `04_permissions.sql` grants; Storage Blob Data Contributor (Terraform) |
| Studio, interactively | **You** | DB access (you're the SQL admin) and lake access (`reader_object_id` gives read; writing to the lake needs Contributor) |

`Run Loop Static Load` keeps looping when a table fails and **raises at the end**, so one bad static table doesn't hide the others, and the pipeline's red arrow still fires.

### Spark: why it's switched on here

The ADF guide explains why this platform doesn't need Spark for its own small CSV files. Here it's needed for one reason: **the client's pipeline uses notebooks**, and the point is to reproduce it. Each Debug run starts `sparksmall` (2–4 minutes, 3 nodes billed while running) and it pauses 15 minutes after the last notebook. Stop the session in **Monitor > Apache Spark applications** if you finish early.

### Two orchestrators in one project

This breaks the platform's rule that ADF orchestrates and Synapse only queries, on purpose and in an isolated corner:

| | Platform ingestion | Watermark test |
| --- | --- | --- |
| Orchestrator | ADF | Synapse pipelines |
| Source | On-prem files via SHIR | Azure SQL DB (no SHIR) |
| Lake container | `landing`, `raw`, `curated`, `quarantine`, `archive` | `synapse` only |
| Deployed by | Terraform | Git link + Studio |
| Can be removed by | n/a | `deploy_watermark_test = false`, `deploy_spark = false`, delete `synapse/` |

Synapse pipelines run on the same engine as ADF, so everything here would also work in ADF. The exception is the two **Synapse Notebook** activities, which in ADF would become *Synapse Notebook* activities pointing at this workspace, or Databricks notebooks.

## Troubleshooting

| Error | Fix |
| --- | --- |
| Plan: `deploy_watermark_test needs deploy_spark = true …` | Set `deploy_spark = true` and `reader_object_id` (Step 1) |
| Apply: `SqlServerRegionDoesNotAllowProvisioning` | The SQL server already follows `synapse_location` (westus2). If that region refuses too, change `synapse_location`, and note this moves the workspace as well |
| Apply: `MissingSubscriptionRegistration … Microsoft.Sql` | Step 0.3 |
| Lookup / Copy: `Login failed for user '<token-identified principal>'` | Run `04_permissions.sql` after `configure-watermark.sh` (so it has the workspace name), as the Entra admin |
| `04_permissions.sql`: `Principal '…' could not be found` | The workspace name in the script is still a token or wrong; the user name must equal the workspace name |
| Copy: `Cannot connect to SQL Database … Client with IP address … is not allowed` | The `AllowAllWindowsAzureIps` rule is missing; re-apply Terraform |
| Insert New Tables: `TRUNCATE … permission` | `GRANT ALTER ON etl.NewTablesStaging` from `04_permissions.sql` |
| Copy to lake: `403 … AuthorizationPermissionMismatch` | Workspace identity's Storage Blob Data Contributor not propagated yet; wait a few minutes |
| Notebook: `Spark pool sparksmall not found` | `deploy_spark = true` and redeploy |
| Notebook: JDBC `Login failed` | Same grants as above for pipeline runs. Interactively it's *your* identity |
| `Error Report Email`: `Invalid URI` | `AlertWebhookUrl` is still `__ALERT_URL__`; paste a URL in the Debug dialog |
| Studio shows only `dev`, or no Git | `synapse_git_repo` not set, or GitHub not authorised yet (Step 4.1) |
| Large child fails on a run with no new rows | Old and new watermarks are equal, so the partition range is empty. If S2 fails here, switch the large child's `partitionOption` to `None` for empty ranges, or wrap the copy in an If on `old != new` |
| Every table copied again in full | `WatermarkValue` didn't update: look at `Update watermark` in the child run |

## Things to know

- **Deletes aren't captured.** A watermark only sees inserts and updates. A row deleted at source stays in the lake. Catching deletes needs change tracking / CDC, or a periodic full compare.
- **Late updates with old timestamps are missed.** If a source writes `ModifiedDate` earlier than the current watermark (clock skew, back-dated loads), those rows never qualify.
- **Watermarks are strings.** `WatermarkValue` holds `yyyy-MM-dd HH:mm:ss.fff` and is cast back to `datetime2` in the query. Keep that format if you edit it by hand. To reload a table from scratch, set it to `1900-01-01`.
- **Every run writes a new Parquet file** per table, including empty ones. Downstream readers should read the folder, not a file name.
- **Archiving copies, it doesn't move.** `pl_archiving` leaves `raw/incremental/` in place, so the archive grows each True run. Add a Delete activity if you want a real move.
- **The trigger is Stopped.** It only fires after you **Publish** and start it. The client has 8 triggers. Here there's one, to keep the test cheap.
- **Teardown.** Set `deploy_watermark_test = false` and `deploy_spark = false` and deploy. The database and its data are deleted; the `synapse` container contents stay.
