# ADF deployment configuration

Everything in this folder feeds [`azure.datafactory.tools`](https://github.com/Azure-Player/azure.datafactory.tools).

## The two-file model

Per-environment configuration is split deliberately:

| File | Owner | Contents | Committed? |
|---|---|---|---|
| `config-<env>.csv` | **You** | Decisions a human makes: which triggers run, batch sizes, timeouts, retention parameters. | Yes — reviewed in PRs |
| `config-<env>.generated.csv` | **CI** | Endpoints derived from Terraform: storage URLs, SQL FQDNs, Synapse endpoints. | No — built at deploy time |

At deploy time `scripts/Deploy-DataFactory.ps1` calls
`scripts/New-DeploymentConfig.ps1`, which reads `terraform output -json
deployment_config` and **merges** the two into the file actually passed to
`Publish-AdfV2FromJson`. Generated rows win on conflict.

### Why not just commit the real values?

Because the resource names carry a random suffix (`adf-edwtaxi-dev-a7k2`).
Committing them means every environment rebuild produces a pull request full of
mechanical noise, and — worse — a stale CSV deploys a linked service pointing at
a storage account that no longer exists. The failure surfaces hours later as an
authentication error, not as a deployment error.

### Why not generate everything?

Because "is the production trigger enabled?" is a decision, not a fact about
infrastructure. It belongs in a file a reviewer reads, not in a script's output.

---

## CSV format

Four columns, no header comments (the parser does not strip them):

```
type,name,path,value
```

* **type** — `linkedService`, `pipeline`, `dataset`, `trigger`, `dataflow`,
  `integrationRuntime`, `managedVirtualNetwork`, `factory`
* **name** — the artifact name. `*` wildcards are supported, e.g. `TR_*`
* **path** — dot/bracket path **relative to the object's `properties` node**.
  So for a linked service whose JSON is
  `{"name":"LS_X","properties":{"typeProperties":{"url":"..."}}}` the path is
  `typeProperties.url` — *not* `properties.typeProperties.url`.
* **value** — the replacement value

### Worked examples

Rewrite a linked service endpoint:

```
linkedService,LS_ADLS_Lake,typeProperties.url,https://stedwtaxiprodx9f2.dfs.core.windows.net
```

Enable a trigger in production only:

```
trigger,TR_Monthly_NycTaxi_Load,runtimeState,Started
```

Change a pipeline parameter default:

```
pipeline,PL_Backfill_NycTaxi_Yellow,parameters.startYearMonth.defaultValue,201901
```

Reach into an activity — note the array index:

```
pipeline,PL_Load_Sql_YellowTrip,activities[2].typeProperties.sink.writeBatchSize,500000
```

Wildcard across every trigger:

```
trigger,TR_*,runtimeState,Stopped
```

### Path-into-activity is fragile

`activities[2]` breaks the moment somebody reorders activities in ADF Studio,
and it breaks **silently** — the tool patches whatever now sits at index 2.
Prefer, in order:

1. A pipeline **parameter** with a per-environment `defaultValue` (stable, named).
2. A **global parameter**.
3. An `activities[n]` path, only when neither of the above is possible, and with
   a comment in this README explaining what index 2 was when you wrote it.

---

## What is deliberately NOT deployed from here

`publish-options.json` excludes `integrationRuntime` and
`managedVirtualNetwork`. Those are owned by Terraform
(`infra/terraform/modules/datafactory`), because they are network-and-identity
shaped and must exist *before* any linked service that references
`IR-ManagedVNet` can deploy.

If you ever see Terraform and the ADF pipeline flip-flopping an integration
runtime on alternate deployments, that exclusion is what has gone missing.

`../integrationRuntime/IR-ManagedVNet.json` exists anyway, as a placeholder the
exclusion keeps out of every deployment. The module resolves `connectVia`
references against the source folder, not against the live factory, so without
that file `Test-AdfCode` fails with five missing-reference errors and
`Publish-AdfV2FromJson` fails with `ADFT0005` before deploying anything. It is
also what keeps `deleteNotInSource: true` honest: the runtime is now *in*
source, so it cannot be considered an orphan. (The exclusion alone would already
protect it — `DoNotDeleteExcludedObjects` defaults to true — but relying on a
default nobody sets is thinner cover than the file.)

`publish-options.json` itself must be kept out of the module's config-file
validation, which globs `deployment/*.csv` and `deployment/*.json`: it uses our
schema, not the module's, and each top-level property would be read as an
artifact name to patch. `adf-cd.yml` passes
`-ConfigPath 'src/adf/deployment/config-*.csv'` to `Test-AdfCode` for exactly
this reason. Without it you get `ADFT0017: Object [$comment] could not be found.`

See the long comment at the top of
`infra/terraform/modules/datafactory/main.tf` for the full ownership table.
