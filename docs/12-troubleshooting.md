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

### `VnetAddressSpaceOverlapsWithAlreadyPeeredVnet` after a rebuild {#stale-peering}

```
Cannot create or update peering ... because address space of the first virtual
network overlaps with address space of virtual network .../vnet-edwtaxi-dev
already peered with the second.
```

...and the VNet it names does not exist:

```bash
az network vnet show -g <old-rg> -n vnet-edwtaxi-dev
# ResourceNotFound
```

The spoke VNet is gone but the RUNNER-SIDE half of the peering survived it, in
state `Disconnected`. **A disconnected peering still counts for the overlap
check**, so a rebuild using the same address space is refused.

This happens whenever the spoke resource group is deleted outside Terraform -
`az group delete`, or a portal deletion. Terraform created both halves of the
peering, but only the spoke half lived in that resource group; the half in the
runner's resource group is orphaned with nothing left to clean it up.

Find and remove it:

```bash
az network vnet peering list -g <runner-rg> --vnet-name <runner-vnet> \
  --query "[].{name:name, state:peeringState}" -o table

az network vnet peering delete -g <runner-rg> --vnet-name <runner-vnet> -n <name>
```

The failure cascades and the peering error is easy to miss among the noise.
Without a peering there is no route, so every data-plane resource fails at
once - filesystems time out against the private endpoint IP, and Key Vault
reports "Public network access is disabled and request is not from a trusted
service nor via an approved private link". Those look like separate faults and
are one.

**Prefer `terraform destroy` to `az group delete`** for exactly this reason: it
removes both halves of the peering. Reach for the group delete only when a
destroy is stuck, and clean up the runner-side peering by hand afterwards.

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

### Private DNS zone will not delete: `CannotDeleteResource` {#dns-zone-wont-delete}

```
Error: deleting Private Dns Zone (... privatelink.sql.azuresynapse.net):
409 Conflict: CannotDeleteResource: Cannot delete resource while nested
resources exist. Some existing nested resource IDs include:
'.../virtualNetworkLinks/link-runner'
```

Check whether that link actually exists:

```bash
az network private-dns link vnet show -g <rg> -z <zone> -n link-runner
```

If it returns **`NotFound`** while the zone delete keeps naming it, this is an
Azure resource-provider inconsistency, not your configuration. The link is gone
from the data path but the zone's internal nested-resource index has not caught
up. It can persist for tens of minutes, and retrying `terraform destroy` in that
window fails identically.

Terraform ordering is not the problem: the link is destroyed before the zone
(the link references the zone name, so the dependency is real and honoured).
Adding sleeps to the destroy path does not reliably help either.

What works:

```bash
# ARM orchestrates the whole group through a different path
az group delete -n <rg> --yes --no-wait
```

Then reconcile Terraform, which will refresh, find nothing, and empty the
state:

```bash
terraform destroy -var-file=envs/<env>/<env>.tfvars
```

This platform creates NINE private DNS zones per environment, so a
tear-down-and-rebuild cycle in dev meets this more often than most. The residual
cost while you wait is trivial - a Private DNS zone with no links and no queries
is about USD 0.50/month - so it is usually right to issue the group delete and
move on rather than sit and watch it.

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

### Plan shows a replacement you did not ask for {#unwanted-replacement}

```
# module.synapse.azurerm_synapse_workspace.this must be replaced
```

**Replacing a Synapse workspace destroys every serverless database, view and
external table.** Never let this one through on autopilot.

Find the actual attribute before theorising. The reason is always printed:

```bash
terraform plan -var-file=envs/dev/dev.tfvars -no-color \
  | grep -B2 'forces replacement'
```

If a tfvars change caused it — `managed_virtual_network_enabled`,
`data_exfiltration_protection_enabled` — revert it, or plan the rebuild
deliberately: the serverless DDL is all in `src/synapse/serverless/`, so it is
already version-controlled.

#### When nobody changed anything {#forcenew-null-drift}

This platform hit a nastier version, and it is worth understanding because it
is not specific to Synapse.

```
- sql_administrator_login = "sqladminuser" -> null # forces replacement
```

Nobody set `sqladminuser`. **Azure did.** The module runs Entra-only auth and
deliberately passes no SQL administrator, because there is no password anywhere
in this platform. But the API has no way to store "none" — it backfills a
default. So state held `sqladminuser`, configuration held `null`, and the
attribute is ForceNew.

The result: **every apply destroyed and recreated the workspace**, taking its
managed private endpoints, diagnostic settings, role assignments and every ADF
endpoint pointing at it along with it. On a configuration nobody had touched.
It read as flaky networking for most of a day — the managed private endpoints
really were failing, because they were being created against a workspace
Terraform was concurrently replacing.

The fix is `ignore_changes`, in `modules/synapse/main.tf`:

```hcl
lifecycle {
  ignore_changes = [sql_administrator_login]
}
```

Safe because `azuread_authentication_only = true` refuses SQL authentication
outright — whatever Azure recorded in that field can never be used to connect.

**The general rule.** When a resource is ForceNew on an attribute you leave
null, check whether the provider marks it `Computed`:

```bash
terraform providers schema -json \
  | jq '.provider_schemas[].resource_schemas.azurerm_mssql_server
        .block.attributes.administrator_login'
```

- `computed: true` — null means *"keep whatever Azure set"*. No diff. Safe.
- `computed: false` — null means *"set this to nothing"*. Diffs against the
  backfilled value, and if ForceNew, replaces the resource on every apply.

That single flag is the entire difference between `azurerm_mssql_server`
(Computed — safe, needs no lifecycle block) and `azurerm_synapse_workspace`
(not Computed — replaced every time). Both are ForceNew; both get backfilled;
the SQL server currently reports an administrator called `CloudSA05a7428b` that
nobody chose. See the note in `modules/sql/main.tf` before making the two
resources "consistent" — they look identical and they are not.

**Why plan alone did not save us.** The plan said exactly what it was going to
do, every time. It was read as noise because the surrounding runs were failing
on network errors. Read the destroy list before approving an apply, especially
in an environment you believe is only being patched:

```bash
grep -E 'must be replaced|will be destroyed|^Plan:' plan.txt
```

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

### Synapse workspace ends in `Failed`, apply reports a cancelled context {#synapse-create-timeout}

```
Error: waiting for creation of Workspace: Future#WaitForCompletion:
context has been cancelled: StatusCode=200 -- Original Error: context deadline exceeded
```

Read `StatusCode=200`. **Azure was still working and perfectly happy.** The
cancellation is Terraform's own deadline - the provider default for creating a
Synapse workspace is 30 minutes, and a managed-VNet workspace in a cold region
routinely exceeds it.

What makes this expensive to diagnose is the aftermath. Terraform abandons the
operation, the half-provisioned workspace settles into
`provisioningState = Failed`, and the next apply finds a Failed workspace. So
the symptom presents as a broken configuration rather than a timeout, and the
next error you get is the thoroughly uninformative

```
CreateWorkspaceError: An error has occured while creating the workspace.
Correlation Id: ...
```

which carries no detail at all, in the portal or the activity log.

`modules/synapse` now allows 90 minutes, and `_terraform-apply.yml` allows 150
for the job - the job timeout must exceed the longest resource timeout, or a
slow-but-succeeding apply gets cancelled instead, which is worse: Terraform
does not get to write state for what it created.

**A `Failed` workspace cannot be repaired.** Delete it and let Terraform
recreate:

```bash
az synapse workspace delete -n <workspace> -g <rg> --yes
```

Do not simply re-run the apply against it - Terraform will attempt an update,
which also fails, and you lose another 30 minutes.

### `Login failed for user '<token-identified principal>'` deploying serverless SQL {#serverless-login-failed}

```
==> Acquiring an Entra access token for the SQL data plane.
    Token acquired.
==> 010_database.sql  ->  [master]
    XX 010_database.sql FAILED
       Login failed for user '<token-identified principal>'.
```

The token is valid — it was issued, and ARM calls in the same job succeed. The
workspace simply cannot tell that the principal presenting it is an
administrator.

The workspace's SQL administrator is an Entra **group**, and the deployment
identity is a service principal inside that group. Resolving "is this service
principal a member of that group" requires the workspace's own managed identity
to read the directory — the **Directory Readers** role. A human in the same
group authenticates without it, which is what makes this look like an
SP-specific permissions bug rather than a missing tenant role.

Check, and grant:

```bash
MI=$(az synapse workspace show -n <workspace> -g <rg> --query identity.principalId -o tsv)

# Empty output = the workspace cannot read the directory. This is the fault.
az rest --method get \
  --url "https://graph.microsoft.com/v1.0/servicePrincipals/$MI/memberOf" \
  --query "value[].displayName" -o tsv

ROLE=$(az rest --method get \
  --url "https://graph.microsoft.com/v1.0/directoryRoles?\$filter=roleTemplateId eq '88d8e3e3-8f55-4a1e-953a-9b9898b8876b'" \
  --query "value[0].id" -o tsv)

az rest --method post \
  --url "https://graph.microsoft.com/v1.0/directoryRoles/$ROLE/members/\$ref" \
  --headers "Content-Type=application/json" \
  --body "{\"@odata.id\":\"https://graph.microsoft.com/v1.0/directoryObjects/$MI\"}"
```

Granting it needs **Privileged Role Administrator** or Global Administrator —
more than the subscription Owner rights the rest of this template asks for, and
it is a tenant-wide role, so it is not something bootstrap does for you. Allow a
few minutes for the grant to reach the SQL data plane before re-running.

Azure SQL needs the same grant for its own server identity before
`CREATE USER ... FROM EXTERNAL PROVIDER` can resolve a service principal — see
[ADF cannot log in to Azure SQL](#adf-cannot-log-in-to-azure-sql).

> **Do not diagnose this with `az ad group member list`.** It returns users and
> silently omits service principals, so an admin group that contains the deploy
> SP looks like it contains only humans — sending you to fix a membership that
> was never broken. Use the explicit check, which answers for any principal
> type:
>
> ```bash
> az ad group member check --group <group-object-id> --member-id <sp-object-id> --query value
> ```
>
> Note also that `az ad` commands run against the tenant of your **current**
> subscription. With a default subscription in another tenant, group lookups
> return "Resource ... does not exist", which reads like deletion rather than
> the wrong directory.

### `The SQL pool is warming up. Please try again.` {#serverless-warming-up}

```
==> 010_database.sql  ->  [master]
    XX 010_database.sql FAILED
       The SQL pool is warming up. Please try again.
```

Exactly what it says, and it is an instruction rather than a failure. Serverless
SQL has no always-on compute: the built-in pool resumes on demand, and the first
statement after an idle period is rejected while that happens. It clears within
a minute or two.

`Deploy-ServerlessSql.ps1` retries these — five attempts backing off
15/30/45/60/60s — and only these. The pattern is narrow on purpose:

| Message | Retried |
|---|---|
| `is warming up` | yes |
| `is not currently available` / `Please retry the connection` | yes |
| `transport-level error` | yes |
| `Login failed`, `Incorrect syntax`, storage RBAC errors | **no** — fail immediately |

A retry loop that swallowed real errors would turn a five-second syntax failure
into a five-minute one. Tune with `-WarmupRetryCount` if a cold pool in your
region takes longer.

This is also why a deployment can fail on a Monday morning and pass on a re-run
with no change: whether the pool was warm depended on whether anyone had queried
it recently.

### `ResourceNotDeletable` on `WorkspaceDefaultSqlServer` {#workspace-default-linked-services}

```
Removing object: [LinkedService].[syn-edwtaxi-dev-65ri-WorkspaceDefaultSqlServer]
     | The linked service syn-edwtaxi-dev-65ri-WorkspaceDefaultSqlServer is managed
     | by the workspace syn-edwtaxi-dev-65ri and cannot be deleted.
     | Status: 400 ErrorCode: ResourceNotDeletable
```

`deleteNotInSource: true` converges the workspace on the repository, and Azure
creates two linked services with every workspace that are not, and never will
be, in `src/synapse/workspace`:

| | |
|---|---|
| `<workspace>-WorkspaceDefaultSqlServer` | the built-in serverless endpoint |
| `<workspace>-WorkspaceDefaultStorage` | the workspace's primary ADLS filesystem |

Both are workspace-managed and the API refuses to delete them, so the publish
fails at the delete step — after the artifacts have already been deployed.

`publish-options.json` excludes `linkedService.*-WorkspaceDefault*`. A pattern
rather than two names because the names carry the workspace prefix, which
differs per environment. `DoNotDeleteExcludedObjects` defaults to true, so an
excluded object is skipped rather than attempted.

Do not fix this by turning off `deleteNotInSource` — that also stops artifacts
deleted in a PR from ever leaving the workspace.

### `IDX12741: JWT must have three segments` deploying a sqlscript {#idx12741}

```
Start deploying object: [sqlscript].[SQL_Explore_YellowTaxi] (0 dependency/ies)
WARNING: sqlscripts are being deployed by Rest-API regardless of PublishMethod.
Invoke-RestMethod: .../azure.synapse.tools/0.27.0/private/Deploy-SynapseObjectOnly.ps1:145
     | { "code": "AuthenticationFailed", "message": "Token Authentication failed -
     |   IDX12741: JWT must have three segments (JWS) or five segments (JWE)." }
```

Not a credential problem — a **marshalling** one, and only on Linux. The
module's `Get-RequestHeader` unwraps the SecureString that Az.Accounts 5.x
returns like this:

```powershell
$BSTR  = [Marshal]::SecureStringToBSTR($SynapseToken.Token)   # UTF-16 buffer
$token = [Marshal]::PtrToStringAuto($BSTR)                    # wrong on Unix
```

`PtrToStringAuto` is UTF-16 on Windows and UTF-8 everywhere else. Reading a
UTF-16 buffer as UTF-8 stops at the first NUL byte, so the token arrives as its
**first character**:

```
original        : [aaaa.bbbb.cccc] len=14
PtrToStringAuto : [a] len=1 segments=1        <- what gets sent
PtrToStringBSTR : [aaaa.bbbb.cccc] len=14 segments=3
```

One character is not a JWT, hence the error. A Windows runner never sees it.
The same function also picks its branch from
`(Get-Command Get-AzAccessToken).Version`, which resolves to the wrong module
when several Az.Accounts versions are installed — that route sends the literal
string `System.Security.SecureString` and fails identically.

`Deploy-Synapse.ps1` replaces the function in the module's own scope with a
version using `PtrToStringBSTR` and a type test. 0.27.0 is the newest release,
so there is nothing to upgrade to. The patch applies only while the installed
module still contains `PtrToStringAuto`, and the script says which path it
took:

```
Patched Get-RequestHeader (upstream PtrToStringAuto bug, see comment above).
Get-RequestHeader needs no patch in this version.
```

This affects every artifact the module sends over the Dev REST API —
sqlscripts, notebooks, kqlscripts, Spark job definitions, datasets — and
starting or stopping Synapse triggers. Linked services and pipelines go through
`Set-AzSynapse*` cmdlets, which handle their own auth, which is why they deploy
fine and the failure looks artifact-specific.

### `New-AzResource` fails with only a CorrelationId {#synapse-armresource-empty-error}

```
Start deploying object: [linkedService].[LS_ADLS_Lake] (1 dependency/ies)
New-AzResource: .../azure.synapse.tools/0.27.0/private/Deploy-SynapseObjectOnly.ps1:169
     | CorrelationId: 069f9a98-763e-4763-ae16-92cac9283c48
```

No message, because ARM returned none. The publish is going through the wrong
plane: `Publish-SynapseFromJson` defaults to `-Method 'AzResource'`, which
writes workspace artifacts through
`Microsoft.Synapse/workspaces/linkedservices` on the ARM control plane instead
of the workspace's own Dev endpoint. With public network access disabled on the
workspace, that route does not work, and the private link this platform builds
does not cover it.

`Deploy-Synapse.ps1` pins `-Method 'AzSynapse'`
([07-synapse](07-synapse.md#the-publish-method-is-azsynapse-not-the-module-default)).
If it is missing from `$publishParams`, this is what you get.

Do not confuse it with the identically-named cmdlet failing on Data Factory —
there, `New-AzResource` is the *correct* call and a missing **Az.Resources**
module is the cause ([above](#new-azresource-missing)).

### `ASWT0005: Referenced object [IntegrationRuntime].[AutoResolveIntegrationRuntime] was not found` {#aswt0005-autoresolve}

```
STEP: Deployment of all Synapse objects...
Start deploying object: [linkedService].[LS_ADLS_Lake] (1 dependency/ies)
     | ASWT0005: Referenced object
     | [IntegrationRuntime].[AutoResolveIntegrationRuntime] was not found.
```

The runtime exists in the workspace — Azure puts it there. The module resolves
`connectVia` against the **source folder**, so it needs a file. Restore
`src/synapse/workspace/integrationRuntime/AutoResolveIntegrationRuntime.json`;
it is a placeholder that `publish-options.json` excludes from every deployment.
The Data Factory equivalent is [`ADFT0005`](#new-azresource-missing)'s
neighbour, `integrationRuntime/IR-ManagedVNet.json`.

Two things in that log that are **not** problems:

- `# Number of objects marked as to be deployed: 1/3` followed by a single
  artifact. `ToBeDeployedStat` pipes through `Select-Object -Unique`, which
  compares objects by type name and collapses them. All three are deployed.
- `Getting triggers...` returning nothing. There are no Synapse triggers in
  this template; the ADF factory owns scheduling.

The failure lands after `STEP: Stopping triggers...`, so check trigger state
once the deployment succeeds.

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

### `InvalidAuthenticationToken` from `Get-AzDFV2Credential` {#invalid-auth-token}

```
Invoke-RestMethod: .../azure.datafactory.tools/<version>/private/Get-AzDFV2Credential.ps1:17
     | { "error": { "code": "InvalidAuthenticationToken",
     |              "message": "The access token is invalid." } }
```

The token is fine; the module is too old. Below **1.16.0**,
`Get-AzDFV2Credential` and `Remove-AdfObjectRestAPI` build the ARM
`Authorization` header by hand:

```powershell
$token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com'
'Bearer ' + $token.Token
```

Two things break that on a current runner:

- **Az.Accounts 5.0.0** changed `Get-AzAccessToken` to return `Token` as a
  `SecureString` by default. String-concatenating one yields the literal
  `Bearer System.Security.SecureString`.
- The hand-rolled path cannot use a **federated (OIDC) credential** at all —
  which is exactly how this template authenticates.

1.16.0 replaced both call sites with `Invoke-AzRestMethod`, which acquires and
attaches the token itself. Pin 1.16.0 or later; this repo pins 1.18.0. Note the
`Get-AzAccessToken` deprecation warnings you may have seen in earlier runs were
the same problem announcing itself.

### `The term 'New-AzResource' is not recognized` {#new-azresource-missing}

```
STEP: Deployment of all ADF objects...
Start deploying object: [linkedService].[LS_ADLS_Lake] (1 dependency/ies)
Deploy-AdfObjectOnly: .../azure.datafactory.tools/<version>/private/Deploy-AdfObject.ps1:43
     | The term 'New-AzResource' is not recognized as a name of a cmdlet ...
```

Nothing to do with Data Factory, and nothing to do with the network.
`New-AzResource` lives in **Az.Resources**, which is not installed. The module
publishes with `Method = 'AzResource'` by default, so every artifact goes
through that one cmdlet — and it declares no `RequiredModules`, so nothing
warns you at import time. `azure/login`'s `enable-AzPSSession` only guarantees
`Az.Accounts`.

The failure lands *after* `STEP: Stopping triggers...`, so the factory is left
with its triggers stopped. Check them once the deployment succeeds:

```bash
az datafactory trigger list -g <rg> --factory-name <adf> \
  --query "[].{name:name, state:properties.runtimeState}" -o table
```

```powershell
Install-Module Az.Resources -Scope CurrentUser -Force
```

The same cmdlet is on `azure.synapse.tools`' publish path, so a Synapse
deployment fails identically. Both `Deploy-DataFactory.ps1` and
`Deploy-Synapse.ps1` now install the module if it is absent, and the workflows
pre-install it; this entry is for when you are running from a jumpbox with an
older checkout.

### `apply` hangs forever creating a managed private endpoint {#mpe-create-hangs}

```
module.datafactory.azurerm_data_factory_managed_private_endpoint.this["synapse-dev"]: Still creating... [13m30s elapsed]
```

Check Azure before assuming the endpoint is missing — in the case that
produced this note it already existed and was perfectly healthy:

```bash
# NOTE the mpe- prefix. The Terraform key is "synapse-dev"; the ARM resource
# is "mpe-synapse-dev". Querying the key alone returns a misleading 404.
az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>\
/providers/Microsoft.DataFactory/factories/<adf>/managedVirtualNetworks/default\
/managedPrivateEndpoints/mpe-synapse-dev?api-version=2018-06-01"
```

`provisioningState: Succeeded`, `connectionState: Pending` means the endpoint
is fine and Terraform simply cannot see it. Now try the LIST call:

```bash
az datafactory managed-private-endpoint list \
  --factory-name <adf> -g <rg> --managed-virtual-network-name default
```

If that returns **HTTP 500**:

```
InternalError: Sequence contains no elements
  at System.Linq.Enumerable.First[TSource](IEnumerable`1 source)
  at ManagedPrivateEndpointController.CreateManagedPrivateEndpointResponse(...)
```

then the resource provider is throwing while projecting its own endpoints into
ARM responses. Endpoint **reads** go through GET and keep working; the
**create** path polls LIST, so it retries a permanent 500 until the job times
out. Existing endpoints are unaffected — only new ones hang.

**Repair, without destroying anything.** The endpoints already exist, so stop
trying to create them and adopt them instead:

```bash
terraform import \
  'module.datafactory.azurerm_data_factory_managed_private_endpoint.this["synapse-dev"]' \
  "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.DataFactory\
/factories/<adf>/managedVirtualNetworks/default/managedPrivateEndpoints/mpe-synapse-dev"
```

Import uses GET, so it succeeds even while LIST is broken. The next plan sees
the endpoints as present and never calls create.

If the endpoint genuinely does not exist, create it by hand — this also takes
the create path off Terraform's broken poll, and lands in ~45 seconds:

```bash
az rest --method put --url "<the URL above>" --headers "Content-Type=application/json" \
  --body '{"properties":{"privateLinkResourceId":"<synapse workspace id>","groupId":"Dev"}}'
```

Synapse group IDs are case-sensitive: `Dev`, `Sql`, `SqlOnDemand`, `Web`.

**Do not "fix" this by destroying the factory or the workspace.** Destroying a
target is what orphans these endpoints in the first place: the ADF managed VNet
keeps records pointing at a resource that no longer exists, and every
subsequent apply hangs on them. See
[#forcenew-null-drift](#forcenew-null-drift) for how that cycle started.

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
