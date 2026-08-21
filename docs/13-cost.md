# 13 — Cost

What this platform costs, where the money actually goes, and which knobs matter.

> Figures are East US 2 list prices as a planning aid, not a quote. Check your
> own rate card — enterprise agreements, reservations and regional differences
> move these materially. The *shape* of the breakdown is the durable part.

---

## Idle cost

With no pipelines running, per month:

| Component | dev | test | prod | Note |
|---|---|---|---|---|
| Private endpoints | $73 | $73 | $73 | 10 × ~$7.30. Charged whether traffic flows or not. |
| Azure SQL | ~$15 | ~$40 | ~$580 | dev/test serverless with auto-pause; prod `GP_Gen5_4` ZRS |
| Storage (1 yr of trips ≈ 25 GB) | ~$1 | ~$2 | ~$3 | LRS Hot; less once tiering kicks in |
| Log Analytics | ~$5 | ~$10 | ~$40 | driven by retention and ingest volume |
| Key Vault | <$1 | <$1 | <$1 | operations are effectively free at this volume |
| Bastion | — | — | ~$140 | Basic SKU, prod only |
| Synapse workspace | $0 | $0 | $0 | serverless: no charge for existing |
| Data Factory | $0 | $0 | $0 | no charge for existing |
| **Idle total** | **~$95** | **~$125** | **~$835** | |

**All three environments idle: roughly $1,055/month.**

### The surprise is private endpoints

$219/month across three environments, before a single byte moves. That is what
"private-only" costs, and it is charged for existence, not for traffic.

Ten per environment:

| Endpoint | Purpose |
|---|---|
| storage `blob`, storage `dfs` | ADLS needs both — genuinely different APIs |
| Key Vault `vault` | |
| SQL `sqlServer` | |
| Synapse `Sql`, `SqlOnDemand`, `Dev` | three sub-resources, two DNS zones |
| ADF `dataFactory`, `portal` | runtime and Studio |
| Synapse Private Link Hub `Web` | prod only |

Reducible to **six** by dropping the two ADF endpoints and the Synapse `Sql`
endpoint in non-prod — saving ~$22/month per environment. See
[Reducing cost](#reducing-cost).

---

## Per-run cost

Loading one month (~3 million trips):

| Item | Quantity | Cost |
|---|---|---|
| ADF activity runs | ~12 | ~$0.01 |
| Managed-VNet IR time | ~15 min | ~$0.06 |
| Data movement (DIU-hours) | ~0.3 | ~$0.08 |
| Synapse serverless scanned | ~3 GB | ~$0.015 |
| Azure SQL compute | included | — |
| **Per month loaded** | | **~$0.17** |

The monthly production load costs about **twenty cents**. A full twelve-month
backfill is roughly **$2**.

Which tells you where to look when the bill grows: not the pipeline.

---

## Where the money actually goes

Ranked, prod:

```
Azure SQL          $580   69%   ████████████████████████████████████
Bastion            $140   17%   ████████
Private endpoints   $73    9%   ████
Log Analytics       $40    5%   ██
Storage              $3    <1%
Pipelines            $2    <1%
```

The warehouse is the platform. Everything else is rounding, and optimising the
pipeline before optimising the database is optimising the wrong thing.

---

## Reducing cost

Ordered by saving per unit of effort.

### 1. Right-size Azure SQL (up to ~$400/month)

`GP_Gen5_4` is a starting guess, not a measurement. Look at what you actually
use:

```sql
SELECT TOP (168)
    end_time,
    AvgCpuPct    = avg_cpu_percent,
    AvgDataIoPct = avg_data_io_percent,
    AvgLogPct    = avg_log_write_percent,
    MaxWorkerPct = max_worker_percent
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;
```

Sustained CPU under 20% means you are two sizes too large.

```bash
az sql db update -g "$RG" -s "$SERVER" -n edw --service-objective GP_Gen5_2   # ~$290
```

Then update `sql_sku_name` in `prod.tfvars`, or Monday's drift detection will
flag it — which is the system working correctly.

Also consider:

- **Reserved capacity** — one or three years, 20–35% off. Free money if the
  platform is staying.
- **Hyperscale** — worth evaluating past ~500 GB.
- **Serverless in prod** — only if the load is genuinely a nightly batch and
  nobody queries in the morning. The 30–60 second resume on the first query is
  usually unacceptable for a reporting database.

### 2. Turn off Bastion when idle (~$140/month)

```hcl
# prod.tfvars
deploy_bastion = false
```

Deploy it through `infra-cd` when you need break-glass access, and turn it off
again. Ten minutes of `terraform apply` versus $140/month.

The counter-argument: you need Bastion exactly when something is badly wrong,
and "wait ten minutes for a Terraform apply" is a poor answer at 03:00. Keep it
in prod if the platform is business-critical; that is what the $140 buys.

### 3. Drop optional private endpoints (~$22/month/env)

```hcl
# dev.tfvars, test.tfvars
adf_deploy_factory_private_endpoints = false   # -2 endpoints
synapse_deploy_private_link_hub      = false   # -1 endpoint (already default)
```

You lose ADF Studio and Synapse Studio over Private Link. Authors then use the
public Studio endpoints, which still authenticate through Entra — the *data*
stays private either way. Reasonable in dev; think harder in prod.

The Synapse `Sql` endpoint is created even though there is no dedicated pool,
because it shares a DNS zone with `SqlOnDemand`. Removing it saves $7.30 and
creates a confusing partial-resolution state if a dedicated pool is ever added.
Not worth it.

### 4. Tune Log Analytics (~$20/month)

The `daily_quota_gb` cap is the important one — it makes a runaway diagnostic
setting a capped incident rather than an uncapped bill.

```hcl
log_retention_in_days = 30    # from 90
log_daily_quota_gb    = 5     # from 20
```

What is actually being ingested:

```kql
Usage
| where TimeGenerated > ago(30d)
| summarize GB = sum(Quantity) / 1024 by DataType
| order by GB desc
```

`StorageBlobLogs` is usually the largest by a wide margin. `StorageRead` on a
busy lake is voluminous — it is enabled in
`modules/storage` because "who read the PII zone" is a question auditors ask and
you cannot answer retroactively. If you do not need that, drop it from
`blob_log_categories`.

### 5. Lifecycle the lake (grows with history)

Already configured, and the settings are worth understanding:

```hcl
raw_cool_after_days    = 30     # ~45% cheaper than Hot
raw_archive_after_days = 365    # ~85% cheaper than Hot
```

The trap: **reading an archived blob requires rehydration** — hours, not
minutes. A curated rebuild of an archived month will appear to hang. If you
rebuild history regularly, raise `raw_archive_after_days` or drop archiving
entirely.

Curated deliberately stays warm: Synapse serverless reads it on every query, and
Cool has a per-read charge that can exceed the storage saving on a
frequently-queried layer.

### 6. Delete non-production overnight

The largest saving available, and the most disruptive. Dev and test at ~$220/month
combined cost ~$73/month if destroyed nightly and rebuilt each morning.

```bash
gh workflow run infra-cd.yml -f environment=dev -f plan_only=false
```

Honest assessment: a twenty-minute rebuild each morning, plus a data reload, is
usually not worth $150/month of engineer patience. Consider it only if dev sits
idle for weeks at a time.

---

## Synapse serverless cost control

The one component that can produce a genuinely alarming bill from a single
query. Billed per TB scanned, with nothing stopping a user.

```sql
-- ~40 MB. Folder pruning applies.
WHERE PickupYear = 2024 AND PickupMonth = 3

-- The whole lake. PickupDate lives inside the files.
WHERE PickupDate = '2024-03-15'
```

Three controls, in order of effectiveness:

**1. Workspace cost control.** Synapse Studio → Manage → SQL pools → Built-in →
Cost control. Set a daily, weekly and monthly TB cap. The pool refuses queries
beyond it. This is a hard stop, and every workspace should have one.

**2. The alert.** `alert-<env>-synapse-data-processed` fires when more than the
threshold is scanned in an hour. Tells you within an hour rather than at
month-end.

**3. Education.** The `SQL_Explore_YellowTaxi` script tab deployed into Studio
opens with the cost rules and finishes with a query showing what the reader's
own exploration just cost. Cheaper than any control.

Who is spending it:

```kql
SynapseBuiltinSqlPoolRequestsEnded
| where TimeGenerated > ago(30d)
| summarize
    Requests     = count(),
    TotalGB      = round(sum(DataProcessedBytes) / pow(1024.0, 3), 2),
    EstimatedUSD = round(sum(DataProcessedBytes) / pow(1024.0, 4) * 5.0, 2)
  by LoginName
| order by TotalGB desc
```

(Saved as **EDW-ServerlessCostByPrincipal**.)

---

## Cost as it scales

The template's NYC Taxi dataset is small. Extrapolating for a real workload:

| | Template (1 yr) | 10× (10 yrs, or 10 sources) | 100× |
|---|---|---|---|
| Lake storage | 25 GB / ~$3 | 250 GB / ~$25 | 2.5 TB / ~$250 |
| Serverless per rebuild | 3 GB / $0.02 | 30 GB / $0.15 | 300 GB / $1.50 |
| Azure SQL | GP_Gen5_4 / $580 | GP_Gen5_8 / ~$1,160 | Hyperscale / ~$2,500+ |
| Private endpoints | $73 | $73 | $73 |
| **Prod total** | **~$835** | **~$1,500** | **~$3,000** |

Two things to notice:

- **Private endpoints do not scale with data.** They are a fixed entry price for
  private networking. At small scale they are 9% of the bill; at 100× they are
  2%.
- **Storage and compute for the pipeline are nearly free even at 100×.** The
  serving database is the cost, at every scale.

Which is the argument for the four-layer design: keeping the transformation in
serverless and the lake, and putting only conformed, aggregated data into the
expensive layer, is what keeps the bill sub-linear.

---

## Tracking it

Every resource is tagged:

```hcl
tags = {
  environment = "prod"
  project     = "edwtaxi"
  workload    = "edw-platform"
  managed-by  = "terraform"
  cost-center = "FIN-1234"
  owner       = "data-platform@your-org.com"
  criticality = "high"
}
```

```bash
# Month to date by environment
az consumption usage list \
  --start-date "$(date -u +%Y-%m-01)" --end-date "$(date -u +%Y-%m-%d)" \
  --query "[?contains(instanceName, 'edwtaxi')].{name:instanceName, cost:pretaxCost, currency:currency}" \
  -o table
```

Set a budget with an alert, per environment:

```bash
az consumption budget create \
  --budget-name edwtaxi-prod-monthly \
  --amount 1000 --category Cost --time-grain Monthly \
  --start-date "$(date -u +%Y-%m-01)" --end-date 2027-01-01 \
  --resource-group rg-edwtaxi-prod-eus2
```

A budget alert at 80% is the cheapest cost control there is, and the only one
that catches a category of spend nobody predicted.

---

Back to the [README](../README.md).
