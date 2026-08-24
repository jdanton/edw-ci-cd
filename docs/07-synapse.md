# 07 — Synapse serverless

The logical data warehouse: what serverless is good at, what it is not, and the
two-halves deployment that catches everyone out once.

---

## The two halves

This is the single most common misunderstanding about deploying Synapse.

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │  HALF 1  —  Workspace artifacts                                    │
  │                                                                     │
  │  src/synapse/workspace/                                             │
  │    linkedService/   LS_ADLS_Lake, LS_KeyVault                       │
  │    sqlscript/       SQL_Explore_YellowTaxi                          │
  │                                                                     │
  │  Deployed by:  azure.synapse.tools → Publish-SynapseFromJson        │
  │  Reaches:      https://<workspace>.dev.azuresynapse.net  (REST)     │
  │  Lives in:     the workspace artifact store                         │
  └─────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────┐
  │  HALF 2  —  Serverless SQL OBJECTS                                  │
  │                                                                     │
  │  src/synapse/serverless/                                            │
  │    010_database.sql              CREATE DATABASE edw_lake           │
  │    020_security.sql              master key, scoped credential      │
  │    030_external_data_sources.sql eds_raw, eds_curated, eds_sandbox  │
  │    040_file_formats_and_schemas  ff_parquet_snappy, raw/curated/... │
  │    060_views_raw.sql             raw.vw_*                           │
  │    070_procs_curate.sql          curated.usp_Build_Yellow_Monthly   │
  │    080_views_curated.sql         curated.vw_*, serving.vw_*         │
  │    090_permissions.sql           ADF user + grants, edw_analyst     │
  │                                                                     │
  │  Deployed by:  Invoke-Sqlcmd over TDS                               │
  │  Reaches:      <workspace>-ondemand.sql.azuresynapse.net:1433       │
  │  Lives in:     the serverless database                              │
  └─────────────────────────────────────────────────────────────────────┘
```

**A "SQL script" artifact is a saved query TAB in Studio. Deploying it does not
execute it.** If you only run half 1, the workspace looks perfect in Studio and
every ADF pipeline fails, because `edw_lake` does not exist.

`synapse-cd.yml` runs both, in order, every time.

---

## Why serverless and not a dedicated pool

| | Serverless | Dedicated pool |
|---|---|---|
| Cost model | per TB scanned | per hour, provisioned |
| Idle cost | zero | full price |
| Storage | none — reads Parquet in place | its own, loaded first |
| Right for | transformation, exploration, a lake you query occasionally | a warehouse queried constantly at scale |

This platform transforms a few gigabytes a month and exposes views for ad-hoc
exploration. Serving is Azure SQL's job. A dedicated pool would be an idle bill.

The corollary is that serverless is **wrong for dashboards**. Thirty people
refreshing Power BI all morning against per-TB billing is how a data platform
budget disappears. Point BI at `rpt.vw_YellowTaxiTripDaily` in Azure SQL.

---

## Collation — decide once {#collation}

```sql
CREATE DATABASE edw_lake COLLATE Latin1_General_100_BIN2_UTF8;
```

Not a style preference:

- Parquet stores strings as UTF-8. A non-UTF8 database collation makes
  serverless **transcode every string column on every read** — a permanent tax,
  frequently 2–3× on string-heavy scans.
- `BIN2` gives byte-order comparison: the fastest possible string comparison,
  and it lets predicate pushdown work on string columns.

The cost is case sensitivity: `'Manhattan' <> 'MANHATTAN'`. For a warehouse
where string comparisons are mostly joins on codes, that is the right trade.
Where you need case-insensitive comparison, `COLLATE` the expression.

Changing it requires dropping and re-creating the database.
`010_database.sql` warns loudly rather than failing if it finds a database with
the wrong collation — failing would block every subsequent deployment.

---

## Public network access: enabled at create, disabled after {#public-access-at-create}

The workspace is created with `public_network_access_enabled = true` and locked
down immediately afterwards by a `null_resource` that issues an ARM PATCH. That
looks like a workaround. It is not optional.

Measured on a real subscription, same storage account, same filesystem, same
managed VNet, with the flag as the only difference:

| `publicNetworkAccess` at create | Outcome |
|---|---|
| `Disabled` | 30+ minutes, never completes, ends `provisioningState = Failed` |
| `Enabled` | **Succeeded in 7 minutes** |

Synapse needs to reach its own endpoints while provisioning. Disabling public
access before the workspace exists denies it that, and the failure is silent:
Azure keeps returning `StatusCode=200` while making no progress, so Terraform
eventually hits its own timeout and the abandoned workspace settles into
`Failed`. The error you are then shown is

```
CreateWorkspaceError: An error has occured while creating the workspace.
Correlation Id: ...
```

which says nothing about networking, and a `Failed` workspace cannot be
repaired - it must be deleted before anything can proceed.

**Raising the Terraform timeout does not fix this.** It only makes the failure
take longer to arrive.

The lockdown runs after the workspace private endpoints AND the managed private
endpoints, so the private path is proven before the public one closes. Because
Azure then reports `Disabled` while the configuration says `true`, the resource
carries `ignore_changes = [public_network_access_enabled]` - without it every
plan proposes turning public access back on.

`az synapse workspace update` has no flag for this, hence the generic
`az resource update --set properties.publicNetworkAccess=Disabled`.

---

## The three external data sources

One per lake filesystem, rather than one root data source. Two reasons:

1. **Blast radius.** A view reading `eds_raw` physically cannot read
   `eds_sandbox`, whatever the path expression says.
2. **Portability.** Every environment has the same three names pointing at
   different accounts, so not one view or procedure contains a storage account
   name. Promoting from dev to prod changes three objects and nothing else.

All three use:

```sql
CREATE DATABASE SCOPED CREDENTIAL cred_LakeManagedIdentity
    WITH IDENTITY = 'Managed Identity';
```

which resolves to the **workspace** managed identity regardless of caller.
Deterministic, auditable, and grantable in exactly one place
([`rbac.tf`](../infra/terraform/rbac.tf), `synapse_lake_contributor`).

The alternative — no credential — passes **the caller's** identity through.
Great for ad-hoc analyst queries, useless for a pipeline: the query behaves
differently depending on who runs it.

> The master key exists only because SQL insists a scoped credential be
> encrypted. For `'Managed Identity'` there is no secret material to protect, so
> the password protects nothing. It is generated fresh per deployment and never
> stored. Putting it in Key Vault would create one more thing to rotate in
> exchange for nothing.

---

## `OPENROWSET` views, not external tables

Every view in `raw` and `curated` is an `OPENROWSET` over a wildcard path, not
a `CREATE EXTERNAL TABLE`. One decisive reason: **`filepath()`**.

```sql
SELECT
    PickupYear  = CAST(src.filepath(1) AS INT),
    PickupMonth = CAST(src.filepath(2) AS INT),
    ...
FROM OPENROWSET(
        BULK 'nyctlc/yellow/puYear=*/puMonth=*/*.parquet',
        DATA_SOURCE = 'eds_raw', FORMAT = 'PARQUET'
     ) ... AS src;
```

`filepath(n)` returns the text matched by the n-th wildcard, turning folder
names into columns. Filtering on them prunes whole folders **without opening a
file**. External tables have no notion of Hive-style partitioning, so an
external table over raw would scan all 70+ month folders even when the caller
wants one month.

On this dataset that is the difference between 40 MB and 40 GB scanned — and
serverless bills per byte.

### Cost rules for anyone querying these

```sql
-- ~40 MB scanned. Folder pruning applies.
WHERE PickupYear = 2024 AND PickupMonth = 3

-- The whole lake. PickupDate is inside the files; every one must be opened.
WHERE PickupDate = '2024-03-15'
```

The second form is how a five-dollar query becomes a five-hundred-dollar query.
The `alert-<env>-synapse-data-processed` rule watches for it.

Also: project only the columns you need. Parquet is columnar, so `SELECT *`
reads every column.

---

## CETAS, and the thing it cannot do

`curated.usp_Build_Yellow_Monthly` writes one month with `CREATE EXTERNAL TABLE
AS SELECT`.

### It cannot overwrite

`DROP EXTERNAL TABLE` removes **metadata only**. The Parquet files stay on disk,
and the next CETAS to the same `LOCATION` fails with:

```
Cannot create external table. External table location already exists.
```

Serverless has no `DELETE` and cannot remove files. **Something outside Synapse
must clear the folder first** — in this template, the `Delete` activity in
`PL_Curate_NycTaxi_Yellow`, guarded by a `Get Metadata` existence check because
`Delete` fails on a path that does not exist.

By hand:

```bash
az storage fs directory delete -f curated --account-name <acct> \
  -n "nyctlc/yellow_trip/PickupYear=2024/PickupMonth=1" --auth-mode login -y
```

The procedure catches this specific failure and re-raises it with an actionable
message, because the native one names neither the folder nor the fix.

### Per-partition, throwaway external tables

Each call creates `curated.ext_YellowTaxiTrip_<YYYYMM>`. We want the **files**;
the table is a by-product. Consumers read `curated.vw_YellowTaxiTrip` — an
`OPENROWSET` over all partitions — because only that supports `filepath()`.

Keeping the per-partition tables costs nothing and makes
`sys.external_tables` a useful record of which partitions have been built.

A `UNION ALL` over the external tables would also need editing every month —
a maintenance trap nobody remembers until a month is missing from a report.

### Partition leakage

The raw folders are partitioned on the publisher's `puYear`/`puMonth`, but the
files genuinely contain rows whose `tpepPickupDateTime` falls in another month:
meter clock errors, trips crossing midnight on the 1st, and a handful of records
dated decades out.

Carried through, curated `PickupYear=2024/PickupMonth=1` would hold January
**and** stray February rows. The Azure SQL load deletes and re-inserts by
`(PickupYear, PickupMonth)`, so those strays would be inserted by January's run
and deleted by February's — and silently disappear.

So the `WHERE` clause re-derives the partition from the **timestamp**, not the
folder:

```sql
AND r.tpepPickupDateTime >= DATEFROMPARTS(@puYear, @puMonth, 1)
AND r.tpepPickupDateTime <  DATEADD(MONTH, 1, DATEFROMPARTS(@puYear, @puMonth, 1))
```

Excluded rows are visible, with reasons, in
`curated.vw_YellowTaxiTrip_Rejected` — which is computed on demand against raw
and therefore costs nothing until somebody asks where 4,102 rows went.

> **Keep the rejected view in step with the procedure.** It is the inverse of
> the same predicates. Add a rule in one and not the other, and rows vanish with
> reason unknown — worse than not having the view at all.

---

## Permissions inside the database

Layer 3 of the [three-layer model](00-architecture.md#the-three-layer-permission-model).
Azure RBAC cannot create a SQL principal.

`090_permissions.sql` enumerates the grants rather than using `db_owner`. Each
line is there because removing it produces a specific failure:

| Grant | Without it |
|---|---|
| `SELECT ON SCHEMA::raw` | "The SELECT permission was denied" |
| `EXECUTE ON SCHEMA::curated` | cannot call the build procedure |
| `ADMINISTER DATABASE BULK OPERATIONS` | **every `OPENROWSET` fails**, even with SELECT granted — serverless-specific |
| `CREATE TABLE` + `ALTER ON SCHEMA::curated` | CETAS cannot create its external table |
| `ALTER ANY EXTERNAL DATA SOURCE` / `... FILE FORMAT` | CETAS cannot resolve `eds_curated` / `ff_parquet_snappy` by name |
| `REFERENCES ON DATABASE SCOPED CREDENTIAL` | credential-not-found, implying it is missing rather than inaccessible |

`ADMINISTER DATABASE BULK OPERATIONS` is the one nobody guesses.

There is also an `edw_analyst` role, granted read plus the bulk-operations
permission. What it is **not** granted is deliberate and documented in the
script: no `CREATE TABLE` (analysts cannot write curated), no
`ALTER ANY EXTERNAL DATA SOURCE` (cannot repoint a data source at another
account), no `EXECUTE ON SCHEMA::curated`. Analysts needing scratch space use
the `sandbox` filesystem, which is lifecycle-deleted after 30 days.

> Analysts also need **Storage Blob Data Reader** on the lake
> ([`rbac.tf`](../infra/terraform/rbac.tf), `synapse_admins_lake_reader`).
> Without it, the same query works for the pipeline (workspace MI) and fails for
> the human with "content of directory cannot be listed" — a storage error
> surfaced as if it were a path problem.

---

## Verifying the source schema

Microsoft has changed the Open Datasets NYC TLC schema before, and the explicit
`WITH` clause in `060_views_raw.sql` will break loudly when they do again. That
is by design — an explicit contract fails at a known place rather than silently
changing downstream column types.

To see what is actually in the files:

```bash
./scripts/Deploy-ServerlessSql.ps1 -Environment dev -WhatIf   # confirm context
```

then run [`util/inspect_source_schema.sql`](../src/synapse/serverless/util/inspect_source_schema.sql)
in Synapse Studio. It uses `sp_describe_first_result_set` over an inference
query to print the real column names and types, lists which partitions exist in
raw and curated, and shows what your exploration just cost.

---

## Deploying

```bash
# Both halves, dev:
./scripts/Deploy-Synapse.ps1        -Environment dev   # artifacts
./scripts/Deploy-ServerlessSql.ps1  -Environment dev   # SQL objects

# See what would run, without connecting:
./scripts/Deploy-ServerlessSql.ps1 -Environment dev -WhatIf
```

Scripts run in filename order, and the numeric prefixes **are** the dependency
graph — `synapse-cd.yml` fails the build if a script lacks a prefix or two
share one. Every script is idempotent (`CREATE OR ALTER`, or a guarded
`IF NOT EXISTS`), so a partial failure is repaired by running it again from the
start.

Deployment stops at the first failure rather than continuing, because
continuing past a missing external data source produces a cascade of errors that
obscure the real one.

### The publish method is `AzSynapse`, not the module default

`Deploy-Synapse.ps1` passes `-Method 'AzSynapse'` to `Publish-SynapseFromJson`.
The module's default is `AzResource`, and the two write to different planes:

| Method | Call | Endpoint |
|---|---|---|
| `AzResource` (default) | `New-AzResource` on `Microsoft.Synapse/workspaces/linkedservices` | ARM, which relays to the workspace |
| `AzSynapse` | `Set-AzSynapseLinkedService -DefinitionFile` | `<workspace>.dev.azuresynapse.net` |

The workspace has public network access disabled, and the
`privatelink.dev.azuresynapse.net` zone ([04-networking](04-networking.md))
exists to reach that Dev endpoint. The ARM route is the one path that private
link does not cover, and it fails with a correlation id and no message at all.

Note the asymmetry with Data Factory, which does **not** pass a method: ADF
artifacts are genuine ARM resources, and the ARM control plane stays reachable
with the data plane locked down. Synapse workspace artifacts are not ARM
resources.

Authorization differs too. The Dev API is governed by **Synapse RBAC**, not
Azure RBAC — Contributor on the workspace grants nothing here. The deployment
identity gets it by being a member of the Synapse admin group created in
`bootstrap/`. A 401 or 403 from this step means that membership, not a network
fault.

### The `Get-RequestHeader` patch

`Deploy-Synapse.ps1` replaces one private function inside `azure.synapse.tools`
before publishing. The module builds its Dev-API bearer token with
`Marshal::PtrToStringAuto`, which is UTF-16 on Windows and UTF-8 elsewhere —
so on a Linux runner the token becomes its first character and every REST-based
artifact fails with `IDX12741: JWT must have three segments`
([12-troubleshooting](12-troubleshooting.md#idx12741)). 0.27.0 is the newest
release; there is nothing to upgrade to.

The patch is dot-sourced into the module's scope, uses `PtrToStringBSTR`, and
removes itself once the installed module no longer contains the broken call.

### `workspace/integrationRuntime/AutoResolveIntegrationRuntime.json`

A placeholder, never deployed — `publish-options.json` excludes
`integrationRuntime.*`. Azure creates `AutoResolveIntegrationRuntime` with the
workspace; nothing here manages it, and Terraform only sets
`managed_virtual_network_enabled`.

It exists because `azure.synapse.tools` resolves `connectVia` references
against the **source folder**, not the live workspace. `LS_ADLS_Lake` names the
runtime, so without the file the publish fails with

```
ASWT0005: Referenced object [IntegrationRuntime].[AutoResolveIntegrationRuntime] was not found.
```

— after the triggers have been stopped. Same mechanism as
`integrationRuntime/IR-ManagedVNet.json` on the Data Factory side
([06-data-factory](06-data-factory.md)); the difference is only who owns the
runtime, Azure here and Terraform there.

---

## Adding an entity

To add green taxis alongside yellow:

1. `060_views_raw.sql` — add `raw.vw_GreenTaxiTrip` over
   `nyctlc/green/puYear=*/puMonth=*/*.parquet`.
2. `070_procs_curate.sql` — add `curated.usp_Build_Green_Monthly`, copying the
   yellow procedure. Keep the guards.
3. `080_views_curated.sql` — add `curated.vw_GreenTaxiTrip` and its
   `_Rejected` counterpart.
4. `090_permissions.sql` — no change; grants are schema-level.
5. ADF — a new ingest pipeline (or parameterise the existing one on entity) and
   a new curate pipeline.
6. Azure SQL — `stg.GreenTaxiTrip`, `fact.GreenTaxiTrip`,
   `etl.usp_Merge_GreenTaxiTrip`.

[10-making-a-change](10-making-a-change.md#example-4-adding-a-new-source) walks
this through with the actual code.

---

Next: [08 — Azure SQL](08-azure-sql.md)
