# 06 — Data Factory

Artifacts, deployment with `azure.datafactory.tools`, the config CSV, and
trigger state.

---

## Why not `adf_publish`

ADF's Git integration offers two deployment sources. The template uses the
second.

| | `adf_publish` branch | Collaboration branch |
|---|---|---|
| What is deployed | An ARM template ADF generates when someone clicks **Publish** in Studio | The artifact JSON as authored |
| Trigger | A human, in a browser | A commit |
| PR diff | Hundreds of lines of re-serialised ARM | `+ "retry": 2` |
| Failure granularity | Whole-template rollback | Per artifact |
| Parameterisation | `ARMTemplateParametersForFactory.json` | A four-column CSV |

Three concrete reasons for the collaboration branch:

1. **No clicking.** With `adf_publish`, nothing deploys until a human opens
   Studio and presses a button. That is not continuous delivery, and the
   deployed artifact corresponds to no reviewed commit.
2. **Reviewable diffs.** A pull request should say "added a retry policy to the
   copy activity", not show a few hundred lines of template with the change
   buried inside.
3. **Granularity.** `azure.datafactory.tools` deploys artifact by artifact, so
   one broken linked service fails alone rather than rolling back everything.

The cost: **disable Publish in Studio for the dev factory**
(`publishing_enabled = false`), or somebody will press it and generate an
`adf_publish` branch nobody consumes.

---

## Folder layout

The exact structure the module expects — the same structure ADF's own Git
integration writes.

```
src/adf/
  linkedService/   LS_ADLS_Lake, LS_OpenDatasets_NycTlc, LS_Synapse_Serverless,
                   LS_AzureSql_Edw, LS_KeyVault
  dataset/         DS_OpenDatasets_NycTlc_Binary, DS_Lake_Binary,
                   DS_Lake_Curated_Parquet, DS_AzureSql_Table
  pipeline/        PL_Master_NycTaxi_Load, PL_Ingest_NycTaxi_Yellow,
                   PL_Curate_NycTaxi_Yellow, PL_Load_Sql_YellowTrip,
                   PL_Backfill_NycTaxi_Yellow
  trigger/         TR_Monthly_NycTaxi_Load, TR_Tumbling_NycTaxi_Reprocess
  deployment/      config-<env>.csv, publish-options.json, README.md
```

Note what is **absent**: `integrationRuntime/` and `managedVirtualNetwork/`.
Terraform owns those. See
[00-architecture](00-architecture.md#terraform-owns-infrastructure-the-azure-player-tools-own-code).

---

## Four datasets for five pipelines

Parameterised datasets rather than one per table. `DS_AzureSql_Table` takes
`schemaName` and `tableName`; `DS_Lake_Binary` takes `fileSystem` and
`folderPath` and serves the raw sink, the curated purge, and every existence
check.

Resist `DS_AzureSql_StgYellowTaxiTrip`. Each concrete dataset is another
artifact to deploy, review and keep in sync, and none of them carries
information the activity does not already have.

### The empty `schema`

`DS_Lake_Curated_Parquet` has `"schema": []`. An empty schema makes the Copy
activity infer columns from the Parquet footer at run time, so adding a column
to the CETAS output requires no ADF change at all.

The trade-off is real: a column **rename** silently produces NULLs in the sink
instead of failing the pipeline. That is why `etl.usp_RunDataQualityChecks`
asserts on NULL rates in mandatory columns — the guard rail that makes the
loose coupling safe.

---

## The config CSV

Four columns, no header comments:

```
type,name,path,value
```

`path` is relative to the artifact's **`properties`** node, not the document
root. For:

```json
{ "name": "LS_ADLS_Lake", "properties": { "typeProperties": { "url": "..." } } }
```

the path is `typeProperties.url`, **not** `properties.typeProperties.url`.
Getting it wrong is silent by default — which is why
`Deploy-DataFactory.ps1` sets:

```powershell
$opt.FailsWhenConfigItemNotFound = $true
$opt.FailsWhenPathNotFound       = $true
```

Without those, a typo leaves the dev endpoint in the prod factory and reports
success.

### Worked examples

```
linkedService,LS_ADLS_Lake,typeProperties.url,https://stedwtaxiprodx9f2.dfs.core.windows.net
trigger,TR_Monthly_NycTaxi_Load,runtimeState,Started
pipeline,PL_Backfill_NycTaxi_Yellow,parameters.startYearMonth.defaultValue,201901
trigger,TR_*,runtimeState,Stopped
pipeline,PL_Load_Sql_YellowTrip,activities[2].typeProperties.sink.writeBatchSize,500000
```

The last one is fragile: `activities[2]` breaks the moment somebody reorders
activities in Studio, and it breaks **silently** — the tool patches whatever now
sits at index 2. Prefer, in order:

1. a pipeline **parameter** with a per-environment `defaultValue` (named, stable);
2. a global parameter;
3. `activities[n]`, only when neither works, and with a comment saying what
   index 2 was when you wrote it.

### Committed vs generated

```
config-<env>.csv             committed, reviewed.  DECISIONS: trigger state,
                             batch sizes, backfill ranges.
config-<env>.generated.csv   built at deploy time, gitignored.  FACTS from
                             Terraform: storage URLs, SQL FQDNs, endpoints.
```

`New-DeploymentConfig.ps1` merges them; generated rows win.

Committing the endpoints would mean every environment rebuild produces a PR full
of mechanical churn — and a stale CSV silently deploys a linked service pointing
at a storage account that no longer exists, which surfaces hours later as an
authentication error rather than a deployment error.

Generating the decisions would be equally wrong: "is the production trigger
enabled?" belongs in a file a reviewer reads.

The PR workflow runs `New-DeploymentConfig.ps1 -Verify`, which fails if a
committed CSV hard-codes an endpoint that has since changed.

### Config CSV vs Key Vault

You can also make an ADF linked service resolve values from Key Vault at
runtime. The template does not, for the endpoints:

| | Config CSV | Key Vault reference |
|---|---|---|
| Visible in code review | yes | no |
| Changing it | a commit | a portal click |
| Auditable | git history | Key Vault audit log |
| Requires a runtime lookup | no | yes (adds latency, a dependency, a failure mode) |

Key Vault is right for genuine **secrets**. Endpoints are not secrets, and
putting them there trades reviewability for nothing. `LS_KeyVault` is deployed
anyway, so that the moment you add a source needing a real credential the
connectivity is already proven.

---

## Publish options

[`src/adf/deployment/publish-options.json`](../src/adf/deployment/publish-options.json)
uses a schema this repository defines; `Deploy-DataFactory.ps1` translates it
into the module's own option object. The indirection means an upstream property
rename is a one-line fix rather than an edit to three workflow files.

| Option | Value | Why |
|---|---|---|
| `excludes` | `integrationRuntime.*`, `managedVirtualNetwork.*`, `managedPrivateEndpoint.*` | Terraform owns them. Without this, the two flip-flop. |
| `deleteNotInSource` | `true` everywhere | The factory converges on the repository instead of accumulating orphans. |
| `stopStartTriggers` | `true` | **Mandatory.** ADF refuses to modify a pipeline referenced by a started trigger. |
| `createNewInstance` | `false` | Terraform creates factories. A pipeline that can create factories can create them in the wrong subscription. |

Prod is deliberately identical to test. A different publish option between them
means test is not rehearsing prod; protection in prod comes from the approval
gate, not from a weakened deployment.

---

## Trigger state

Triggers are `Stopped` in source control and started per environment by the
config CSV:

```
# config-dev.csv, config-test.csv
trigger,TR_Monthly_NycTaxi_Load,runtimeState,Stopped

# config-prod.csv
trigger,TR_Monthly_NycTaxi_Load,runtimeState,Started
```

Committing `Started` would mean a developer connecting a fresh dev factory to
Git immediately starts a schedule.

The deployment sequence is: stop every trigger → publish → restart the ones that
should run. `adf-cd.yml` records the before-state, and afterwards **asserts**
that every trigger the config says should be `Started` actually is:

```
::error::Triggers were not left in the expected state after deployment
::error::  TR_Monthly_NycTaxi_Load is 'Stopped', expected 'Started'
::error::PRODUCTION LOADS WILL NOT RUN.
```

An interrupted deployment leaving production triggers stopped is a silent
outage — nothing fails, the load just never happens.

---

## Schedule vs tumbling window {#tumbling-windows}

Two triggers on the same pipeline, solving different problems.

**`TR_Monthly_NycTaxi_Load`** — schedule trigger, 03:00 UTC on the 5th, loading
the month that ended two months ago (the TLC publishes on roughly a two-month
lag; the 5th gives the Open Datasets mirror time to pick up the release).

Fire-and-forget: if 5 March fails, nothing re-runs it.

**`TR_Tumbling_NycTaxi_Reprocess`** — tumbling window trigger. Owns a
contiguous, gap-free series of windows, tracks each window's state, supports
`retryPolicy`, and can be re-run for a historical window from the ADF monitor
in two clicks. The right tool for a warehouse where every month must eventually
succeed.

It is `Stopped` in **all** environments, including prod, and should stay that
way until you have read this:

> Starting a tumbling window trigger whose `startTime` is in the past makes ADF
> immediately queue **every window since that date**. With a 2019 start date
> that is 70+ concurrent backfill runs, all contending for the same integration
> runtime, the same serverless pool, and the same staging table.

To adopt it safely:

1. Complete the backfill first, with `PL_Backfill_NycTaxi_Yellow`.
2. Set `startTime` to the month after your last loaded month.
3. Confirm `maxConcurrency: 1`.
4. Start it, and watch the first window.

---

## Defensive pipeline patterns

Three patterns used throughout, each earning its place.

**Ask only for `exists`.**

```json
"fieldList": ["exists"]
```

Requesting `childItems` on a folder that does not exist throws a generic "Path
does not exist" failure instead of returning `false` — turning "that month is
not published yet" into an opaque copy error.

**Fail loudly rather than succeeding emptily.**

```json
{ "type": "Fail", "typeProperties": { "errorCode": "SOURCE_PARTITION_NOT_PUBLISHED" } }
```

A silent no-op propagates as an empty curated partition, an empty staging table,
and a merge that inserts nothing — noticed weeks later as a gap in a report.

**Verify what you cannot see.** CETAS reports success when it writes zero rows,
so `PL_Curate_NycTaxi_Yellow` reads the count back and fails on zero.

---

## Git integration for dev

Optional and default-off in Terraform. The supported flow:

1. Deploy dev with `adf_github_configuration = null`.
2. In ADF Studio → Manage → Git configuration, connect to this repository:
   - Repository: `<owner>/<repo>`
   - Collaboration branch: `main`
   - Root folder: `/src/adf`
   - **Do not** import existing resources
3. Verify authoring works.
4. Uncomment the block in `dev.tfvars` so Terraform adopts the configuration
   rather than fighting it.

Configuring it in Terraform first creates a chicken-and-egg with the OAuth
consent flow, and the first apply afterwards frequently reports a `root_folder`
diff that never converges.

**Only dev.** Test and prod run in live mode and receive artifacts exclusively
from the pipeline. A Git-connected prod factory invites someone to publish from
Studio.

---

## Running it locally

```bash
# Dry run first — reports what would change, touches nothing.
./scripts/Deploy-DataFactory.ps1 -Environment dev -WhatIf

./scripts/Deploy-DataFactory.ps1 -Environment dev
```

Requires an authenticated **Az PowerShell** context, not just the CLI:

```powershell
Connect-AzAccount
Set-AzContext -Subscription <id>
```

In the workflows that is `azure/login@v2` with `enable-AzPSSession: true`.
Without the flag the module fails with "Run Connect-AzAccount to login".

---

Next: [07 — Synapse](07-synapse.md)
