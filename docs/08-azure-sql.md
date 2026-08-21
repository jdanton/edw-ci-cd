# 08 — Azure SQL

SDK-style database projects, publish profiles, and how to make a schema change
that does not lose data.

---

## SDK-style, not legacy `.sqlproj`

```xml
<Project Sdk="Microsoft.Build.Sql/1.0.0">
```

What that buys over the SSDT-era format:

- **`dotnet build` works on Linux.** No SSDT, no Visual Studio, no Windows build
  agent. This is what lets the project compile on your self-hosted Linux runner.
- **Files are globbed** (`**/*.sql`) rather than enumerated. Adding a table is
  `git add`, not a merge conflict in an XML file — the single biggest day-to-day
  irritation of the old format.
- **`<PackageReference>` works** like any other .NET project, so referencing
  `master.dacpac` or another database project is ordinary NuGet.

```bash
dotnet build src/sql/EdwTaxi.Database/EdwTaxi.Database.sqlproj -c Release
# → bin/Release/EdwTaxi.Database.dacpac
```

### Settings that matter

```xml
<DSP>Microsoft.Data.Tools.Schema.Sql.SqlAzureV12DatabaseSchemaProvider</DSP>
```

Azure SQL Database, not SQL Server. Not cosmetic: with a SQL Server target the
model validator accepts `FILEGROUP` clauses and other on-premises syntax that
Azure SQL rejects at deploy time — turning a compile error into a 2 a.m.
production failure.

```xml
<TreatTSqlWarningsAsErrors>True</TreatTSqlWarningsAsErrors>
<SuppressTSqlWarnings>71502</SuppressTSqlWarnings>
```

Unresolved references are warnings by default, so a procedure naming a column
that does not exist compiles cleanly and fails on first execution. Promoting
them to errors makes the build catch it.

`SQL71502` is suppressed for exactly one reason: the post-deploy script
references `$(DataFactoryName)`, a principal that cannot exist in the model.
Never add to that list without a reason written next to it.

### Pre/post-deploy wiring

The SDK globs everything into `<Build>`, so deployment scripts must be removed
first:

```xml
<Build Remove="Scripts/**/*.sql" />
<PreDeploy  Include="Scripts/PreDeploy/PreDeploy.sql" />
<PostDeploy Include="Scripts/PostDeploy/PostDeploy.sql" />
<None Include="Scripts/PostDeploy/**/*.sql" Exclude="Scripts/PostDeploy/PostDeploy.sql" />
```

Exactly one `PreDeploy` and one `PostDeploy` are permitted; everything else is
pulled in with `:r` and must be `<None>` so the compiler ignores it while
MSBuild still copies it.

### SQLCMD variables

Supplied at **publish** time, not build time, so one DACPAC deploys everywhere:

```bash
sqlpackage /Action:Publish ... \
  /v:DataFactoryName=adf-edwtaxi-prod-x9f2 \
  /v:EnvironmentName=prod \
  /v:DimDateStartYear=2009 \
  /v:DimDateEndYear=2035
```

Build once, deploy many. Rebuilding per environment means the thing approved for
production is not the thing that was tested.

> Your IDE will underline `$(DimDateStartYear)` as a syntax error. That is the
> editor not knowing about SQLCMD mode; DacFx enables it for pre/post-deploy
> scripts. `dotnet build` is the authority.

---

## The schema

```
stg   volatile staging. Heap, no indexes, no constraints, truncated per load.
dim   Date, Vendor, RateCode, PaymentType, TaxiZone. Rowstore, clustered PKs.
fact  YellowTaxiTrip. Clustered columnstore.
etl   the load procedures.
meta  LoadAudit, DataQualityRule, DataQualityResult.
rpt   the shape Power BI imports.
```

### Clustered columnstore, no nonclustered index

Everything about the fact table's access pattern says columnstore: written once
per month in one large batch, never updated in place, read by aggregates
touching a handful of the twenty columns, and large enough that ~10×
compression is worth money.

There is deliberately **no** nonclustered index on
`(PickupYear, PickupMonth)`, even though the merge deletes by exactly that
predicate. Because rows are inserted one month at a time, each rowgroup
contains a single month, so segment min/max metadata already eliminates every
rowgroup but the target. An index would add write cost during the bulk insert
and buy nothing.

If you start loading months out of order or interleaved, revisit that. Confirm
segments are still month-aligned first:

```sql
SELECT
    rg.partition_number, rg.row_group_id, rg.total_rows, rg.state_desc,
    MinYear = MIN(css.min_data_id), MaxYear = MAX(css.max_data_id)
FROM sys.dm_db_column_store_row_group_physical_stats rg
JOIN sys.column_store_segments css
  ON css.hobt_id = rg.object_id AND css.segment_id = rg.row_group_id
WHERE rg.object_id = OBJECT_ID('fact.YellowTaxiTrip')
GROUP BY rg.partition_number, rg.row_group_id, rg.total_rows, rg.state_desc;
```

### No foreign keys on the fact table

Azure SQL supports them on columnstore, and they are still wrong here:

- checked row by row during the bulk insert — the slowest part of the load;
- they cannot prevent the failure that actually occurs (a dimension member
  missing at load time), because the ETL resolves unknowns to `-1` first.

Referential integrity is enforced by the key resolution in
`etl.usp_Merge_YellowTaxiTrip` and **asserted** by
`etl.usp_RunDataQualityChecks` after every load. A violation becomes a named
data quality failure rather than an opaque constraint error mid-transaction.

Foreign keys **are** used in `meta.*`, where the tables are small and the
inserts are single-row. The distinction is volume, not principle.

### The Unknown (-1) member

Every dimension has one, and every fact key is `NOT NULL`. Roughly 0.1% of TLC
rows carry a code not in the published list. Three options:

1. Drop the fact rows → silently loses revenue.
2. Leave the FK NULL → every report must remember `LEFT JOIN`, and one day
   someone will not, and the number quietly shrinks.
3. Point at an Unknown member → `INNER JOIN`s stay correct, rows stay counted,
   and "Unknown" appears in the report where a human notices it.

Option 3. `dim.Date`'s check constraint explicitly permits `-1` rather than
being disabled around the insert — a constraint re-enabled `WITH NOCHECK`
becomes *not trusted*, which silently removes it from the optimiser's
consideration for every future query.

---

## Why the "merge" is not a `MERGE`

`etl.usp_Merge_YellowTaxiTrip` does a whole-partition `DELETE` then `INSERT`,
inside one transaction. The name is conventional; the implementation is not.

1. **T-SQL `MERGE` has a long, documented history of correctness bugs**, several
   unfixed. For the statement that decides what is in a warehouse, "usually
   correct" is not a category that exists.
2. **`MERGE` on a clustered columnstore performs badly.** It resolves to
   row-by-row updates, which on columnstore means marking rows deleted in the
   delta store and appending new versions. Over months the table fragments and
   performance degrades invisibly until it is severe.
3. **Partition replacement matches the source's semantics.** The TLC restates
   months. The correct action is "this month is now that set of rows", not
   "reconcile row by row" — and a whole-partition swap expresses that directly,
   is trivially idempotent, and needs no assumption that the natural key is
   stable across a restatement.

The cost: a re-run rewrites the whole month even if one row changed. At ~3M rows
into a columnstore, that is seconds.

### The five most important lines in the repository

```sql
IF @rowsStaged = 0
BEGIN
    RAISERROR('stg.YellowTaxiTrip is empty. Refusing to replace fact partition %d-%d with nothing.', 16, 1, @PickupYear, @PickupMonth);
    RETURN;
END
```

Without this, a Copy activity that silently transferred zero rows would `DELETE`
the existing partition and `INSERT` nothing — turning a transient upstream
problem into deleted production data.

`MERGE` **is** used in the post-deploy scripts, for the five-to-265-row
dimensions. Different size, different storage, different frequency, different
answer.

---

## Data quality rules as rows

`meta.DataQualityRule` holds SQL; `etl.usp_RunDataQualityChecks` executes each
enabled rule with `sp_executesql`.

A new check is an `INSERT`, not a schema change and a deployment. That is the
right friction for something a data steward should be able to propose.

Contract: each rule's SQL returns **one row, one column named `FailedCount`**,
and may reference the bound parameters `@PickupYear` and `@PickupMonth`. A
malformed rule is reported as an authoring error rather than silently passing.

On the dynamic SQL, a straight answer rather than a disclaimer: only members of
the `etl` role or an administrator can insert a rule, and anyone who can do that
can already run arbitrary SQL directly — the rule table adds no privilege. The
parameters are **bound**, never concatenated, so values from ADF cannot alter
the statement.

| Severity | Effect |
|---|---|
| `Blocking` | `RAISERROR` → the activity fails → the load is not marked Succeeded |
| `Warning` | recorded and trended; the load continues |

`FailureThreshold` exists because some badness is expected and stable. The TLC
publishes a few hundred zero-passenger trips every month; alerting on it every
month trains people to ignore the alert, which costs you the alert you actually
needed.

The eight seeded rules are in
[`030_DataQualityRules.sql`](../src/sql/EdwTaxi.Database/Scripts/PostDeploy/030_DataQualityRules.sql).
Note that `IsEnabled` is deliberately **not** updated by the `MERGE`: an
operator who disables a noisy rule at 02:00 during an incident should not find
it silently re-enabled by the next deployment.

---

## Publish profiles

Three, in `Properties/`. The differences are the point.

| Setting | dev | test | prod | Why |
|---|---|---|---|---|
| `BlockOnPossibleDataLoss` | False | **True** | **True** | Dev data is reproducible in twenty minutes. Prod data is not. |
| `BlockWhenDriftDetected` | False | **True** | **True** | Deploying over drift silently reverts somebody's 2 a.m. fix. |
| `DropObjectsNotInSource` | True | True | True | The database converges on the repository. |
| `IgnoreColumnOrder` | True | True | True | Avoids a full table rebuild for a purely cosmetic difference. |
| `GenerateSmartDefaults` | False | False | False | See below. |
| `CommandTimeout` | 600 | 1800 | 1800 | A columnstore rebuild on a nine-figure table genuinely takes that long. |

### `ExcludeObjectTypes` — do not remove entries

```xml
<ExcludeObjectTypes>Users;Logins;RoleMembership;Permissions;ServerRoleMembership;Credentials;DatabaseScopedCredentials;...</ExcludeObjectTypes>
```

Security is owned by two other things: Azure RBAC and the Entra admin group
(Terraform), and contained users, roles and grants
(`Scripts/PostDeploy/040_ServicePrincipals.sql`).

If sqlpackage also managed them, it would drop the Data Factory user on every
deployment — it is not in the model and cannot be, since its name is
environment-specific — and the next pipeline run would fail.

Removing entries from this list is one of the few ways to break production with
a deployment that reports success.

### `GenerateSmartDefaults` is False on purpose

Smart defaults invent a value so a new `NOT NULL` column can be added to a table
with existing rows. It works, and it quietly fills your fact table with zeros
that look like real measurements. Adding a `NOT NULL` column should require you
to state what existing rows mean, deliberately, in a post-deploy script.

---

## Making a schema change that loses no data

`BlockOnPossibleDataLoss=True` will refuse a rename, because sqlpackage sees a
drop plus an add. The answer is a migration in **three deployments**, not a flag.

Say `TripDistanceMiles` should become `TripDistanceKm`.

**Deployment 1 — add.**

```sql
-- Tables/fact/YellowTaxiTrip.sql
[TripDistanceMiles] DECIMAL(9,3) NULL,
[TripDistanceKm]    DECIMAL(9,3) NULL,   -- new, nullable
```

```sql
-- Scripts/PostDeploy/050_BackfillTripDistanceKm.sql   (idempotent)
IF EXISTS (SELECT 1 FROM fact.YellowTaxiTrip WHERE TripDistanceKm IS NULL AND TripDistanceMiles IS NOT NULL)
BEGIN
    PRINT 'Backfilling TripDistanceKm...';
    UPDATE fact.YellowTaxiTrip
    SET TripDistanceKm = TripDistanceMiles * 1.609344
    WHERE TripDistanceKm IS NULL AND TripDistanceMiles IS NOT NULL;
END
```

**Deployment 2 — switch readers.** Update `rpt.vw_YellowTaxiTripDaily`, the
curated CETAS, and the staging table. Both columns still exist; anything still
reading the old one keeps working.

**Deployment 3 — drop.** Remove `TripDistanceMiles` from the table. sqlpackage
still flags data loss, and now that is correct and intended:

```bash
sqlpackage /Action:Publish ... /p:BlockOnPossibleDataLoss=False
```

Overriding it on the command line, for one deployment, after two deployments of
preparation, with the DeployReport artifact attached to the change record — that
is a decision. Setting it False in the profile is an accident waiting to happen.

Full walkthrough with the pipeline changes:
[10-making-a-change](10-making-a-change.md#example-2-adding-a-column-end-to-end).

---

## Deploying

```bash
SERVER=$(terraform -chdir=infra/terraform output -raw sql_server_fqdn)
DB=$(terraform     -chdir=infra/terraform output -raw sql_database_name)
ADF=$(terraform    -chdir=infra/terraform output -raw data_factory_name)
TOKEN=$(az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)

# ALWAYS look first.
sqlpackage /Action:Script \
  /SourceFile:src/sql/EdwTaxi.Database/bin/Release/EdwTaxi.Database.dacpac \
  /Profile:src/sql/EdwTaxi.Database/Properties/EdwTaxi.Database.dev.publish.xml \
  /TargetServerName:"$SERVER" /TargetDatabaseName:"$DB" /AccessToken:"$TOKEN" \
  /OutputPath:./deploy.sql \
  /v:DataFactoryName="$ADF" /v:EnvironmentName=dev \
  /v:DimDateStartYear=2009 /v:DimDateEndYear=2035

less ./deploy.sql

# Then apply (same command, /Action:Publish, no /OutputPath).
```

`sql-cd.yml` runs `DeployReport` and `Script` before every publish and uploads
both as artifacts, so the reviewer on the prod approval gate reads the exact
T-SQL before approving.

### Authentication

`/AccessToken` with an Entra token. The deployment service principal is a
member of the Entra admin group for the server (`bootstrap/main.tf`), so the
token carries full control with no password anywhere.

This is also **required** for `CREATE USER ... FROM EXTERNAL PROVIDER` in the
post-deploy script: a SQL-authenticated login cannot create an Entra user, even
as sysadmin. Switch sqlpackage to SQL auth and that script fails with
"Principal 'x' could not be found or this principal type is not supported".

---

## Testing

The build validates the model. For behaviour, add
[tSQLt](https://tsqlt.org/) as a referenced project and test the procedures in
dev — `etl.usp_Merge_YellowTaxiTrip`'s empty-staging guard and
`etl.usp_RunDataQualityChecks`'s malformed-rule handling are the two worth
covering first.

Not included here because a test framework in the production database is a real
decision with real trade-offs (tSQLt installs CLR objects), and a template
should not make it for you.

What **is** included is the post-deploy verification in `_sql-publish.yml`:
object counts, `dim.Date` populated, quality rules seeded, and — the one that
catches the most real problems — the ADF database user present.

---

Next: [09 — CI/CD workflows](09-cicd-workflows.md)
