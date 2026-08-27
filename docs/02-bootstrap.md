# 02 — Bootstrap

The complete first-deployment runbook, from an empty subscription to a loaded
warehouse. Allow about ninety minutes, most of it waiting for Azure.

---

## What bootstrap is, and why it is not in CI

`bootstrap/` is the only Terraform in this repository that a human applies from
a workstation, with local state. It creates:

1. The storage account holding Terraform state for dev/test/prod.
2. Four Entra app registrations — one per environment plus a read-only CI
   identity — each with OIDC federated credentials scoped to this repository.
3. Entra security groups used as Azure SQL and Synapse administrators.
4. The Azure RBAC tying them together.

It is deliberately not a workflow. **A pipeline that can mint its own
credentials can escalate its own privileges.** Bootstrap creates the identities
that everything else uses; if a pull request could modify it, a pull request
could grant itself Owner.

### Local state is fine here

`bootstrap/` uses local state, which is normally poor practice. It is
acceptable because:

- everything it creates is named deterministically and can be re-imported;
- it changes perhaps twice a year;
- putting its state in the account it creates is a chicken-and-egg problem.

Back up `bootstrap/terraform.tfstate` somewhere sensible. If you lose it,
[re-import rather than re-create](#recovering-lost-bootstrap-state).

---

## Step 1 — Bootstrap

```bash
az login
az account set --subscription <your-subscription-id>

# Confirm you are where you think you are. This is the step that prevents
# deploying a data platform into the wrong subscription.
az account show --query "{name:name, id:id, tenant:tenantId}" -o table

cd bootstrap
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
subscription_id = "..."            # az account show --query id -o tsv
tenant_id       = "..."            # az account show --query tenantId -o tsv

project  = "edwtaxi"               # <= 8 chars: it goes into storage account names
location = "eastus2"

# CASE-SENSITIVE. These form the OIDC subject claim; a mismatch means every
# workflow fails at azure/login with AADSTS70021 and no useful detail.
github_owner      = "your-org"
github_repository = "edw-ci-cd"

human_admin_object_ids = [
  "...",                           # az ad signed-in-user show --query id -o tsv
]
```

Then:

```bash
terraform init
terraform plan       # expect ~30 resources
terraform apply
```

### What you should see

```
Apply complete! Resources: 31 added, 0 changed, 0 destroyed.

Outputs:
backend_config = { "dev" = <<EOT ... }
ci_client_id = "..."
deploy_client_ids = { "dev" = "...", "prod" = "...", "test" = "..." }
sql_admin_group_ids = { ... }
...
```

### If it fails

| Error | Cause | Fix |
|---|---|---|
| `Insufficient privileges to complete the operation` | No Application Administrator in Entra. | Someone with the role runs this step, or grants it to you. |
| `AuthorizationFailed ... Microsoft.Authorization/roleAssignments/write` | Not Owner or User Access Administrator at subscription scope. | Get the role, or switch `deploy_scope` to `"resource_group"` and pre-create the RGs. |
| `A resource with the ID ... already exists` | A partial previous run. | `terraform import` the existing resource, or delete it and re-apply. |
| `StorageAccountAlreadyTaken` | The random suffix collided globally. | `terraform taint random_string.suffix && terraform apply`. |

---

## Step 2 — Wire up GitHub

```bash
cd ..
gh auth login              # if not already
./scripts/Set-GitHubOidcSecrets.ps1
```

This sets repository and environment **variables** — not secrets. Under OIDC
there is nothing secret to store: a client ID, a tenant ID and a subscription
ID are identifiers. The credential is the short-lived token GitHub mints per
job, which Entra accepts only for the exact repository and environment named in
the federated credential.

> If you find yourself adding `AZURE_CLIENT_SECRET`, stop and re-read
> `bootstrap/main.tf`. The whole design exists to avoid it.

### Then, by hand

The script prints these; they are here too because they matter.

**Required reviewers** — Settings → Environments → `prod` → Required reviewers.
This is the control that stops an automated pipeline changing production
unsupervised. Repeat for `test` if you want it.

**Runner labels** — Settings → Actions → Runners. Confirm your runners carry
`edw`, or set `RUNNER_LABELS`:

```bash
gh variable set RUNNER_LABELS --body '["self-hosted","linux","X64","data-platform"]'
```

**Branch protection** — Settings → Branches → `main`:
require a pull request, require the `pr-validate` checks, disallow bypass.

---

## Step 3 — Fill in the environment variables

Bootstrap produces the values; paste them in.

```bash
cd bootstrap

# Backend configuration for each environment
terraform output backend_config
#   → paste each block's values into infra/terraform/envs/<env>/backend.hcl
#     (replace REPLACE-ME-FROM-BOOTSTRAP with the storage account name)

# Admin group IDs and names
terraform output -raw 'tfvars_fragments["dev"]'
terraform output -raw 'tfvars_fragments["test"]'
terraform output -raw 'tfvars_fragments["prod"]'
#   → paste into infra/terraform/envs/<env>/<env>.tfvars
```

Then set the one value bootstrap cannot know — your runner's VNet:

```bash
az network vnet list --query "[].{name:name, rg:resourceGroup, id:id}" -o table
```

In each `envs/<env>/<env>.tfvars`:

```hcl
runner_vnet_id = "/subscriptions/.../resourceGroups/rg-runners/providers/Microsoft.Network/virtualNetworks/vnet-runners"
```

### Check for address space overlap now

Peering fails if the address spaces overlap, and the error arrives twenty
minutes into an apply.

```bash
az network vnet show --ids "$RUNNER_VNET" --query addressSpace.addressPrefixes -o tsv
```

Defaults are `10.60.0.0/24` (dev), `10.61.0.0/24` (test), `10.62.0.0/24`
(prod). If your runners are in `10.60.x`, change
`vnet_address_space` and `subnet_private_endpoints_prefix` in the tfvars.

---

## Step 4 — Deploy dev

> **Run this from the runner, or from a host inside the runner's VNet.**
> `terraform apply` creates ADLS filesystems and directories, which are
> data-plane operations against an account with no public endpoint. From a
> laptop outside the VNet those resources fail with a timeout that says nothing
> about networking.
>
> The easiest path is to trigger the **Infrastructure CD** workflow with
> `environment: dev`. If you would rather watch it locally, SSH to the runner.

```bash
cd infra/terraform
terraform init -reconfigure -backend-config=envs/dev/backend.hcl
terraform plan  -var-file=envs/dev/dev.tfvars      # ~90 resources
terraform apply -var-file=envs/dev/dev.tfvars
```

Twenty to thirty minutes. Synapse workspace creation alone is about ten.

### The one thing to check afterwards

```bash
terraform output runner_peering_enabled     # must be true
terraform output runner_vnet_dns_linked     # must be true
```

If either is `false`, stop. Nothing downstream will work, and every failure
will look like something else. See
[05-runner-connectivity](05-runner-connectivity.md).

Then prove it end to end:

```bash
cd ../..
./scripts/Test-PlatformConnectivity.ps1 -Environment dev
```

Expected:

```
  Azure SQL (TDS)  (sql-edwtaxi-dev-a7k2.database.windows.net : 1433)
  [PASS] DNS -> 10.60.0.7 (private)
  [PASS] TCP 1433 open
  ...
  All checks passed (0 warning(s)).
```

A `PUBLIC` in that output is the whole problem. Do not proceed past it.

---

## Step 5 — Deploy the code

Order matters on a first deployment. Serverless before ADF, because ADF's
`Script` activity calls a procedure that must already exist.

```bash
# 1. Synapse serverless objects — the edw_lake database and everything in it
./scripts/Deploy-ServerlessSql.ps1 -Environment dev

# 2. Synapse workspace artifacts
./scripts/Deploy-Synapse.ps1 -Environment dev

# 3. Azure SQL schema
dotnet build src/sql/EdwTaxi.Database/EdwTaxi.Database.sqlproj -c Release

SERVER=$(terraform -chdir=infra/terraform output -raw sql_server_fqdn)
DB=$(terraform     -chdir=infra/terraform output -raw sql_database_name)
ADF=$(terraform    -chdir=infra/terraform output -raw data_factory_name)
TOKEN=$(az account get-access-token --resource https://database.windows.net/ --query accessToken -o tsv)

sqlpackage /Action:Publish \
  /SourceFile:src/sql/EdwTaxi.Database/bin/Release/EdwTaxi.Database.dacpac \
  /Profile:src/sql/EdwTaxi.Database/Properties/EdwTaxi.Database.dev.publish.xml \
  /TargetServerName:"$SERVER" \
  /TargetDatabaseName:"$DB" \
  /AccessToken:"$TOKEN" \
  /v:DataFactoryName="$ADF" \
  /v:EnvironmentName=dev \
  /v:DimDateStartYear=2009 \
  /v:DimDateEndYear=2035

# 4. Data Factory artifacts
./scripts/Deploy-DataFactory.ps1 -Environment dev
```

Or, equivalently, trigger the three CD workflows with `environment: dev`.

---

## Step 6 — Load data

```bash
# Reference data first. Without it every fact row's zone keys resolve to
# Unknown and the zone quality rule fires for the whole backfill.
./scripts/Initialize-ReferenceData.ps1 -Environment dev

# One month, to prove the chain.
gh workflow run data-backfill.yml \
  -f environment=dev \
  -f start_year_month=201901 \
  -f end_year_month=201901 \
  -f initialize_reference_data=false
```

Or from ADF Studio: run `PL_Backfill_NycTaxi_Yellow` with
`startYearMonth=201901`, `endYearMonth=201901`.

Fifteen to twenty-five minutes for the first month — the managed-VNet
integration runtime pays a cold start on its first activity.

### Verify

In Synapse Studio (Built-in → `edw_lake`):

```sql
SELECT PickupYear, PickupMonth, TripCount = COUNT_BIG(*)
FROM curated.vw_YellowTaxiTrip
GROUP BY PickupYear, PickupMonth;
-- expect roughly 2.9 million rows for 2024-01
```

In Azure SQL:

```sql
SELECT TOP (5) * FROM meta.vw_LoadHistory ORDER BY LoadId DESC;

SELECT r.RuleName, d.FailedCount, d.Passed
FROM meta.DataQualityResult d
JOIN meta.DataQualityRule   r ON r.RuleId = d.RuleId
WHERE d.LoadId = (SELECT MAX(LoadId) FROM meta.LoadAudit);

SELECT TOP (10) FullDate, TripCount, TotalAmount
FROM rpt.vw_YellowTaxiTripDaily
WHERE PickupYear = 2024 AND PickupMonth = 1
ORDER BY FullDate;
```

---

## Step 7 — test and prod

Repeat steps 4–6 with `test`, then `prod`. In practice, push to `main` and let
the workflows do it:

```
Infrastructure CD  → dev → test (approval) → prod (approval)
Synapse CD         → dev → test → prod
Azure SQL CD       → build once → dev → test → prod
Data Factory CD    → dev → test → prod
```

Then load prod:

```bash
gh workflow run data-backfill.yml \
  -f environment=prod \
  -f start_year_month=201901 \
  -f end_year_month=202412
```

That is 72 months, sequentially — plan for the best part of a day. The
`concurrency` group on the workflow prevents a second backfill starting
alongside it.

Finally, confirm the production trigger is running:

```bash
RG=$(terraform  -chdir=infra/terraform output -raw resource_group_name)
ADF=$(terraform -chdir=infra/terraform output -raw data_factory_name)
az datafactory trigger list -g "$RG" --factory-name "$ADF" \
  --query "[].{name:name, state:properties.runtimeState}" -o table
```

`TR_Monthly_NycTaxi_Load` should be `Started` — set by
`src/adf/deployment/config-prod.csv`, and asserted by the last step of the
prod job in `adf-cd.yml`.

---

## Recovering lost bootstrap state

Everything bootstrap creates is deterministically named, so it can be imported
rather than re-created. Re-creating would issue new client IDs and break every
federated credential.

```bash
cd bootstrap
terraform init

SUB=$(az account show --query id -o tsv)

terraform import azurerm_resource_group.tfstate \
  "/subscriptions/$SUB/resourceGroups/rg-edwtaxi-tfstate-eastus2"

# The storage account name contains the random suffix. Find it:
az storage account list -g rg-edwtaxi-tfstate-eastus2 --query "[].name" -o tsv

terraform import azurerm_storage_account.tfstate \
  "/subscriptions/$SUB/resourceGroups/rg-edwtaxi-tfstate-eastus2/providers/Microsoft.Storage/storageAccounts/<name>"

# Entra objects import by OBJECT ID, not application ID.
az ad app list --display-name "sp-edwtaxi-github-deploy-dev" --query "[].id" -o tsv
terraform import 'azuread_application.deploy["dev"]' "/applications/<object-id>"

# ... repeat for test, prod, the CI app, the service principals and the groups.
terraform plan     # should end up empty
```

Then pin the suffix so a future state loss cannot change it:

```hcl
# in terraform.tfvars — not a variable in bootstrap by default; add one if you
# have been through this once and never want to again.
```

---

## Tearing down

```bash
cd infra/terraform
terraform init -reconfigure -backend-config=envs/dev/backend.hcl
terraform destroy -var-file=envs/dev/dev.tfvars
```

Two things survive on purpose:

- **Key Vault** is soft-deleted, not purged (`purge_soft_delete_on_destroy = false`).
  Recreating with the same name recovers it — which is why dev has
  `purge_protection_enabled = false`. To purge deliberately:
  `az keyvault purge --name <vault> --location <region>`.
- **Log Analytics** is soft-deleted for 14 days.

Bootstrap should normally be left alone. If you genuinely want it gone:

```bash
cd bootstrap
terraform destroy      # prevent_destroy on the state account will block this
```

Remove the `lifecycle { prevent_destroy = true }` block from
`azurerm_storage_account.tfstate` first, and be sure — that account holds the
state for every environment.

---

Next: [03 — Terraform](03-terraform.md)
