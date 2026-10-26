# Hybrid File Ingestion Platform

Portfolio project for the *Azure Data Platform & DevOps 8-week learning plan*
(`../Azure-Data-Platform-Learning-Plan.pdf`).

A simulated on-prem server drops CSV files. They are copied to Azure Storage,
trigger a Data Factory pipeline, get validated, and are moved to `raw/` or
`quarantine/`. Every step is logged, alerted on and shown on a dashboard, and
everything is deployed from this repository by GitHub Actions.

```
On-prem files ──(SHIR)──► Storage landing/ ──(Event Grid)──► ADF pipeline ──► raw / curated / quarantine
                               │                                   │
                               └────── diagnostic logs ──► Log Analytics ──► alerts + dashboards
All of it: Bicep + GitHub Actions (OIDC) ── PR what-if ──► dev ──(approval)──► prod
```

## Layout

| Path | What it is |
|---|---|
| `infra/main.bicep` | Entry point: Log Analytics, Storage (ADLS Gen2 + containers + diagnostics), Key Vault |
| `infra/modules/` | One Bicep module per resource |
| `infra/dev.bicepparam`, `prod.bicepparam` | Per-environment parameters |
| `.github/workflows/infra.yml` | PR: lint + what-if. Push to `main`: deploy dev, then prod after approval |
| `.github/workflows/deploy.yml` | Reusable deploy job, one per environment |
| `.github/workflows/tests.yml` | Unit and data-quality tests on every PR |
| `pipelines/validate.py` | File validation logic used by the pipeline |
| `tests/` | `pytest` tests and `integration.sh` (end-to-end against dev) |
| `samples/` | A good and a bad sample file |
| `scripts/bootstrap.sh` | One-time setup: resource groups, OIDC app, repo variables, environments |

## Getting started

```bash
# 1. Tools: Azure CLI, Bicep (az bicep install), GitHub CLI, Python 3.12
az login
gh auth login

# 2. Push this repo to GitHub, then run the one-time bootstrap
gh repo create <owner>/hybrid-ingestion-platform --private --source . --push
scripts/bootstrap.sh <owner>/hybrid-ingestion-platform

# 3. Run the tests locally
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q

# 4. Preview the infrastructure
az deployment group what-if -g rg-ingest-dev -f infra/main.bicep -p infra/dev.bicepparam
```

Set a **budget alert** on the subscription before deploying anything, and delete
the resource groups when you finish each week (`az group delete -n rg-ingest-dev`)
— the point is that everything redeploys from this repo.

## Roadmap

- [x] **Week 0** — Setup: repo layout, resource groups, budget
- [x] **Week 1** — Bicep: storage, Key Vault, Log Analytics modules
- [x] **Week 2** — GitHub Actions: OIDC, PR what-if, gated dev → prod
- [ ] **Week 3** — Data Factory + self-hosted IR: copy on-prem files to `landing/`
- [ ] **Week 4** — Storage event trigger, validation, archive / quarantine
- [ ] **Week 5** — Alerts: pipeline failed, file late, quarantine not empty
- [ ] **Week 6** — Data-quality and integration tests in CI; ADF CI/CD
- [ ] **Week 7** — Azure Monitor Workbook + Power BI report
- [ ] **Week 8** — README polish, RBAC review, teardown and redeploy

Weeks 0–2 are scaffolded here. The remaining weeks are left for you to build.
