# 11 — Operations runbook

What to do when an alert fires. One section per alert, each anchored so the
alert's own description links straight here.

---

## First five minutes, whatever the alert

```sql
-- Azure SQL. The single most useful query in the platform.
SELECT TOP (10) *
FROM meta.vw_LoadHistory
ORDER BY LoadId DESC;
```

| Column | Tells you |
|---|---|
| `Status` | `Running` past its window means stuck, not slow |
| `PartitionKey` | which month |
| `RowsStaged` vs `RowsInserted` | rows dropped between staging and fact |
| `DqBlockingFailed` | it loaded, and the data is wrong |
| `PipelineRunId` | pastes straight into the ADF monitor |

Then, in Log Analytics, the saved search **EDW-ActivityFailures**:

```kql
ADFActivityRun
| where TimeGenerated > ago(24h)
| where Status == "Failed"
| project TimeGenerated, PipelineName, ActivityName,
          ErrorCode    = tostring(parse_json(Error).errorCode),
          ErrorMessage = tostring(parse_json(Error).message),
          PipelineRunId
| order by TimeGenerated desc
```

---

## `alert-<env>-adf-pipeline-failed` {#adf-pipeline-failure}

**Sev 1 in prod.** One or more pipeline runs failed. The load did not happen.

### Triage

Find the failing activity:

```bash
RG=$(terraform  -chdir=infra/terraform output -raw resource_group_name)
ADF=$(terraform -chdir=infra/terraform output -raw data_factory_name)

az datafactory pipeline-run query-by-factory -g "$RG" --factory-name "$ADF" \
  --last-updated-after  "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --last-updated-before "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --query "value[?status=='Failed'].{pipeline:pipelineName, run:runId, msg:message}" -o table
```

### By error code

| Error code | Meaning | Action |
|---|---|---|
| `SOURCE_PARTITION_NOT_PUBLISHED` | The TLC has not published that month yet. | **Not a fault.** The TLC lags ~2 months. Confirm, then wait and re-run. |
| `CURATED_PARTITION_EMPTY` | Raw landed; every row failed the quality predicates. | See below. |
| `BACKFILL_RANGE_INVALID` | Bad `startYearMonth`/`endYearMonth`. | Re-run with valid YYYYMM. |
| `already exists` in the curate stage | The curated folder was not purged. | See [CETAS cannot overwrite](12-troubleshooting.md#cetas-cannot-overwrite). |
| `Login failed for user '<token-identified principal>'` | Missing SQL principal — layer 3. | [12-troubleshooting](12-troubleshooting.md#adf-cannot-log-in-to-azure-sql). |
| `stg.YellowTaxiTrip is empty` | The guard worked. The Copy transferred nothing. | Investigate the curated partition; **do not** bypass the guard. |

### `CURATED_PARTITION_EMPTY`

Raw arrived but nothing survived. Find out what was rejected — in Synapse
(`edw_lake`):

```sql
SELECT RejectReason, RejectedRows = COUNT_BIG(*)
FROM curated.vw_YellowTaxiTrip_Rejected
WHERE PickupYear = 2024 AND PickupMonth = 3
GROUP BY RejectReason
ORDER BY RejectedRows DESC;
```

| Dominant reason | Likely cause |
|---|---|
| `PartitionMismatch` | The publisher mis-filed the month — every row's timestamp is outside the folder. Verify against `raw.vw_YellowTaxiTrip`; if genuine, the folder is wrong and the source needs re-fetching. |
| `NullPickupTimestamp` | Schema change upstream. Run `util/inspect_source_schema.sql`. |
| `Duplicate` | The same file landed twice. Check `raw/nyctlc/yellow/…` for duplicate part files. |

### Re-running

Every stage is idempotent for a given month. Re-run the smallest thing that
failed:

```bash
# Whole month
az datafactory pipeline create-run -g "$RG" --factory-name "$ADF" \
  --name PL_Master_NycTaxi_Load --parameters '{"puYear":2024,"puMonth":3}'

# Just the load, if ingest and curate succeeded
az datafactory pipeline create-run -g "$RG" --factory-name "$ADF" \
  --name PL_Load_Sql_YellowTrip --parameters '{"puYear":2024,"puMonth":3}'
```

Or the `data-backfill` workflow for a range.

### Before re-running, clear a stuck audit row

```sql
SELECT * FROM meta.LoadAudit WHERE Status = 'Running';
```

`etl.usp_Start_Load` auto-reaps anything Running for more than four hours. To do
it now:

```sql
UPDATE meta.LoadAudit
SET Status = 'Failed', CompletedAtUtc = SYSUTCDATETIME(),
    Message = 'Manually closed by <you> after run <runId> was cancelled.'
WHERE LoadId = <id>;
```

---

## `alert-<env>-adf-pipeline-overrunning` {#pipeline-overrun}

**Sev 2 in prod.** A pipeline has been running longer than the SLA. It has not
failed — it will simply not finish in time.

### Where is it?

```kql
ADFActivityRun
| where TimeGenerated > ago(6h)
| summarize arg_max(TimeGenerated, Status, ActivityName, PipelineName, Start) by ActivityRunId
| where Status == "InProgress"
| extend RunningMinutes = datetime_diff('minute', now(), Start)
| project PipelineName, ActivityName, Start, RunningMinutes
| order by RunningMinutes desc
```

| Stuck activity | Usual cause | Action |
|---|---|---|
| `Copy Raw Files` | Open Datasets slow, or a first-run managed-VNet cold start (60–90s). | Wait. Raise `dataIntegrationUnits` if chronic. |
| `Build Curated Partition` | Raw is in the **Archive** tier — rehydration takes hours. | See below. |
| `Load Staging Table` | Azure SQL resuming from auto-pause, or log throughput saturated. | Check `sql_cpu`; consider a larger SKU. |
| `Merge Into Fact` | Columnstore rebuild, or blocking. | Query `sys.dm_exec_requests` for a blocker. |

### Archive-tier rehydration

The lifecycle policy moves raw to Archive after 180 days (365 in prod). Reading
an archived blob requires rehydration — hours, not minutes.

```bash
az storage blob list --account-name "$STORAGE" -c raw \
  --prefix "nyctlc/yellow/puYear=2019/puMonth=3/" --auth-mode login \
  --query "[].{name:name, tier:properties.blobTier}" -o table
```

To rehydrate:

```bash
az storage blob set-tier --account-name "$STORAGE" -c raw \
  -n "nyctlc/yellow/puYear=2019/puMonth=3/part-00000.parquet" \
  --tier Hot --rehydrate-priority High --auth-mode login
```

`High` priority is under an hour and costs more; `Standard` is up to 15 hours.
Then re-run the curate stage.

### Cancelling

```bash
az datafactory pipeline-run cancel -g "$RG" --factory-name "$ADF" \
  --run-id <runId> --is-recursive true
```

`--is-recursive` matters — without it the child pipelines keep running. Then
close the audit row (above) before re-running.

---

## `alert-<env>-synapse-data-processed` {#serverless-cost-spike}

**Sev 3.** Serverless processed more than the threshold in one hour. Somebody is
spending real money.

### Who, and on what

Log Analytics saved search **EDW-ServerlessCostByPrincipal**:

```kql
SynapseBuiltinSqlPoolRequestsEnded
| where TimeGenerated > ago(4h)
| extend GB = DataProcessedBytes / pow(1024.0, 3)
| project TimeGenerated, LoginName, GB = round(GB, 2),
          DurationSec = round(DurationMs / 1000.0, 1),
          Query = substring(Command, 0, 300)
| order by GB desc
| take 20
```

### If it is a person

Almost always a missing partition filter:

```sql
-- ~40 MB scanned
WHERE PickupYear = 2024 AND PickupMonth = 3

-- the whole lake: PickupDate is inside the files
WHERE PickupDate = '2024-03-15'
```

Send them
[07-synapse](07-synapse.md#cost-rules-for-anyone-querying-these) and the saved
SQL script `SQL_Explore_YellowTaxi` in Studio, which demonstrates both forms.

For a repeat offender, consider a workload constraint — Synapse serverless
supports a per-user data-processed limit at workspace level:

```sql
-- in master on the serverless endpoint
ALTER DATABASE SCOPED CONFIGURATION SET RESULT_SET_CACHING = ON;
```

and set the daily/weekly/monthly caps in Studio → Manage → SQL pools →
Built-in → Cost control.

### If it is the pipeline

A full-year rebuild scans roughly 40 GB and is expected. Check whether a
backfill is running before treating it as an incident. If the *routine* monthly
build has grown, look for a curated partition that was never purged and is now
being scanned twice.

---

## `alert-<env>-sql-cpu` {#sql-cpu}

**Sev 3.** CPU above threshold for 30 minutes.

### Is it the load, or a query?

```sql
SELECT
    r.session_id, r.status, r.command, r.wait_type, r.wait_time,
    r.cpu_time, r.total_elapsed_time,
    t.text
FROM sys.dm_exec_requests AS r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.session_id <> @@SPID
ORDER BY r.cpu_time DESC;
```

Is a load running?

```sql
SELECT * FROM meta.vw_LoadHistory WHERE Status = 'Running';
```

**If a load is running:** high CPU during the merge is normal. Compare against
history:

```sql
SELECT PartitionKey, DurationMinutes, RowsInserted, StartedAtUtc
FROM meta.vw_LoadHistory
WHERE TargetObject = 'fact.YellowTaxiTrip' AND Status = 'Succeeded'
ORDER BY LoadId DESC
OFFSET 0 ROWS FETCH NEXT 20 ROWS ONLY;
```

A duration that has doubled with a similar row count is a regression — usually a
new index, a changed statistic, or the fact table having grown past a threshold.

**If no load is running:** it is a query. `sys.dm_exec_requests` above names it.
Common causes: a report doing `SELECT *` from `fact.YellowTaxiTrip` without a
partition filter, or an unfolded Power BI DirectQuery.

### Immediate relief

```sql
-- Confirm what you are about to kill first.
KILL <session_id>;
```

Scaling up is a portal or CLI operation with no downtime on a General Purpose
database:

```bash
az sql db update -g "$RG" -s "$SERVER" -n edw --service-objective GP_Gen5_8
```

Remember to scale back, and to update `sql_sku_name` in `prod.tfvars` if the
change should stick — otherwise drift detection will flag it on Monday, which is
the system working correctly.

---

## `alert-<env>-sql-storage` {#sql-storage}

**Sev 2.** Allocated storage above threshold. The next load will fail with
"Could not allocate space".

### What is using it

```sql
SELECT TOP (20)
    SchemaName = s.name,
    TableName  = t.name,
    RowCount   = p.rows,
    TotalMB    = CAST(SUM(a.total_pages) * 8 / 1024.0 AS DECIMAL(10,1)),
    UsedMB     = CAST(SUM(a.used_pages)  * 8 / 1024.0 AS DECIMAL(10,1))
FROM sys.tables t
JOIN sys.schemas s      ON s.schema_id = t.schema_id
JOIN sys.indexes i      ON i.object_id = t.object_id
JOIN sys.partitions p   ON p.object_id = i.object_id AND p.index_id = i.index_id
JOIN sys.allocation_units a ON a.container_id = p.partition_id
GROUP BY s.name, t.name, p.rows
ORDER BY TotalMB DESC;
```

### Quick wins, in order

**1. Staging left full.** It should be empty between loads.

```sql
SELECT COUNT_BIG(*) FROM stg.YellowTaxiTrip;   -- expect 0
TRUNCATE TABLE stg.YellowTaxiTrip;
```

**2. Columnstore not compressed.** Rows in open or closed rowgroups are stored
uncompressed.

```sql
SELECT state_desc, RowGroups = COUNT(*), Rows = SUM(total_rows)
FROM sys.dm_db_column_store_row_group_physical_stats
WHERE object_id = OBJECT_ID('fact.YellowTaxiTrip')
GROUP BY state_desc;

-- If OPEN/CLOSED dominate:
ALTER INDEX CCI_fact_YellowTaxiTrip ON fact.YellowTaxiTrip
    REORGANIZE WITH (COMPRESS_ALL_ROW_GROUPS = ON);
```

Typically recovers a lot — uncompressed columnstore is roughly 10× the size.

**3. Old audit history.**

```sql
DELETE FROM meta.DataQualityResult WHERE CheckedAtUtc < DATEADD(YEAR, -2, SYSUTCDATETIME());
DELETE FROM meta.LoadAudit
WHERE StartedAtUtc < DATEADD(YEAR, -2, SYSUTCDATETIME())
  AND NOT EXISTS (SELECT 1 FROM meta.DataQualityResult r WHERE r.LoadId = meta.LoadAudit.LoadId);
```

Order matters — the foreign key.

**4. Grow the database.** Update `sql_max_size_gb` in tfvars and deploy through
`infra-cd`, so the change is in code rather than drift.

---

## Routine checks

### Every morning (two minutes)

```sql
SELECT TOP (5) PartitionKey, Status, StartedAtUtc, DurationMinutes,
               RowsInserted, DqBlockingFailed
FROM meta.vw_LoadHistory
ORDER BY LoadId DESC;
```

### Every week

Data quality trend — a rule quietly returning 400 failures every month for a
year is a different, worse problem than one that fails once:

```sql
SELECT
    r.RuleName, r.Severity,
    Runs      = COUNT(*),
    Failures  = SUM(CASE WHEN d.Passed = 0 THEN 1 ELSE 0 END),
    AvgFailed = AVG(CAST(d.FailedCount AS DECIMAL(18,2))),
    MaxFailed = MAX(d.FailedCount)
FROM meta.DataQualityResult d
JOIN meta.DataQualityRule   r ON r.RuleId = d.RuleId
WHERE d.CheckedAtUtc > DATEADD(DAY, -90, SYSUTCDATETIME())
GROUP BY r.RuleName, r.Severity
ORDER BY Failures DESC;
```

Load durations:

```kql
ADFPipelineRun
| where TimeGenerated > ago(90d)
| summarize arg_max(TimeGenerated, Status, Start, End) by RunId, PipelineName
| where Status == "Succeeded" and PipelineName == "PL_Master_NycTaxi_Load"
| extend Minutes = datetime_diff('minute', End, Start)
| summarize P50 = percentile(Minutes, 50), P95 = percentile(Minutes, 95) by bin(Start, 7d)
| render timechart
```

### Every month

- Drift issues closed with a decision recorded, not just closed.
- Cost review: [13-cost](13-cost.md).
- Confirm the production trigger is still `Started`.
- Confirm a backup restore actually works. An untested backup is a hope.

```bash
az sql db restore -g "$RG" -s "$SERVER" -n edw \
  --dest-name edw-restore-test --time "$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%S)"
# verify, then:
az sql db delete -g "$RG" -s "$SERVER" -n edw-restore-test --yes
```

---

## Break-glass

### Getting into the private data plane

Prod deploys Azure Bastion (`deploy_bastion = true`). Deploy a small VM into the
VNet, connect through Bastion, and use SSMS or Azure Data Studio.

Failing that, temporarily allow your IP. **Set a calendar reminder to remove
it** — a forgotten firewall rule is a permanent hole:

```bash
MY_IP=$(curl -s https://api.ipify.org)
az sql server firewall-rule create -g "$RG" -s "$SERVER" \
  -n "breakglass-$(date +%Y%m%d)" --start-ip-address "$MY_IP" --end-ip-address "$MY_IP"
az sql server update -g "$RG" -n "$SERVER" --enable-public-network true

# ... and afterwards, without fail:
az sql server update -g "$RG" -n "$SERVER" --enable-public-network false
az sql server firewall-rule delete -g "$RG" -s "$SERVER" -n "breakglass-$(date +%Y%m%d)"
```

Drift detection will flag this on the next weekday morning, which is the system
working correctly. Close the issue with a note explaining the incident.

### Stopping everything

```bash
for t in TR_Monthly_NycTaxi_Load TR_Tumbling_NycTaxi_Reprocess; do
  az datafactory trigger stop -g "$RG" --factory-name "$ADF" --name "$t"
done
```

Remember to start them again, and note that the next `adf-cd` deployment will
restore whatever `config-prod.csv` says — so if the stop needs to outlive a
deployment, change the CSV.

---

Next: [12 — Troubleshooting](12-troubleshooting.md)
