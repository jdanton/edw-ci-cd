# 09 — CI/CD workflows

Ten workflows. What triggers each, what gates it, and why the pipelines are
separate.

---

## The set

| Workflow | Trigger | Gates | Purpose |
|---|---|---|---|
| [`pr-validate.yml`](../.github/workflows/pr-validate.yml) | pull request | none — read-only identity | fmt, validate, plan, build, lint, config drift |
| [`infra-cd.yml`](../.github/workflows/infra-cd.yml) | push to `main` under `infra/`, or manual | Environment approvals | Terraform, dev → test → prod |
| [`adf-cd.yml`](../.github/workflows/adf-cd.yml) | push under `src/adf/`, or manual | Environment approvals | `azure.datafactory.tools` |
| [`synapse-cd.yml`](../.github/workflows/synapse-cd.yml) | push under `src/synapse/`, or manual | Environment approvals | artifacts**and** serverless SQL |
| [`sql-cd.yml`](../.github/workflows/sql-cd.yml) | push under `src/sql/`, or manual | Environment approvals | build once, publish thrice |
| [`data-backfill.yml`](../.github/workflows/data-backfill.yml) | manual only | Environment approvals | run an ADF pipeline and wait |
| [`drift-detect.yml`](../.github/workflows/drift-detect.yml) | 06:00 UTC weekdays | none — plan only | detect out-of-band changes |
| `_terraform-apply.yml` | reusable | — | one environment's plan/apply/verify |
| `_synapse-deploy.yml` | reusable | — | one environment's two Synapse halves |
| `_sql-publish.yml` | reusable | — | one environment's DACPAC publish |

---

## Why four CD pipelines and not one

Path filters. A change to a pipeline JSON must not re-plan the whole platform,
and a change to a VNet CIDR must not republish a factory.

The practical benefit shows up during an incident: a broken ADF pipeline is
fixed and deployed in four minutes without touching Terraform, Synapse or the
database. One monolithic pipeline would mean a twenty-minute deployment and a
much larger blast radius for a one-line fix.

The one ordering constraint: **infrastructure must exist before artifacts can
deploy into it.** On a first-ever deployment, run `infra-cd` to completion
first. After that they are independent.

---

## Everything runs on your self-hosted runners

```yaml
runs-on: ${{ fromJSON(vars.RUNNER_LABELS || '["self-hosted","linux","X64","edw"]') }}
```

Including `pr-validate`. `terraform plan` is not purely a control-plane
operation here: refreshing `azurerm_storage_data_lake_gen2_filesystem` calls the
ADLS **data** plane, which has no public endpoint. On a GitHub-hosted runner
those refreshes hang and fail with a timeout that says nothing about
networking.

The jobs that need no Azure access at all — linting, the DACPAC build — are
separated out so they still give fast feedback when the runner pool is busy.

---

## Authentication

OIDC federation. No secrets anywhere.

```yaml
permissions:
  id-token: write        # mint the OIDC token
  contents: read

steps:
  - uses: azure/login@v2
    with:
      client-id: ${{ vars.AZURE_CLIENT_ID }}
      tenant-id: ${{ vars.AZURE_TENANT_ID }}
      subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      enable-AzPSSession: true
```

The token carries a subject claim GitHub builds from the job's context:

| Job context | Subject | Which identity |
|---|---|---|
| `environment: dev` | `repo:owner/repo:environment:dev` | `sp-<project>-github-deploy-dev` |
| `environment: prod` | `repo:owner/repo:environment:prod` | `sp-<project>-github-deploy-prod` |
| pull request | `repo:owner/repo:pull_request` | `sp-<project>-github-ci` (Reader) |
| scheduled on `main` | `repo:owner/repo:ref:refs/heads/main` | the deploy identity, for drift detection |

Entra exchanges the token only for the service principal whose federated
credential names that **exact** subject. A job without an `environment:` block
cannot authenticate as a deployment identity at all — a much better failure than
one that authenticates as the wrong environment.

### Two identities, deliberately

Pull requests get **Reader**. A PR can change workflow files, so a workflow that
can deploy is a workflow anyone with fork access can turn into a deployment. The
CI identity holds Reader on the subscription and write access to nothing except
the Terraform state lock blob — `plan` needs to take the lock.

It is explicitly **not** granted Key Vault access. Plan-time secret reads are a
data-exfiltration vector on fork PRs.

### `enable-AzPSSession`

`azure.datafactory.tools` and `azure.synapse.tools` are built on the Az
PowerShell modules. Without this flag only the Azure CLI is authenticated, and
the modules fail with "Run Connect-AzAccount to login". It is also needed by the
Terraform provisioner that approves private endpoints, which shells out to `az`.

---

## Approval gates

Protection rules live on the GitHub **Environments**, not in YAML. Putting them
in a workflow file would mean a pull request could edit them.

Settings → Environments → `prod`:

| Rule | Effect |
|---|---|
| Required reviewers | The job queues until a human approves. This is the real control. |
| Wait timer | Optional. Useful when you want a window to cancel. |
| Deployment branches | `main` only. Enforced by GitHub **before** the token is minted. |

That last one matters more than it looks. The OIDC subject says
`environment:prod` — it does not say which branch asked. Without the branch
restriction, a feature branch could run a job with `environment: prod` and Entra
would issue a token. `Set-GitHubOidcSecrets.ps1` sets the policy; verify it.

### If you cannot use Environments

Private repositories on GitHub Free do not have them. Then:

- there are no approval gates;
- the OIDC subject becomes `repo:owner/repo:ref:refs/heads/main`, so you need a
  single federated credential and effectively a single identity for all
  environments.

That collapses the isolation between dev and prod. If Environments are not
available, use three separate repositories or a different CD system — do not
pretend the isolation exists.

---

## Concurrency

```yaml
concurrency:
  group: infra-cd
  cancel-in-progress: false
```

`cancel-in-progress: false` on every deployment workflow. Cancelling a
Terraform apply midway leaves a state lock and possibly a half-created
environment; cancelling a `sqlpackage` publish can leave the database in a
partially-migrated state. Deployments queue.

The exception is `pr-validate`, where `cancel-in-progress: true` is right — a
plan against superseded code helps nobody.

`data-backfill.yml` scopes its group per environment, because two concurrent
backfills would both truncate `stg.YellowTaxiTrip` and interleave, producing a
partition missing rows from both. `PL_Load_Sql_YellowTrip` pins pipeline
concurrency to 1 as well; this is the outer belt to that inner braces.

---

## Promotion

```
push to main
     │
     ├── infra-cd     dev ──▶ test (approval) ──▶ prod (approval)
     ├── adf-cd       dev ──▶ test (approval) ──▶ prod (approval)
     ├── synapse-cd   dev ──▶ test (approval) ──▶ prod (approval)
     └── sql-cd    build ──▶ dev ──▶ test (approval) ──▶ prod (approval)
```

Strictly sequential, with `needs:`. A failure in dev stops the chain.

The `if:` conditions look convoluted:

```yaml
if: |
  always() &&
  (needs.dev.result == 'success' || needs.dev.result == 'skipped') &&
  (github.event_name == 'push' || inputs.environment == 'all' || inputs.environment == 'test')
```

`always()` is needed because a *skipped* dependency would otherwise skip this
job too — which breaks "deploy test only" via `workflow_dispatch`. The result
check restores the "do not proceed past a failure" semantics that `always()`
removed.

### Environment parity

Test rehearses production. Deliberate differences:

| | test | prod | Why |
|---|---|---|---|
| SQL SKU | `GP_S_Gen5_2` serverless | `GP_Gen5_4` provisioned | Cost. Auto-pause is wrong in prod: the first query of the morning would pay a 30–60s resume, and a paused database cannot be a scheduled load target. |
| Zone redundancy | off | on | Cost. |
| Trigger | Stopped | Started | Test is driven by explicit backfills. |
| Bastion | off | on | Break-glass access matters where an outage costs money. |
| Log retention | 30 days | 90 days | Quarter-end investigations. |

Everything about **safety** is identical: `BlockOnPossibleDataLoss`,
`BlockWhenDriftDetected`, `ExcludeObjectTypes`, publish options. If you relax
one in test to get a deployment through, you have found something that will
fail in prod.

---

## What each workflow actually checks

### `pr-validate`

- `terraform fmt -check -recursive` — fails on unformatted files.
- `terraform validate` on the root, `bootstrap/`, **and every module
  independently** — a module broken in isolation but unused by the root would
  otherwise pass.
- Every ADF and Synapse JSON parses.
- `PSScriptAnalyzer` on `scripts/` — errors fail, warnings annotate.
- `dotnet build` the DACPAC with `-warnaserror`.
- `terraform plan` against dev with the read-only identity, published as a job
  summary and an artifact.
- `New-DeploymentConfig.ps1 -Verify` — fails if a committed config CSV
  hard-codes an endpoint that has since changed.

### `adf-cd`

- `Test-AdfCode` — the module's own static validator. Catches what a JSON parse
  cannot: a dataset referencing a missing linked service, an activity naming a
  missing pipeline. Every one of those deploys "successfully" and fails at run
  time.
- After the prod deployment, **asserts trigger state**. An interrupted
  deployment leaving production triggers stopped is a silent outage — nothing
  fails, the load just never happens.

### `synapse-cd`

- Serverless script ordering: every file has an `NNN_` prefix and no two share
  one. The prefixes *are* the dependency graph.
- Both halves deployed, in order.
- A smoke test that counts objects **and** probes storage access — the check
  that catches a missing `Storage Blob Data Contributor` grant, which SQL
  reports as "content of directory cannot be listed".

### `sql-cd`

- Build once, in the first job. Every environment downloads the same artifact.
- `DeployReport` and `Script` before every publish, both uploaded, with data-loss
  alerts surfaced in the job summary rather than buried in XML.
- Post-deploy verification: object counts, `dim.Date` populated, quality rules
  seeded, and the ADF database user present.

That last check is the highest-value one in the file. Without it, a deployment
that silently failed to create the ADF user reports success and every pipeline
fails hours later with "Login failed for user '<token-identified principal>'".

### `drift-detect`

Plans every environment at 06:00 on weekdays and reports differences. It
**never applies**: automatically "correcting" drift is how you delete the
emergency fix currently holding production together.

It uses `-lock=false`, because taking the state lock would block a real
deployment that happened to start at 06:00.

When drift is found, decide:

- **Adopt** — the change was right. Put it in `infra/terraform` and open a PR,
  so the next deployment does not revert it.
- **Revert** — run `infra-cd`, which restores the declared state.

Do not ignore it. The next deployment reverts it silently.

---

## Adapting

**Different runner labels:**

```bash
gh variable set RUNNER_LABELS --body '["self-hosted","linux","X64","data-platform"]'
```

**Only two environments:** delete the `prod` jobs and the `prod` entry in
`bootstrap/terraform.tfvars`.

**Different regions per environment:** already supported — `location` and
`location_short` are per-environment tfvars.

**A separate subscription per environment:** set `subscription_id` per
environment tfvars, and in `bootstrap/`, run one apply per subscription with a
different `environments` map. The state account can stay in one of them.

---

Next: [10 — Making a change](10-making-a-change.md)
