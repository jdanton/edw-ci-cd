# 14 — Coming from a manual deployment

For people who already run this stack — Data Factory, Synapse, Azure SQL, all of
it private — and deploy it by hand. You know the services. What changes is who
presses the button, and where the truth lives.

Read this before [02-bootstrap](02-bootstrap.md). It is orientation, not a
runbook.

---

## The one idea

**Git is the deployed state. Nothing else is.**

Manual deployment makes the live environment the source of truth: you change ADF
in Studio, run a script in SSMS, tick a box in the portal, and the repository —
if there is one — is a record written afterwards, when someone remembers.

Here that is inverted. The repository is what exists; environments are
projections of it. Every consequence below follows from that one inversion, and
so does every habit that has to change.

The practical test: **if you can make a change that no commit describes, the
model is broken.** Not "discouraged" — broken, because the next deployment will
either revert your change or fail on it.

---

## What replaces what

| You do today | Here | Where |
|---|---|---|
| Click **Publish** in ADF Studio | Push to `main`; `adf-cd` deploys the artifact JSON | [06](06-data-factory.md) |
| Export an ARM template, edit parameters per environment | `config-<env>.csv`, generated from Terraform outputs | [06](06-data-factory.md) |
| Run `.sql` files in SSMS against each server | `sqlpackage` publishes one DACPAC, built once, to each environment | [08](08-azure-sql.md) |
| Create the serverless database and views by hand | `src/synapse/serverless/*.sql`, run in numeric order | [07](07-synapse.md) |
| Create resources in the portal | Terraform, one state file per environment | [03](03-terraform.md) |
| Assign RBAC in the portal | `rbac.tf`, plus Entra groups from `bootstrap/` | [02](02-bootstrap.md) |
| Store a connection string in Key Vault and paste it | Managed identity everywhere; no password exists to store | [00](00-architecture.md) |
| A service principal secret in a variable group | OIDC federation — no secret to rotate or leak | [09](09-cicd-workflows.md) |
| "Deploy to test" means someone runs the same steps again | The same commit promotes dev → test → prod | [09](09-cicd-workflows.md) |

---

## Five habits that have to go

**1. The Publish button.** The dev factory has `publishing_enabled = false` for a
reason. Publishing generates an `adf_publish` branch nobody consumes, and the
artifact then differs from every reviewed commit. Author in Studio if you like —
then commit what it wrote.

**2. Editing anything in test or prod.** Not because it is naughty, but because
`deleteNotInSource: true` means the next deployment deletes what you added, and
Terraform reverts what you changed. Your work will disappear on someone else's
schedule. If it is worth doing, it is worth a commit.

**3. One-off SSMS scripts.** A statement you ran once is a statement the next
environment will not have. Objects go in `src/sql/` (the DACPAC) or
`src/synapse/serverless/` (numeric-prefixed scripts). Both are idempotent, so
re-running is free and rebuilding an environment reproduces your fix.

**4. Portal RBAC.** A role assignment made by hand survives until someone reads
the plan and wonders why Terraform wants to remove it. Data-plane grants in
particular — `Storage Blob Data Contributor`, Key Vault roles — are the ones
people reach for in a hurry and are exactly the ones `rbac.tf` manages.

**5. "It worked in dev."** It means less here than you are used to, for a
specific reason worth its own section.

---

## What will genuinely surprise you

### Deployment success is not execution success

This is the biggest adjustment coming from manual work, where you generally
watch the thing run.

Several classes of defect deploy perfectly and fail only when something executes
them:

| Defect | Deploys | Fails at |
|---|---|---|
| A container activity nested in another (`ForEach` inside `IfCondition`) | ✅ | first pipeline run |
| `filepath()` / `filename()` referenced inside a CETAS | ✅ | first curate run |
| Dynamic SQL over 4000 characters, silently truncated | ✅ | first execution, as a parse error mid-statement |
| A linked service with anonymous auth and no `containerUri` | ✅ | first activity that reads it |
| `THROW` in Synapse serverless | ❌ (caught at deploy) | — |

Every one of those is in [12-troubleshooting](12-troubleshooting.md) with its
real error text, because each cost real time to identify. Their common shape:
**the message names a token, a file or a service that is not the cause.**

The habit that helps: a green deployment means the artifact was accepted. It
does not mean the artifact works. Run the thing.

### There are three permission systems, not one

Coming from manual deployment you probably think of Azure RBAC and SQL
permissions. Synapse has a third, and it is invisible from the portal blade you
would naturally check.

| System | Governs | Set by |
|---|---|---|
| Azure RBAC | The resource: create, delete, read properties | `rbac.tf`, `bootstrap/` |
| Entra SQL admin | Authentication to the SQL endpoints | `azurerm_synapse_workspace_sql_aad_admin` |
| **Synapse RBAC** | **Studio, the Dev API, and serverless SQL** | `azurerm_synapse_role_assignment` |

A subscription **Owner** who is a member of the Entra admin group still gets

```
Failed to load one or more resources due to no access, error code 403
```

on every dataset and pipeline in Studio, and cannot query the serverless
endpoint, until they hold a Synapse role. The workspace creator gets one
implicitly — and the creator is the deployment service principal, because
Terraform builds the workspace. So CI works from day one while humans are locked
out, which is a confusing way round.

`azurerm_synapse_role_assignment.admins` grants the admin group Synapse
Administrator so a new environment does not ship in that state.

### Your runners must be on the network

Every data plane here is private. A GitHub-hosted runner cannot create an ADLS
filesystem, publish a Synapse artifact, run serverless DDL, or publish a DACPAC.
None of those fail with a network error — they hang, then time out blaming SQL
or the REST API.

If your current deployment works from a laptop on the corporate VPN, that is the
capability you are replacing, and [05](05-runner-connectivity.md) is the page to
read properly rather than skim.

### Serverless SQL objects are not artifacts

The single most common misconception. A "SQL script" in Synapse Studio is a
saved query tab. Deploying it does not execute it. `edw_lake`, its external data
sources, views and procedures are ordinary T-SQL and need a TDS connection —
which is why `synapse-cd` has two halves and why skipping the second one gives
you a workspace that looks perfect and a factory where everything fails.

### Serverless databases pause, and clients do not wait

dev and test run auto-pausing SKUs. A paused database accepts the TCP connection
and then takes 30–60 seconds to resume, which is longer than `sqlpackage` or
`Invoke-Sqlcmd` will wait. You get

```
Connection Timeout Expired. The timeout period elapsed during the post-login phase.
```

which reads like a firewall or a port-range problem and is neither. Every SQL
caller in `scripts/` goes through `Invoke-SqlWithRetry` in `_Tooling.ps1`, which
retries that and nothing else — retrying a syntax error would turn a
five-second failure into a five-minute one.

---

## Your first week

1. **Read [00-architecture](00-architecture.md).** Layer by layer, and why.
2. **Do [01-prerequisites](01-prerequisites.md) honestly.** The runner section
   is the one that decides whether the rest of the week works.
3. **Run `bootstrap/` yourself.** Once per subscription, from a workstation,
   never from CI — a pipeline that can mint its own credentials can escalate its
   own privileges. Back up its state and `terraform.tfvars` somewhere your team
   can find them; losing them is recoverable but tedious.
4. **Deploy dev only.** `infra-cd` for dev, then Synapse, ADF, SQL.
5. **Run `Test-PlatformConnectivity.ps1` before believing anything.** It
   separates DNS, routing and identity in about twenty seconds, and almost every
   confusing failure downstream is one of those three.
6. **Load one month.** `data-backfill` for a single month proves the whole chain
   end to end. Expect to find something; a first execution usually does.
7. **Only then create test.** New environments are deliberate: `infra-cd` skips
   an environment with no state unless you dispatch it by name, so a shared
   module edit cannot build one by accident.

---

## How a change flows now

```
branch ──▶ pull request ──▶ main ──▶ dev ──▶ test (approval) ──▶ prod (approval)
             │                         │
             │                         └── same commit, same DACPAC, same artifacts
             └── plan, validate, lint: read-only identity, no deployment rights
```

Three properties worth internalising, because they are what you are buying:

- **The same artifact reaches prod.** The DACPAC is built once. Rebuilding per
  environment means the thing approved is not the thing tested.
- **Approvals are GitHub Environment rules, not YAML.** In YAML a pull request
  could edit them.
- **A failure in dev stops the chain.** Promotion is not a schedule.

Worked examples, including adding a column end to end, are in
[10-making-a-change](10-making-a-change.md).

---

## Where it will hurt

Honesty is more useful than encouragement here.

**First runs find bugs.** Not usually yours — a template's paths get exercised
in an order nobody rehearsed. Budget for the first end-to-end taking a day of
small, real fixes rather than an afternoon.

**DNS is the recurring villain.** Nine `privatelink` zones per environment, and
a virtual network may hold exactly **one** link per zone namespace. That means
you cannot give each environment its own copy of the zones and link them all to
one runner VNet: the second environment is refused. Environments after the first
consume the zones the first one created, or you use a central connectivity
subscription. [04](04-networking.md#central-dns) covers the shape.

**Some settings are invisible to `plan`.** The Synapse workspace must be created
with public access enabled and is closed immediately afterwards, so the
attribute sits in `ignore_changes`. Open it to debug something and nothing will
ever close it again — `drift-detect` reports it precisely because `plan` cannot.

**Costs start at creation, not at use.** Ten private endpoints per environment
is roughly $73/month before anything runs. [13-cost](13-cost.md) has the
breakdown; the surprise is always the endpoints.

---

## Reading map

| When | Read |
|---|---|
| Before anything | [00](00-architecture.md), [01](01-prerequisites.md) |
| Runners will not reach the platform | [05](05-runner-connectivity.md) |
| First deployment | [02](02-bootstrap.md) |
| A deployment went green and the thing still fails | [12](12-troubleshooting.md) |
| Changing a pipeline, a table, a view | [10](10-making-a-change.md) |
| An alert fired | [11](11-operations-runbook.md) |
| Someone asks what this costs | [13](13-cost.md) |
