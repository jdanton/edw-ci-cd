# 12 — Troubleshooting

Error messages mapped back to what actually caused them. Most of the entries
here exist because the message names the wrong layer.

---

## Start here

```bash
./scripts/Test-PlatformConnectivity.ps1 -Environment dev
```

If anything fails there, fix that first. Every downstream error will be a
misleading symptom of it.

### The decision tree

```
Does the name resolve to a PRIVATE (10.x / 172.16-31.x / 192.168.x) address?
├── NO  → DNS. The privatelink zone is not linked to this host's VNet.
│         → §"Resolves to a public IP"
└── YES
    │
    Does TCP connect?
    ├── NO  → Routing. Peering missing, one-sided, or NSG blocking.
    │         → §"Resolves privately but times out"
    └── YES
        │
        Does authentication succeed?
        ├── NO  → Identity. Layer 1 (RBAC) or Layer 3 (SQL principal).
        │         → §"Login failed" / §"403 on storage"
        └── YES → It is a genuine application error. Read the message.
```

---

## Networking

### Resolves to a public IP

```
[FAIL] DNS -> 20.42.65.90 (PUBLIC)
```

**Cause.** The `privatelink.*` zone is not linked to this host's VNet, or your
custom DNS does not forward it.

**Check:**

```bash
az network private-dns link vnet list \
  -g rg-edwtaxi-dev-eus2 -z privatelink.database.windows.net \
  --query "[].{link:name, vnet:virtualNetwork.id}" -o table

terraform -chdir=infra/terraform output runner_vnet_dns_linked   # want true
```

**Fix:**

```hcl
# envs/<env>/<env>.tfvars
runner_vnet_id                  = "/subscriptions/.../virtualNetworks/vnet-github-runners"
link_private_dns_to_runner_vnet = true
```

If the runner VNet uses custom DNS, linking does nothing — the VMs ask your
servers. See [05-runner-connectivity](05-runner-connectivity.md#custom-dns).

### Resolves privately but times out

```
[PASS] DNS -> 10.60.0.7 (private)
[FAIL] TCP 1433 did not connect within 10s
```

**Cause 1 — one-sided peering.** Azure peering is not implicit. A peering
created in one direction shows `Initiated` and carries no traffic.

```bash
az network vnet peering list -g rg-edwtaxi-dev-eus2 --vnet-name vnet-edwtaxi-dev \
  --query "[].{name:name, state:peeringState}" -o table
az network vnet peering list -g rg-github-runners --vnet-name vnet-github-runners \
  --query "[].{name:name, state:peeringState}" -o table
```

Both must say `Connected`. Terraform creates both when `peer_runner_vnet = true`
and it has Network Contributor on the runner VNet.

**Cause 2 — NSG.** For Azure SQL specifically, check **11000-11999** as well as
1433. Connections originating inside Azure negotiate Redirect mode; blocking
that range produces "A network-related or instance-specific error occurred",
which mentions no port.

```bash
az network nsg rule list -g rg-edwtaxi-dev-eus2 --nsg-name nsg-edwtaxi-dev-pe -o table
```

### `sqlpackage` times out but `nc` on 1433 succeeds

Same cause: 11000-11999. The initial handshake reaches the gateway on 1433,
which then hands back a node address on a high port.

---

## Identity and permissions

### ADF cannot log in to Azure SQL {#adf-cannot-log-in-to-azure-sql}

```
Login failed for user '<token-identified principal>'
```

**This is not networking.** It is layer 3: the managed identity has no principal
inside the database. Azure RBAC cannot create one — SQL keeps its own principal
store.

**Check:**

```sql
SELECT name, type_desc, create_date
FROM sys.database_principals
WHERE type IN ('E', 'X');       -- external user, external group
```

If `adf-edwtaxi-dev-a7k2` is absent, `Scripts/PostDeploy/040_ServicePrincipals.sql`
did not run or failed.

**Fix** — re-deploy, and read the log for the warning block that script prints:

```bash
gh workflow run sql-cd.yml -f environment=dev
```

Or by hand, connected **as an Entra principal** (a SQL login cannot do this,
even as sysadmin):

```sql
CREATE USER [adf-edwtaxi-dev-a7k2] FROM EXTERNAL PROVIDER;
GRANT SELECT, INSERT, DELETE ON SCHEMA::stg  TO [adf-edwtaxi-dev-a7k2];
GRANT EXECUTE                ON SCHEMA::etl  TO [adf-edwtaxi-dev-a7k2];
GRANT SELECT                 ON SCHEMA::meta TO [adf-edwtaxi-dev-a7k2];
GRANT SELECT                 ON SCHEMA::dim  TO [adf-edwtaxi-dev-a7k2];
GRANT ALTER ON OBJECT::stg.YellowTaxiTrip TO [adf-edwtaxi-dev-a7k2];
```

Common reasons the automated step fails:

| Cause | Symptom |
|---|---|
| sqlpackage used SQL auth | `Principal 'x' could not be found or this principal type is not supported` |
| Wrong `$(DataFactoryName)` | The principal name must be the **resource name**, not the object ID or application ID. |
| No Graph access | The database resolves the principal through Microsoft Graph. |

### `Cannot find the object 'stg.YellowTaxiTrip'` on TRUNCATE

```
Cannot find the object "stg.YellowTaxiTrip" because it does not exist
or you do not have permissions.
```

The object exists. `TRUNCATE TABLE` requires **ALTER** on the table — it is a
DDL operation, and `DELETE` permission does not cover it.

```sql
GRANT ALTER ON OBJECT::stg.YellowTaxiTrip TO [adf-edwtaxi-dev-a7k2];
```

`040_ServicePrincipals.sql` grants this; if you built permissions by hand, this
is the line people miss.

### 403 on storage from Terraform or a script {#storage-403}

```
AuthorizationPermissionMismatch: This request is not authorized to perform
this operation using this permission.
```

**Cause.** ARM `Contributor` does **not** grant blob data access. Data-plane
operations need a `Storage Blob Data *` role. This is the single most common
ADLS permissions surprise.

```bash
STORAGE_ID=$(terraform -chdir=infra/terraform output -raw storage_account_name)
ME=$(az ad signed-in-user show --query id -o tsv)

az role assignment list --assignee "$ME" --scope "/subscriptions/.../$STORAGE_ID" \
  --query "[].roleDefinitionName" -o tsv
```

`rbac.tf` grants `Storage Blob Data Contributor` to the deployment identity
(`deployer_lake_contributor`). If you are a human running this locally, grant
yourself the same.

RBAC takes a couple of minutes to propagate to the data plane. If you just
granted it, wait.

### Serverless: `content of directory cannot be listed`

```
External table is not accessible because content of directory cannot be listed.
```

Reads like a path bug. It is **storage RBAC**.

**If the PIPELINE fails:** the Synapse workspace managed identity lacks
`Storage Blob Data Contributor`. Contributor, not Reader — CETAS writes.

```bash
SYN_MI=$(terraform -chdir=infra/terraform output -raw synapse_principal_id)
az role assignment list --assignee "$SYN_MI" --query "[].roleDefinitionName" -o tsv
```

`rbac.tf` → `synapse_lake_contributor`.

**If a PERSON fails and the pipeline works:** serverless passes the caller's
identity through for any external data source without a credential. The human
needs `Storage Blob Data Reader`. `rbac.tf` → `synapse_admins_lake_reader`
grants it to the Synapse admin group; add other users to that group.

### Key Vault 403 during `terraform apply` {#key-vault-403}

```
Caller is not authorized to perform action on resource
```

**Cause 1 — RBAC propagation.** The vault uses RBAC authorization, and grants
take up to a couple of minutes to reach the data plane. `secrets.tf` has a
60-second `time_sleep` for this. If it still fails, wait and re-apply.

**Cause 2 — Contributor is not enough.** With `rbac_authorization_enabled`, the
data plane is a separate permission surface. You need
`Key Vault Secrets Officer`.

**Cause 3 — network.** The vault has no public endpoint. Apply from inside the
VNet.

### `AADSTS700213: No matching federated identity record found` {#aadsts700213}

```
AADSTS700213: No matching federated identity record found for presented
assertion subject 'repo:jdanton@7385792/edw-ci-cd@1341714815:pull_request'
```

Look closely at the subject: it contains `@7385792` and `@1341714815`. Those are
the GitHub **owner ID** and **repository ID**. This is the *immutable* subject
format, and your federated credential is registered with the legacy name-based
form.

This is a genuine security improvement rather than churn — a repository name can
be renamed, transferred, deleted and re-registered by someone else, so a
name-based credential can in principle be inherited by a different repository.
Numeric IDs cannot be.

Check which form your repository issues:

```bash
gh api repos/<owner>/<repo>/actions/oidc/customization/sub
```

Read `sub_claim_prefix`. Note that `use_immutable_subject: false` does **not**
reliably mean legacy subjects are issued during the rollout — the prefix field
is the accurate signal, and the subject in the error message is definitive.

Fix it in `bootstrap/terraform.tfvars`, not the portal, so it survives a
rebuild:

```bash
gh api repos/<owner>/<repo> --jq '{owner_id: .owner.id, repo_id: .id}'
```

```hcl
use_immutable_subject_claim = true
github_owner_id             = 7385792
github_repository_id        = 1341714815
```

```bash
cd bootstrap && terraform apply
```

Subjects update **in place** — no credential is destroyed, so there is no window
where authentication is broken.

### `AADSTS70021: No matching federated identity record found`

The OIDC subject does not match any federated credential.

```bash
APP_ID=$(az ad app list --display-name "sp-edwtaxi-github-deploy-dev" --query "[0].id" -o tsv)
az ad app federated-credential list --id "$APP_ID" --query "[].{name:name, subject:subject}" -o table
```

Compare with what the job actually sends. `github_owner` and
`github_repository` in `bootstrap/terraform.tfvars` are **case-sensitive**.

| Job | Subject |
|---|---|
| `environment: dev` | `repo:owner/repo:environment:dev` |
| pull request | `repo:owner/repo:pull_request` |
| scheduled on main | `repo:owner/repo:ref:refs/heads/main` |

A job with **no** `environment:` block cannot authenticate as a deployment
identity at all. That is deliberate.

---

## Terraform

### Filesystem or directory creation fails

```
Error: creating File System "raw": context deadline exceeded
```

`azurerm_storage_data_lake_gen2_filesystem` is a **data-plane** resource. It
needs private endpoint + DNS from wherever Terraform runs. Run the apply from
the runner, or from a host in the peered VNet.

To plan (not apply) from outside, set `create_data_lake_directories = false` —
though the filesystems themselves still need data-plane access.

### Managed private endpoint creation hangs

`azurerm_synapse_managed_private_endpoint` calls the Synapse **Dev** API
(`<ws>.dev.azuresynapse.net`), which is private. The dependency chain is
workspace → Dev private endpoint → DNS zone group → managed endpoints, and it is
encoded with `depends_on`. It still requires the apply to run from the VNet.

### Synapse cannot read the lake, and the endpoints look fine

Check the **approval** state on the target. A managed private endpoint is half a
connection.

```bash
az network private-endpoint-connection list --id "$(terraform -chdir=infra/terraform output -raw storage_account_id 2>/dev/null || echo '')" \
  --query "[].{name:name, state:properties.privateLinkServiceConnectionState.status}" -o table
```

`Pending` means nobody approved it. Terraform normally does this via
`scripts/Approve-PrivateEndpointConnections.ps1`; if
`auto_approve_managed_private_endpoints = false`, approve manually:

```bash
az network private-endpoint-connection approve --id <connection-id> --description "Approved"
```

### `Error acquiring the state lock`

**Check nothing is actually running** — the Actions tab, and the Activity Log —
before breaking it. Breaking a live lock is how two applies race.

```bash
terraform force-unlock <lock-id>
```

### `A resource with the ID ... already exists`

Terraform created it, then lost track. Import rather than delete:

```bash
terraform import 'module.storage.azurerm_storage_account.this' \
  "/subscriptions/.../storageAccounts/stedwtaxideva7k2"
```

### Plan shows a replacement you did not ask for

```
# module.synapse.azurerm_synapse_workspace.this must be replaced
```

Something create-time-only changed. Usually
`data_exfiltration_protection_enabled` or `managed_virtual_network_enabled`.
**Replacing a Synapse workspace destroys every serverless database, view and
external table.**

```bash
terraform plan -var-file=envs/prod/prod.tfvars | grep -B10 'forces replacement'
```

Revert the tfvars change. If it is genuinely required, plan the rebuild: export
the serverless DDL (it is all in `src/synapse/serverless/`, so it is already
version-controlled), replace, redeploy.

---

## Synapse

### CETAS cannot overwrite {#cetas-cannot-overwrite}

```
Cannot create external table. External table location already exists.
```

`DROP EXTERNAL TABLE` removes metadata only. The Parquet files remain, and
serverless has no `DELETE`.

`PL_Curate_NycTaxi_Yellow` purges the folder with a `Delete` activity before
calling the procedure. If you are running the procedure by hand:

```bash
az storage fs directory delete -f curated --account-name "$STORAGE" \
  -n "nyctlc/yellow_trip/PickupYear=2024/PickupMonth=1" --auth-mode login -y
```

The procedure catches this and re-raises it with instructions, because the
native error names neither the folder nor the fix.

### `Cannot drop the external data source ... it is used by external table` {#external-data-source-in-use}

Expected when the lake location has changed. Drop the dependents first:

```sql
SELECT 'DROP EXTERNAL TABLE ' + QUOTENAME(SCHEMA_NAME(schema_id)) + '.' + QUOTENAME(name) + ';'
FROM sys.external_tables;
```

Run the generated statements, then re-run `030_external_data_sources.sql`. No
data is lost — external tables are metadata.

### Every `OPENROWSET` fails despite `SELECT` being granted

Missing `ADMINISTER DATABASE BULK OPERATIONS`. Serverless-specific, and the one
permission nobody guesses.

```sql
GRANT ADMINISTER DATABASE BULK OPERATIONS TO [principal];
```

### String comparisons behave unexpectedly

The database is `Latin1_General_100_BIN2_UTF8` — **case-sensitive**, by design
(see [07-synapse](07-synapse.md#collation)). `'Manhattan'` does not
equal `'MANHATTAN'`.

For a specific comparison:

```sql
WHERE Borough COLLATE Latin1_General_100_CI_AS = 'manhattan'
```

### `azure.synapse.tools` hangs

The Dev endpoint is private. Check
`privatelink.dev.azuresynapse.net` — it is a **separate zone** from
`privatelink.sql.azuresynapse.net`, and having one and not the other is a common
half-configured state.

```bash
./scripts/Test-PlatformConnectivity.ps1 -Environment dev
```

---

## Data Factory

### Config CSV row has no effect

`path` is relative to the artifact's **`properties`** node:

```
# correct
linkedService,LS_ADLS_Lake,typeProperties.url,https://...

# wrong — silently does nothing by default
linkedService,LS_ADLS_Lake,properties.typeProperties.url,https://...
```

`Deploy-DataFactory.ps1` sets `FailsWhenConfigItemNotFound` and
`FailsWhenPathNotFound` to `$true` so this fails loudly. If you are calling the
module directly, set them.

### `Cannot modify a pipeline referenced by an active trigger`

Triggers must be stopped before publishing. `stopStartTriggers: true` handles it;
if you disabled it, re-enable it.

### Triggers left stopped after a deployment

An interrupted deployment can leave production triggers stopped — a silent
outage, because nothing fails, the load just never happens. `adf-cd.yml` asserts
trigger state after the prod deployment for exactly this reason.

```bash
az datafactory trigger list -g "$RG" --factory-name "$ADF" \
  --query "[].{name:name, state:properties.runtimeState}" -o table

az datafactory trigger start -g "$RG" --factory-name "$ADF" --name TR_Monthly_NycTaxi_Load
```

### Copy succeeds with zero rows

The merge's empty-staging guard fires:

```
stg.YellowTaxiTrip is empty. Refusing to replace fact partition 2024-3 with nothing.
```

**The guard is correct. Do not bypass it.** Find out why the curated partition
is empty:

```sql
SELECT COUNT_BIG(*) FROM curated.vw_YellowTaxiTrip
WHERE PickupYear = 2024 AND PickupMonth = 3;

SELECT RejectReason, COUNT_BIG(*) FROM curated.vw_YellowTaxiTrip_Rejected
WHERE PickupYear = 2024 AND PickupMonth = 3
GROUP BY RejectReason;
```

### Managed VNet activity is slow to start

60–90 seconds of cold start on the first activity is normal. `time_to_live_min`
keeps the compute warm between activities — 10 in dev, 30 in prod. You pay for
the TTL window, so do not raise it in dev.

---

## Azure SQL

### Deployment blocked by possible data loss

```
Rows were detected. The schema update is terminating because data loss might occur.
```

Working as intended in test and prod. Do a three-deployment migration rather
than flipping the flag:
[08-azure-sql](08-azure-sql.md#making-a-schema-change-that-loses-no-data).

### Deployment blocked by drift

```
The schema drift has been detected. Deployment has been terminated.
```

Somebody changed the database outside the pipeline. Deploying over it would
silently revert their change — often a fix currently holding production
together.

The `deployment-plan-<env>` artifact from `sql-cd.yml` shows exactly what
differs. Then adopt it into the project, or revert it deliberately.

### `Could not allocate space for object`

Out of storage. See
[11-operations-runbook](11-operations-runbook.md#sql-storage).

### First query of the day takes 60 seconds

Serverless auto-pause resuming. Expected in dev and test. **Not** expected in
prod, which uses a provisioned SKU — if it happens there, check
`sql_sku_name` in `prod.tfvars` has not been changed to a `GP_S_*`.

---

## Workflows

### Job waits forever with "Waiting for a runner"

No runner matches the labels.

```bash
gh api repos/:owner/:repo/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```

Add `edw` to your runners, or set `RUNNER_LABELS`. Do **not** switch to
`ubuntu-latest` — the lint and build jobs will pass and every deployment job
will hang.

### Workflow authenticates but has no permissions

Check which identity it used. Pull requests deliberately get the **read-only**
CI identity; a `workflow_dispatch` without `environment:` gets nothing.

### `terraform output` returns nothing in a workflow

The backend was not initialised for that environment. Every job that reads
outputs runs `terraform init -reconfigure -backend-config=envs/<env>/backend.hcl`
first.

---

## Getting more detail

```bash
# Terraform
export TF_LOG=DEBUG TF_LOG_PATH=./terraform.log

# Azure CLI
az <command> --debug

# sqlpackage
sqlpackage /Action:Publish ... /Diagnostics:True /DiagnosticsFile:./sqlpackage.log

# The Azure-Player modules
$VerbosePreference = 'Continue'
./scripts/Deploy-DataFactory.ps1 -Environment dev -Verbose

# ADF activity errors, in full
az datafactory activity-run query-by-pipeline-run -g "$RG" --factory-name "$ADF" \
  --run-id <runId> \
  --last-updated-after  "$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --last-updated-before "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --query "value[?status=='Failed'].{activity:activityName, error:error.message}" -o json
```

---

Next: [13 — Cost](13-cost.md)
