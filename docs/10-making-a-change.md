# 10 — Making a change

Four worked examples, end to end, with the actual code.

| | |
|---|---|
| [1](#example-1-tuning-a-copy-activity) | Tuning a copy activity — the smallest possible change |
| [2](#example-2-adding-a-column-end-to-end) | Adding a column, through all four layers |
| [3](#example-3-adding-a-data-quality-rule) | Adding a data quality rule — no deployment needed |
| [4](#example-4-adding-a-new-source) | Adding a new source (green taxis) |

---

## Example 1: tuning a copy activity

**Goal.** The staging load is slow in prod. Raise the write batch size from
100,000 to 500,000 — in prod only.

**Time:** ten minutes.

### The wrong way

Edit `src/adf/pipeline/PL_Load_Sql_YellowTrip.json` and change
`writeBatchSize`. That changes it in all three environments.

### The right way

Per-environment values belong in the config CSV, never in the artifact.

`src/adf/deployment/config-prod.csv`:

```
type,name,path,value
trigger,TR_Monthly_NycTaxi_Load,runtimeState,Started
...
pipeline,PL_Load_Sql_YellowTrip,activities[2].typeProperties.sink.writeBatchSize,500000
```

Then open a PR. `pr-validate` runs; a reviewer sees a one-line diff that says
exactly what it does.

### But `activities[2]` is fragile

It breaks the moment somebody reorders activities in Studio, and it breaks
**silently** — the tool patches whatever now sits at index 2. For anything you
expect to tune more than once, promote it to a pipeline parameter instead:

`PL_Load_Sql_YellowTrip.json`:

```json
"parameters": {
    "puYear":  { "type": "int", "defaultValue": 2024 },
    "puMonth": { "type": "int", "defaultValue": 1 },
    "writeBatchSize": {
        "type": "int",
        "defaultValue": 100000,
        "description": "Rows per bulk-insert batch into stg.YellowTaxiTrip. Raise in prod where the database has more log throughput."
    }
}
```

and in the sink:

```json
"writeBatchSize": {
    "value": "@pipeline().parameters.writeBatchSize",
    "type": "Expression"
}
```

Now the CSV row is stable and readable:

```
pipeline,PL_Load_Sql_YellowTrip,parameters.writeBatchSize.defaultValue,500000
```

### Deploying

Merge to `main`. `adf-cd.yml` fires on the `src/adf/**` path filter:
dev → test (approval) → prod (approval). Nothing else deploys.

---

## Example 2: adding a column, end to end

**Goal.** Surface the TLC's `congestion_surcharge` as
`CongestionSurchargeAmount`, all the way from raw Parquet to Power BI.

**Time:** two to three hours including deployments. Touches all four layers.

### Step 0 — confirm it exists

Never trust a data dictionary. In Synapse Studio (`edw_lake`):

```sql
EXEC sp_describe_first_result_set N'
    SELECT TOP (1) *
    FROM OPENROWSET(
        BULK ''nyctlc/yellow/puYear=2024/puMonth=1/*.parquet'',
        DATA_SOURCE = ''eds_raw'', FORMAT = ''PARQUET''
    ) AS src;
';
```

Look for `congestion_surcharge` and note its `system_type_name`. Say it is
`float`, and present only from 2019 onward — so it must be **nullable**
everywhere downstream.

### Step 1 — the raw view

`src/synapse/serverless/060_views_raw.sql`:

```sql
    src.tollsAmount,
    src.totalAmount,
    src.congestion_surcharge,          -- ADDED
```

and in the `WITH` clause:

```sql
        totalAmount          FLOAT        ,
        congestion_surcharge FLOAT            -- ADDED. Nullable: absent before 2019.
```

> Adding a column to an explicit `WITH` clause is safe for **existing**
> partitions: serverless returns NULL when a Parquet file lacks the column.
> Renaming or retyping one is not — that breaks every historical partition at
> once.

### Step 2 — the curated CETAS

`src/synapse/serverless/070_procs_curate.sql` — in the projection list, the
inner `SELECT`, and the outer column list. All three, or the dynamic SQL will
not compile:

```sql
    , TotalAmount
    , CongestionSurchargeAmount        -- ADDED (outer list)
    , SourceFileName
```

```sql
        , TotalAmount               = TRY_CAST(r.totalAmount AS DECIMAL(10,2))
        , CongestionSurchargeAmount = TRY_CAST(r.congestion_surcharge AS DECIMAL(10,2))   -- ADDED
```

`DECIMAL(10,2)`, not `FLOAT`, for the reason in the file header: a double
cannot represent `0.10` exactly, and summing millions of them gives a total that
differs run to run in the last decimal place.

### Step 3 — the curated view

`src/synapse/serverless/080_views_curated.sql`, in both the projection and the
`WITH`:

```sql
    c.TotalAmount,
    c.CongestionSurchargeAmount,       -- ADDED
```

```sql
        TotalAmount               DECIMAL(10,2),
        CongestionSurchargeAmount DECIMAL(10,2),      -- ADDED
```

### Step 4 — Azure SQL staging and fact

`src/sql/EdwTaxi.Database/Tables/stg/YellowTaxiTrip.sql`:

```sql
    [TotalAmount]               DECIMAL(10,2) NULL,
    [CongestionSurchargeAmount] DECIMAL(10,2) NULL,   -- ADDED
```

Column names must match the curated Parquet **exactly** — the Copy activity
matches by name, and `DS_Lake_Curated_Parquet` has `"schema": []` so there is no
explicit mapping to update.

`Tables/fact/YellowTaxiTrip.sql`:

```sql
    [TotalAmount]               DECIMAL(10,2) NULL,
    [CongestionSurchargeAmount] DECIMAL(10,2) NULL,   -- ADDED
```

**Nullable.** A `NOT NULL` column would require `GenerateSmartDefaults`, which
is False on purpose — it would quietly fill the fact table with zeros that look
like real measurements.

### Step 5 — the merge

`Programmability/Stored Procedures/etl.usp_Merge_YellowTaxiTrip.sql`, in the
`INSERT` column list and the `SELECT`:

```sql
                TipAmount, TollsAmount, TotalAmount,
                CongestionSurchargeAmount,                    -- ADDED
                LoadId, LoadedAtUtc
```

```sql
                s.TotalAmount,
                s.CongestionSurchargeAmount,                  -- ADDED
                @LoadId,
```

### Step 6 — the reporting view

`Programmability/Views/rpt.vw_YellowTaxiTripDaily.sql`:

```sql
    TotalAmount      = SUM(f.TotalAmount),
    TotalCongestionSurcharge = SUM(f.CongestionSurchargeAmount),   -- ADDED
```

No `GROUP BY` change — it is an aggregate.

### Step 7 — a data quality rule

New column, new way to be wrong. Add rule 9 in
`Scripts/PostDeploy/030_DataQualityRules.sql`:

```sql
    (
        9,
        'CongestionSurchargePresentFrom2019',
        'fact.YellowTaxiTrip',
        'Warning',
        1,
        0,
        N'SELECT FailedCount = CASE WHEN @PickupYear >= 2019 AND NOT EXISTS (SELECT 1 FROM fact.YellowTaxiTrip WHERE PickupYear = @PickupYear AND PickupMonth = @PickupMonth AND CongestionSurchargeAmount IS NOT NULL) THEN 1 ELSE 0 END;',
        N'From 2019 the TLC records a congestion surcharge on Manhattan trips. A month with no non-NULL value at all means the column was dropped upstream or the curated build did not pick it up. Warning rather than Blocking: the rest of the row is still correct.'
    )
```

Note the trailing comma on rule 8 in the `VALUES` list.

### Step 8 — deploy, in order

The order matters. Curated must produce the column before staging expects it.

```bash
git checkout -b feat/congestion-surcharge
# ... the seven edits ...
git commit -am "Add CongestionSurchargeAmount from raw through to rpt"
git push -u origin feat/congestion-surcharge
gh pr create
```

`pr-validate` builds the DACPAC (catching, for instance, the merge procedure
naming a column the table does not have) and plans dev.

On merge:

1. `synapse-cd` — raw view, CETAS, curated view.
2. `sql-cd` — staging, fact, merge, reporting view, the new rule.
   `DeployReport` will show `Add Column`, no data-loss alert.
3. `adf-cd` — nothing to do; no artifact changed.

### Step 9 — backfill

Existing curated partitions do not have the column. New loads do. To make
history consistent:

```bash
gh workflow run data-backfill.yml \
  -f environment=dev \
  -f start_year_month=201901 \
  -f end_year_month=202412 \
  -f initialize_reference_data=false
```

The rebuild is idempotent: the curate stage deletes and re-writes each curated
partition, and the load stage replaces each fact partition.

Until it finishes, `CongestionSurchargeAmount` is NULL for older months. That
is honest — it is genuinely unknown — and `rpt.vw_YellowTaxiTripDaily` sums it,
so NULLs contribute zero.

### If instead you were RENAMING a column

`BlockOnPossibleDataLoss=True` will refuse, because sqlpackage sees a drop plus
an add. Three deployments:

1. Add the new column (nullable), backfill it in an idempotent post-deploy
   script.
2. Switch every reader — views, curated CETAS, staging.
3. Drop the old column, with `/p:BlockOnPossibleDataLoss=False` on the command
   line for that one deployment.

Full detail: [08-azure-sql](08-azure-sql.md#making-a-schema-change-that-loses-no-data).

---

## Example 3: adding a data quality rule

**Goal.** Alert if more than 1% of a month's trips have zero distance but a fare
over $10 — a meter fault pattern.

**Time:** five minutes. **No deployment.**

Rules are rows, not code. Insert one:

```sql
INSERT INTO meta.DataQualityRule
    (RuleId, RuleName, TargetObject, Severity, IsEnabled, FailureThreshold, RuleSql, [Description])
VALUES
(
    10,
    'ZeroDistanceHighFare',
    'fact.YellowTaxiTrip',
    'Warning',
    1,
    5000,                                  -- ~0.17% of a typical 3M-row month
    N'SELECT FailedCount = COUNT_BIG(*)
      FROM fact.YellowTaxiTrip
      WHERE PickupYear = @PickupYear
        AND PickupMonth = @PickupMonth
        AND ISNULL(TripDistanceMiles, 0) = 0
        AND FareAmount > 10.00;',
    N'Zero distance with a fare over $10 suggests a meter fault or a cancelled trip still charged. Some occur naturally; the threshold is set from the historical rate.'
);
```

Test it against a loaded month before trusting it:

```sql
DECLARE @PickupYear INT = 2024, @PickupMonth INT = 1;
SELECT FailedCount = COUNT_BIG(*)
FROM fact.YellowTaxiTrip
WHERE PickupYear = @PickupYear AND PickupMonth = @PickupMonth
  AND ISNULL(TripDistanceMiles, 0) = 0 AND FareAmount > 10.00;
```

Set `FailureThreshold` from what that returns, plus headroom. A rule that fires
every month trains people to ignore it, which costs you the alert you actually
needed.

### Then commit it

An ad-hoc `INSERT` disappears the moment somebody rebuilds the environment. Add
it to `Scripts/PostDeploy/030_DataQualityRules.sql` so it is reproducible. The
`MERGE` there is idempotent — the row you already inserted is matched and
updated, not duplicated.

> `IsEnabled` is deliberately **not** updated by that `MERGE`. An operator who
> disables a noisy rule at 02:00 during an incident should not find it silently
> re-enabled by the next deployment.

---

## Example 4: adding a new source

**Goal.** Add NYC **green** taxi trips alongside yellow.

**Time:** half a day. This is the example to read if you are adapting the
template to your own data.

The green dataset lives at
`nyctlc/green/puYear=*/puMonth=*/` in Open Datasets, with a similar but not
identical schema — `lpep_pickup_datetime` rather than `tpep_pickup_datetime`,
plus `ehail_fee` and `trip_type`.

### What you reuse unchanged

Everything structural: the medallion layout, all four CI/CD pipelines, the
permission model, the audit and data quality framework, the reference
dimensions, `dim.Date`, `dim.TaxiZone`, all the networking.

### 1. Lake

`infra/terraform/main.tf` — add directories to the `filesystems` local:

```hcl
raw = {
  directories = [
    "nyctlc", "nyctlc/yellow", "nyctlc/green",     # green already listed
    "nyctlc/reference", "_quarantine",
  ]
}
curated = {
  directories = [
    "nyctlc", "nyctlc/yellow_trip",
    "nyctlc/green_trip",                            # ADD
    "nyctlc/taxi_zone",
  ]
}
```

### 2. Synapse

`060_views_raw.sql` — a new view, using the source's own column names:

```sql
CREATE OR ALTER VIEW raw.vw_GreenTaxiTrip
AS
SELECT
    PickupYear  = CAST(src.filepath(1) AS INT),
    PickupMonth = CAST(src.filepath(2) AS INT),
    src.vendorID,
    src.lpepPickupDatetime,             -- note: lpep, not tpep
    src.lpepDropoffDatetime,
    src.passengerCount,
    src.tripDistance,
    src.puLocationId,
    src.doLocationId,
    src.rateCodeID,
    src.storeAndFwdFlag,
    src.paymentType,
    src.fareAmount,
    src.extra,
    src.mtaTax,
    src.tipAmount,
    src.tollsAmount,
    src.ehailFee,                       -- green only
    src.improvementSurcharge,
    src.totalAmount,
    src.tripType,                       -- green only
    SourceFileName = src.filename()
FROM OPENROWSET(
        BULK 'nyctlc/green/puYear=*/puMonth=*/*.parquet',
        DATA_SOURCE = 'eds_raw', FORMAT = 'PARQUET'
     )
     WITH ( /* ... verify with util/inspect_source_schema.sql first ... */ ) AS src;
GO
```

`070_procs_curate.sql` — copy `curated.usp_Build_Yellow_Monthly` to
`curated.usp_Build_Green_Monthly`. **Keep every guard**: the parameter range
checks, the partition-leakage `WHERE`, the duplicate rank, the `already exists`
error translation. They are not yellow-specific.

`080_views_curated.sql` — `curated.vw_GreenTaxiTrip` and
`curated.vw_GreenTaxiTrip_Rejected`.

`090_permissions.sql` — no change. Grants are schema-level.

### 3. Data Factory

Two new pipelines, copied and adjusted:

- `PL_Ingest_NycTaxi_Green` — same shape; source folder `green/…`, sink
  `nyctlc/green/…`.
- `PL_Curate_NycTaxi_Green` — same shape; calls
  `curated.usp_Build_Green_Monthly`, purges
  `nyctlc/green_trip/PickupYear=…/PickupMonth=…`.
- `PL_Load_Sql_GreenTrip` — same shape; `stg.GreenTaxiTrip`,
  `etl.usp_Merge_GreenTaxiTrip`.

Then extend the master to run both, in parallel where they do not contend:

```json
{
    "name": "Ingest Green Raw",
    "type": "ExecutePipeline",
    "dependsOn": [],
    "typeProperties": {
        "pipeline": { "referenceName": "PL_Ingest_NycTaxi_Green", "type": "PipelineReference" },
        "waitOnCompletion": true,
        "parameters": {
            "puYear":  { "value": "@pipeline().parameters.puYear",  "type": "Expression" },
            "puMonth": { "value": "@pipeline().parameters.puMonth", "type": "Expression" }
        }
    }
}
```

Ingest and curate can run in parallel with yellow — different folders, different
external tables. **The two load stages cannot**: both truncate
`stg.*`-scoped tables and `PL_Load_Sql_*` is pinned to concurrency 1. Chain them,
or give green its own staging table.

No new datasets or linked services. `DS_Lake_Binary`,
`DS_Lake_Curated_Parquet` and `DS_AzureSql_Table` are parameterised precisely so
that a new entity needs no new artifacts.

### 4. Azure SQL

- `Tables/stg/GreenTaxiTrip.sql` — matching the green curated Parquet exactly.
- `Tables/fact/GreenTaxiTrip.sql` — clustered columnstore, same pattern.
- `etl.usp_Merge_GreenTaxiTrip.sql` — copy, keep the empty-staging guard.
- `030_DataQualityRules.sql` — add the same rules with
  `TargetObject = 'fact.GreenTaxiTrip'`.

> `etl.usp_RunDataQualityChecks` filters on `TargetObject = 'fact.YellowTaxiTrip'`.
> Parameterise it — add a `@TargetObject` parameter defaulting to the yellow
> table — rather than writing a second procedure.

- `rpt.vw_GreenTaxiTripDaily`, or better, a `rpt.vw_TripDaily` that
  `UNION ALL`s both with a `ServiceType` column. The second is what a report
  author actually wants.

### 5. Deploy

Merge, and the four pipelines fire on their path filters. Then:

```bash
gh workflow run data-backfill.yml \
  -f environment=dev -f start_year_month=202401 -f end_year_month=202401
```

### The general shape

Adapting to *any* new source is the same five moves:

1. A raw view over the source layout, in the source's vocabulary.
2. A curate procedure that types, deduplicates and applies quality predicates.
3. A curated view plus its rejected counterpart.
4. Staging and fact tables, plus a merge procedure with the empty-staging guard.
5. ADF pipelines that call them, and data quality rules that check them.

Everything else — networking, identity, CI/CD, audit, promotion — is already
built and does not change.

---

Next: [11 — Operations runbook](11-operations-runbook.md)
