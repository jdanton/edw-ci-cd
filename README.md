# Azure EDW reference platform — NYC Taxi

A complete, deployable enterprise data warehouse on Azure, with the CI/CD that
keeps it honest. Built as a **template**: clone it, change the project token,
point it at your subscription, and you have a working four-layer warehouse in
about ninety minutes.

```
Azure Open Datasets          ADLS Gen2              Synapse Serverless        Azure SQL Database
  (NYC TLC yellow taxi)   ┌──────────────┐         ┌──────────────────┐      ┌─────────────────┐
                          │  raw/        │         │  raw.vw_*        │      │  stg.*          │
        ─── ADF Copy ───▶ │   nyctlc/    │ ──────▶ │  curated.usp_*   │      │  dim.* fact.*   │
          (binary)        │              │ CETAS   │   (CETAS)        │      │  etl.* meta.*   │
                          │  curated/    │ ◀────── │  serving.vw_*    │      │  rpt.*          │
                          └──────────────┘         └──────────────────┘      └─────────────────┘
                                  │                                                   ▲
                                  └──────────────── ADF Copy ─────────────────────────┘
                                                  (Parquet → staging → MERGE)
```

Everything runs on **private endpoints**. Nothing in the data plane is reachable
from the public internet.

---

## What is in here

| Path | What it is |
|---|---|
| [`bootstrap/`](bootstrap/) | Applied once, by a human. Terraform state storage, Entra apps with OIDC federation, admin groups. |
| [`infra/terraform/`](infra/terraform/) | The platform. One root module, three environments selected by `-var-file` and `-backend-config`. |
| [`src/adf/`](src/adf/) | Data Factory artifacts in the exact layout [`azure.datafactory.tools`](https://github.com/Azure-Player/azure.datafactory.tools) expects. |
| [`src/synapse/`](src/synapse/) | Workspace artifacts for [`azure.synapse.tools`](https://github.com/Azure-Player/azure.synapse.tools), **plus** the serverless T-SQL that no artifact API can deploy. |
| [`src/sql/`](src/sql/) | SDK-style `.sqlproj` (`Microsoft.Build.Sql`). Builds to a DACPAC with `dotnet build` on Linux. |
| [`scripts/`](scripts/) | PowerShell deployment and diagnostic scripts. Every workflow is a thin wrapper around one of these, so everything is runnable locally. |
| [`.github/workflows/`](.github/workflows/) | Ten workflows: PR validation, four CD pipelines, backfill, drift detection. |
| [`docs/`](docs/) | The long-form explanations. Start with [00-architecture](docs/00-architecture.md). |

---

## Read these three things first

**1. You need a self-hosted runner inside a VNet.** This is not a preference.
Every data-plane endpoint has public network access disabled, so a
GitHub-hosted runner cannot create an ADLS filesystem, publish a Synapse
artifact, run the serverless DDL, or deploy a DACPAC. The workflows target
`runs-on: [self-hosted, linux, X64, edw]`. See
[05-runner-connectivity](docs/05-runner-connectivity.md).

**2. Private DNS is the thing that breaks.** Not firewalls, not RBAC — DNS. If
the `privatelink.*` zones are not linked to the runner's VNet, names resolve to
public IPs, connections hang, and the error blames SQL or Synapse. Run
[`scripts/Test-PlatformConnectivity.ps1`](scripts/Test-PlatformConnectivity.ps1)
before debugging anything else.

**3. Permissions live at three independent layers.** Azure RBAC, network, and
*database principals*. Terraform can do the first two and physically cannot do
the third — SQL keeps its own principal store. The long comment at the top of
[`infra/terraform/rbac.tf`](infra/terraform/rbac.tf) is worth five minutes.

---

## Quick start

Roughly ninety minutes, most of it waiting for Azure.

```bash
# 0. Prerequisites: az, terraform >= 1.5, pwsh 7, dotnet 8, gh
#    See docs/01-prerequisites.md
az login
az account set --subscription <your-subscription-id>

# 1. Bootstrap — once per subscription, from your workstation.
cd bootstrap
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars          # subscription, tenant, GitHub owner/repo
terraform init && terraform apply

# 2. Push the identifiers into GitHub (variables only — OIDC means no secrets).
cd ..
./scripts/Set-GitHubOidcSecrets.ps1

# 3. Fill in the per-environment values bootstrap produced.
cd bootstrap
terraform output -raw 'tfvars_fragments["dev"]'     # paste into
                                                    # infra/terraform/envs/dev/dev.tfvars
terraform output backend_config                     # paste into
                                                    # infra/terraform/envs/*/backend.hcl

# 4. Set runner_vnet_id in each envs/<env>/<env>.tfvars to your runner's VNet.
#    az network vnet list --query "[].{name:name, id:id}" -o table

# 5. Deploy. From the runner, or from any host inside the runner's VNet.
cd ../infra/terraform
terraform init -reconfigure -backend-config=envs/dev/backend.hcl
terraform apply -var-file=envs/dev/dev.tfvars

# 6. Prove the network before going further. This step saves afternoons.
cd ..
./scripts/Test-PlatformConnectivity.ps1 -Environment dev

# 7. Deploy the code.
./scripts/Deploy-ServerlessSql.ps1 -Environment dev
./scripts/Deploy-Synapse.ps1       -Environment dev
./scripts/Deploy-DataFactory.ps1   -Environment dev
dotnet build src/sql/EdwTaxi.Database/EdwTaxi.Database.sqlproj -c Release
# then sqlpackage — see docs/08-azure-sql.md

# 8. Load a month of data.
./scripts/Initialize-ReferenceData.ps1 -Environment dev
# then run the "Data backfill" workflow, or trigger PL_Backfill_NycTaxi_Yellow
# in ADF Studio with startYearMonth=201901, endYearMonth=201901
```

Full walkthrough: [02-bootstrap](docs/02-bootstrap.md).

---

## The pipeline, end to end

`PL_Master_NycTaxi_Load` runs three stages for one month:

| Stage | Pipeline | What happens | Where the work runs |
|---|---|---|---|
| 1 | `PL_Ingest_NycTaxi_Yellow` | Binary copy from Azure Open Datasets into `raw/nyctlc/yellow/puYear=…/puMonth=…/`. Bytes are preserved exactly. | ADF managed-VNet IR |
| 2 | `PL_Curate_NycTaxi_Yellow` | Purge the target folder, then `CETAS` into `curated/nyctlc/yellow_trip/PickupYear=…/PickupMonth=…/`. Types fixed, duplicates removed, partition leakage excluded. | Synapse serverless |
| 3 | `PL_Load_Sql_YellowTrip` | Copy curated Parquet into `stg.YellowTaxiTrip`, then partition-replace into `fact.YellowTaxiTrip`, then run the data quality rules. | ADF copy + Azure SQL |

Each stage is independently re-runnable and idempotent for a given
`(puYear, puMonth)`. A failed run is repaired by running it again, never by
hand-editing the warehouse.

---

## Design decisions worth knowing

Each of these is explained where it lives; this is the index.

| Decision | Where | Why |
|---|---|---|
| Deploy ADF from the **collaboration branch**, not `adf_publish` | [`adf-cd.yml`](.github/workflows/adf-cd.yml) | No human clicking "Publish"; reviewable diffs; per-artifact failures. |
| Terraform owns integration runtimes and managed VNets; the tools own pipelines | [`modules/datafactory/main.tf`](infra/terraform/modules/datafactory/main.tf) | Otherwise the two flip-flop on alternate deployments. |
| **No** `MERGE` statement in the fact load | [`etl.usp_Merge_YellowTaxiTrip`](src/sql/EdwTaxi.Database/Programmability/Stored%20Procedures/etl.usp_Merge_YellowTaxiTrip.sql) | Known correctness bugs; bad on columnstore; partition replacement matches how the TLC restates data. |
| Clustered columnstore with **no** nonclustered index | [`fact.YellowTaxiTrip`](src/sql/EdwTaxi.Database/Tables/fact/YellowTaxiTrip.sql) | Month-at-a-time inserts make rowgroups month-aligned, so segment elimination already does the job. |
| Raw ingest is **binary**, not Parquet-to-Parquet | [`DS_OpenDatasets_NycTlc_Binary`](src/adf/dataset/DS_OpenDatasets_NycTlc_Binary.json) | A raw zone should hold what was published, byte for byte. |
| Curated exposed by `OPENROWSET` views, not external tables | [`080_views_curated.sql`](src/synapse/serverless/080_views_curated.sql) | Only `OPENROWSET` supports `filepath()` partition pruning — the difference between 40 MB and 40 GB scanned. |
| Every dimension has an **Unknown (-1)** member | [`dim.Vendor`](src/sql/EdwTaxi.Database/Tables/dim/Vendor.sql) | Keeps `INNER JOIN`s correct without dropping fact rows. |
| Data quality rules are **rows**, not code | [`meta.DataQualityRule`](src/sql/EdwTaxi.Database/Tables/meta/DataQualityRule.sql) | A new check is an `INSERT`, not a deployment. |
| Endpoints generated from Terraform; decisions committed | [`src/adf/deployment/README.md`](src/adf/deployment/README.md) | Reviewable config without mechanical churn or stale endpoints. |
| Bootstrap is **never** in CI | [`bootstrap/providers.tf`](bootstrap/providers.tf) | A pipeline that can mint its own credentials can escalate its own privileges. |

---

## Documentation

| | |
|---|---|
| [00 — Architecture](docs/00-architecture.md) | The whole system, layer by layer, and why each one exists. |
| [01 — Prerequisites](docs/01-prerequisites.md) | Tools, Azure permissions, and what to check before starting. |
| [02 — Bootstrap](docs/02-bootstrap.md) | The full first-deployment runbook. |
| [03 — Terraform](docs/03-terraform.md) | Module layout, state, promotion, and the cycle-avoidance rules. |
| [04 — Networking](docs/04-networking.md) | Private endpoints, managed VNets, and the nine DNS zones. |
| [05 — Runner connectivity](docs/05-runner-connectivity.md) | Making your existing self-hosted runners work with this platform. |
| [06 — Data Factory](docs/06-data-factory.md) | Artifacts, the config CSV, trigger state, tumbling windows. |
| [07 — Synapse](docs/07-synapse.md) | Serverless, CETAS, collation, and the two-halves deployment. |
| [08 — Azure SQL](docs/08-azure-sql.md) | SDK-style projects, publish profiles, and safe migrations. |
| [09 — CI/CD workflows](docs/09-cicd-workflows.md) | Every workflow, what triggers it, and what gates it. |
| [10 — Making a change](docs/10-making-a-change.md) | Four worked end-to-end examples, including adding a column. |
| [11 — Operations runbook](docs/11-operations-runbook.md) | What to do when an alert fires, per alert. |
| [12 — Troubleshooting](docs/12-troubleshooting.md) | Error messages mapped back to their actual causes. |
| [13 — Cost](docs/13-cost.md) | What this costs, and which knobs matter. |

---

## Adapting the template

The dataset is a worked example, not the point. To replace NYC Taxi with your
own source, [10-making-a-change](docs/10-making-a-change.md#example-4-adding-a-new-source)
walks through it. In short: the platform, the CI/CD, the permission model and
the medallion structure are reusable as-is; you replace one ADF ingest pipeline,
one CETAS procedure, one staging table and one merge procedure.

Rename the project by changing `project` in `bootstrap/terraform.tfvars` and in
each `infra/terraform/envs/<env>/<env>.tfvars`. It is capped at eight characters
because it is concatenated into storage account names, which Azure caps at 24.

---

## Licence and provenance

The NYC TLC trip record data is published by the New York City Taxi and
Limousine Commission and mirrored by Microsoft in
[Azure Open Datasets](https://learn.microsoft.com/azure/open-datasets/dataset-taxi-yellow).
It is used here under the TLC's terms as sample data.
