# 00 — Architecture

What each layer is, what it is responsible for, and — more usefully — what it is
deliberately *not* responsible for.

---

## The whole thing on one page

```
                                  ┌───────────────────────────────────────────┐
                                  │  Azure Open Datasets (public, anonymous)  │
                                  │  azureopendatastorage / nyctlc / yellow   │
                                  └───────────────────┬───────────────────────┘
                                                      │  HTTPS, anonymous read
                                                      │  the ONE public egress
┌─────────────────────────────────────────────────────┼───────────────────────────────────┐
│  Your subscription                                  │                                   │
│                                                     ▼                                   │
│   ┌────────────────────────────────────────────────────────────────────────────────┐   │
│   │  Azure Data Factory        managed VNet, public data plane disabled             │   │
│   │                                                                                 │   │
│   │   PL_Master_NycTaxi_Load ──▶ PL_Ingest ──▶ PL_Curate ──▶ PL_Load_Sql            │   │
│   │   PL_Backfill_NycTaxi_Yellow  (ForEach over a month range, sequential)          │   │
│   │                                                                                 │   │
│   │   IR-ManagedVNet ──── managed private endpoints ────┐                           │   │
│   └─────────────────────────────────────────────────────┼───────────────────────────┘   │
│                                                          │                              │
│   ┌──────────────────────────────────────────────────────▼───────────────────────────┐  │
│   │  ADLS Gen2   HNS on, no account keys, public access off                          │  │
│   │                                                                                  │  │
│   │    raw/       nyctlc/yellow/puYear=2024/puMonth=1/*.parquet   ← binary, as-is    │  │
│   │               nyctlc/reference/taxi_zone_lookup.csv                              │  │
│   │    curated/   nyctlc/yellow_trip/PickupYear=2024/PickupMonth=1/*.parquet         │  │
│   │    sandbox/   analyst scratch, lifecycle-deleted after 30 days                   │  │
│   │    synapse/   workspace system filesystem — not data                             │  │
│   │    logs/      SQL audit, ADF delete manifests                                    │  │
│   └──────────────────────▲────────────────────────────────┬─────────────────────────┘  │
│                          │ CETAS writes                   │ OPENROWSET reads           │
│   ┌──────────────────────┴────────────────────────────────▼─────────────────────────┐  │
│   │  Synapse Serverless SQL     database edw_lake, no dedicated pool, no Spark      │  │
│   │                                                                                  │  │
│   │    raw.vw_YellowTaxiTrip           source names, source types, nothing removed  │  │
│   │    curated.usp_Build_Yellow_Monthly  ← CETAS: types, dedupe, quality predicates │  │
│   │    curated.vw_YellowTaxiTrip       every built partition, one view              │  │
│   │    curated.vw_YellowTaxiTrip_Rejected  what was dropped, and why                │  │
│   │    serving.vw_*                    aggregates for direct BI over the lake       │  │
│   └──────────────────────────────────────────────────────────────────────────────────┘  │
│                                                          │                              │
│                                    ADF Copy (Parquet)    │                              │
│   ┌──────────────────────────────────────────────────────▼───────────────────────────┐  │
│   │  Azure SQL Database        public access off, Entra-only authentication          │  │
│   │                                                                                  │  │
│   │    stg.YellowTaxiTrip     heap, truncated per load, fast to write                │  │
│   │    fact.YellowTaxiTrip    clustered columnstore, partition-replaced per month    │  │
│   │    dim.Date .Vendor .RateCode .PaymentType .TaxiZone   each with an Unknown (-1) │  │
│   │    etl.usp_*              start / merge / quality / complete                     │  │
│   │    meta.LoadAudit .DataQualityRule .DataQualityResult                            │  │
│   │    rpt.vw_YellowTaxiTripDaily   the shape Power BI imports                       │  │
│   └──────────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                          │
│   Supporting: Key Vault · Log Analytics + 5 alerts · VNet with 10 private endpoints      │
│               peered to your existing self-hosted GitHub runner VNet                     │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Why four layers and not two

A common objection: Synapse serverless can query the raw Parquet directly, and
Power BI can query Synapse. Why land anything in Azure SQL at all?

Because the layers answer different questions, and collapsing them means one
layer answers all of them badly.

| Layer | Answers | Optimised for | Costs |
|---|---|---|---|
| **raw** | "What did they actually send us?" | Fidelity. Nothing is changed. | Storage only. Tiered to Cool after 30 days. |
| **curated** | "What do we believe is true?" | Repeatable transformation. Rebuildable from raw at any time. | Storage, plus TB scanned during each rebuild. |
| **serving (Synapse views)** | "Let me explore the lake." | Ad-hoc, arbitrary grain, no data movement. | Per TB scanned, per query. |
| **warehouse (Azure SQL)** | "Give me the same number, in 200 ms, a thousand times an hour." | Concurrency, sub-second response, joins to conformed dimensions. | Provisioned compute, whether queried or not. |

The economics decide it. Serverless is superb for a query someone runs twice a
week and terrible for a Power BI dashboard that thirty people refresh all
morning — you would pay per TB scanned, per refresh, forever. Azure SQL is the
opposite: fixed cost, unlimited queries, and it holds a star schema that a BI
tool can navigate.

So: **serverless for exploration and transformation, Azure SQL for serving.**
If your BI workload is genuinely light, you can delete the Azure SQL layer and
point Power BI at `serving.vw_*`. The template keeps them separate because
that is the shape that survives contact with a real reporting team.

---

## Responsibility boundaries

The single most useful thing to internalise about this platform is which
component owns what. Most operational confusion is a boundary being crossed.

### Data Factory owns *orchestration*, not *transformation*

ADF moves bytes and decides what runs next. It does not reshape data.

There is not a single Mapping Data Flow in this repository, and that is
deliberate. A data flow spins up a Spark cluster (a real per-hour cost, plus a
cold start), expresses logic in a GUI that diffs terribly in a pull request,
and duplicates capability that Synapse serverless already provides for less
money. The transformation lives in `curated.usp_Build_Yellow_Monthly`, which is
T-SQL — reviewable, testable, and executable by hand during an incident.

ADF's three jobs here:

1. Copy bytes (Open Datasets → raw, curated → staging).
2. Call things (`Script` and `SqlServerStoredProcedure` activities).
3. Handle failure (retries, the `Fail` activities, the audit-closing path).

### Synapse owns *transformation*, not *serving*

Serverless reads raw, applies types and rules, and writes curated. It also
exposes views for exploration. It does not serve dashboards, because per-TB
billing and dashboard refresh rates are a bad combination.

### Azure SQL owns *serving*, not *transformation*

The database receives already-conformed data. `etl.usp_Merge_YellowTaxiTrip`
resolves dimension keys and replaces a partition; it does not clean data. If a
row is wrong in Azure SQL, the fix belongs in the curated layer, and the
warehouse is repaired by re-running the load.

That rule is what makes the warehouse **reproducible**: drop the database,
re-deploy the DACPAC, re-run the backfill, and you get the same numbers.

### Terraform owns *infrastructure*, the Azure-Player tools own *code*

The awkward case is ADF and Synapse, where the two overlap. The line drawn here:

| Terraform | The deployment tools |
|---|---|
| The factory / workspace resource | pipelines, datasets |
| Managed virtual network | linked services |
| Managed private endpoints | triggers |
| Integration runtimes | dataflows, notebooks, SQL script tabs |
| Diagnostic settings | global parameters |
| Managed identity and RBAC | |

The rule that produces this split: **anything a linked service must be able to
*reference* has to exist before artifacts deploy.** A linked service pinning
`connectVia: IR-ManagedVNet` cannot deploy if that runtime does not exist, so
the runtime is infrastructure.

The consequence is the `excludes` list in
[`src/adf/deployment/publish-options.json`](../src/adf/deployment/publish-options.json).
If you ever see Terraform and the ADF pipeline flip-flopping an integration
runtime on alternate deployments, that exclusion has gone missing.

---

## The three-layer permission model

Getting ADF to read a Parquet file and write a row into Azure SQL requires
grants at three *independent* layers. Missing any one produces an error that
points at a different layer.

```
  Layer 1   AZURE RBAC                          managed by Terraform
            "Storage Blob Data Contributor"     infra/terraform/rbac.tf
            on the storage account.
            NOTE: ARM "Contributor" does NOT imply blob data access.
                        │
                        ▼
  Layer 2   NETWORK                             managed by Terraform
            A managed private endpoint out      modules/datafactory, modules/synapse
            of the managed VNet, APPROVED
            on the target side.
            (Approval is a separate step —
             scripts/Approve-PrivateEndpointConnections.ps1)
                        │
                        ▼
  Layer 3   DATABASE PRINCIPALS                 NOT Terraform. Cannot be.
            A contained user inside Azure SQL   src/sql/Scripts/PostDeploy/040_ServicePrincipals.sql
            and inside the serverless database. src/synapse/serverless/090_permissions.sql
            Azure RBAC has no visibility into
            SQL's own permission system.
```

Layer 3 is the one that surprises people. `CREATE USER [adf-name] FROM EXTERNAL
PROVIDER` is the only way to make an Azure managed identity into a SQL
principal, and no amount of RBAC substitutes for it. The symptom is:

```
Login failed for user '<token-identified principal>'
```

which names neither the identity nor the database.
[12-troubleshooting](12-troubleshooting.md#adf-cannot-log-in-to-azure-sql) maps
this and its relatives back to the layer that actually caused them.

---

## Data flow, in detail

### Stage 1 — ingest

`PL_Ingest_NycTaxi_Yellow(puYear, puMonth)`

1. Build both paths as pipeline variables, so the folder convention appears
   twice in the pipeline rather than once per activity.
2. `Get Metadata` with `fieldList: [exists]` — **only** `exists`. Asking for
   `childItems` on a folder that does not exist throws a generic failure
   instead of returning `false`, turning "that month is not published yet" into
   an opaque copy error.
3. If absent: `Fail` with `SOURCE_PARTITION_NOT_PUBLISHED`. Failing loudly
   beats succeeding with zero rows — an empty partition propagates silently all
   the way to a gap in a report weeks later.
4. Binary copy with `validateDataConsistency: true`, so a truncated transfer
   fails here rather than landing a corrupt Parquet file that Synapse rejects
   hours later.

**Why binary.** A raw zone should hold the bytes as published. A Parquet→Parquet
copy makes ADF deserialise and re-serialise every file: DIUs spent for no
benefit, possible silent physical type changes, and the loss of any ability to
prove the file you hold is the file they published.

### Stage 2 — curate

`PL_Curate_NycTaxi_Yellow(puYear, puMonth)`

1. `Get Metadata` → `If` → `Delete` the curated partition folder.
2. `Script` activity: `EXEC curated.usp_Build_Yellow_Monthly` — the CETAS.
3. `Script` activity: read the row count back.
4. `If` count is zero: `Fail` with `CURATED_PARTITION_EMPTY`.

**Why the delete.** CETAS refuses to write into a folder that already contains
files, and `DROP EXTERNAL TABLE` removes only metadata — the Parquet files
remain. Serverless has no `DELETE` and cannot remove them. Something outside
Synapse must clear the folder, and that something is the ADF `Delete` activity.
Skip it and every re-run fails with

```
Cannot create external table. External table location already exists.
```

**Why the row-count check.** CETAS reports success when it writes zero rows.
Reading the count back converts silent data loss into a loud failure, which is
the entire point of having a curated layer.

**What the CETAS actually does** ([070_procs_curate.sql](../src/synapse/serverless/070_procs_curate.sql)):

- Money columns become `DECIMAL(10,2)`. The source stores doubles; a double
  cannot represent `0.10` exactly, and summing tens of millions of them gives a
  total that differs run to run in the last decimal place. Finance users notice.
- `TripKey` = `MD5` of the natural key. Deterministic, so a rebuilt partition
  produces identical keys and the downstream load stays idempotent.
- Duplicates removed by `ROW_NUMBER` over the natural key. The TLC files
  contain genuine exact duplicates.
- **Partition leakage excluded.** The raw folders use the publisher's
  `puYear`/`puMonth`, but the files contain rows whose `tpepPickupDateTime`
  falls in a different month. Carried through, those strays would be inserted by
  January's load and deleted by February's — and vanish. The `WHERE` clause
  re-derives the partition from the timestamp, not the folder.

### Stage 3 — load

`PL_Load_Sql_YellowTrip(puYear, puMonth)`

1. `Lookup` → `etl.usp_Start_Load` returns a `LoadId`. A Lookup rather than a
   Stored Procedure activity because only Lookup reads a value back.
2. `Copy` curated Parquet → `stg.YellowTaxiTrip`, `preCopyScript` truncates.
3. `etl.usp_Merge_YellowTaxiTrip` — partition delete-then-insert in one
   transaction.
4. `etl.usp_RunDataQualityChecks` — every enabled rule; `RAISERROR` on a
   blocking failure.
5. `etl.usp_Complete_Load`, or `Fail Load` on the failure path.

**The most important five lines in the repository** are the empty-staging guard
in step 3:

```sql
IF @rowsStaged = 0
BEGIN
    RAISERROR('stg.YellowTaxiTrip is empty. Refusing to replace fact partition %d-%d with nothing.', 16, 1, ...);
    RETURN;
END
```

Without it, a Copy activity that silently transferred zero rows would `DELETE`
the existing partition and `INSERT` nothing — turning a transient upstream
problem into deleted production data.

---

## What is deliberately absent

| Not here | Why |
|---|---|
| Dedicated SQL pool | Serverless plus Azure SQL covers this workload. A dedicated pool costs money whether queried or not and is a different operational discipline. |
| Spark pools / notebooks | Nothing here needs Spark. Adding one because it is available is how platforms become unaffordable. |
| Mapping Data Flows | Spark under a GUI. Diffs badly, costs more, duplicates what serverless does in T-SQL. |
| Delta Lake | Parquet plus whole-partition replacement gives idempotency without the metadata layer. Adopt Delta when you need time travel or concurrent writers. |
| Microsoft Purview | Genuinely valuable, genuinely a separate project. |
| Databricks | Overlaps Synapse serverless for this workload. |
| Self-hosted integration runtime | Nothing on-premises is being read. Add one when it is. |
| Azure Monitor Private Link Scope | Log Analytics ingestion stays public. AMPLS is a real hardening step and a real complexity step — flagged in [04-networking](04-networking.md#what-is-still-public), not implemented. |

---

## Environments

Three, promoted strictly in order.

| | dev | test | prod |
|---|---|---|---|
| Git-connected ADF | yes (optional) | no | no |
| Hand-editing in Studio | expected | forbidden | forbidden |
| SQL `BlockOnPossibleDataLoss` | false | **true** | **true** |
| Drift blocking | false | **true** | **true** |
| Azure SQL SKU | `GP_S_Gen5_2`, auto-pause 60m | `GP_S_Gen5_2`, auto-pause 360m | `GP_Gen5_4`, provisioned |
| Storage replication | LRS | ZRS | ZRS |
| Trigger `TR_Monthly_NycTaxi_Load` | Stopped | Stopped | **Started** |
| Approval to deploy | none | required reviewers | required reviewers |
| Deployable from | any branch | `main` only | `main` only |

**Test exists to rehearse production.** Every safety setting in the test publish
profile is identical to prod. If you find yourself relaxing one to get a
deployment through, you have just found something that will fail in prod —
which is precisely what test is for.

---

Next: [01 — Prerequisites](01-prerequisites.md)
