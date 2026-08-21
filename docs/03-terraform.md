# 03 — Terraform

Layout, state, environment selection, and the two structural rules that are not
obvious from reading the files.

---

## Layout

```
bootstrap/                       local state, applied by a human, once
  main.tf                        state account, Entra apps, OIDC, admin groups

infra/terraform/                 ONE root module, THREE environments
  providers.tf                   provider config + partial backend
  main.tf                        composition: which modules, wired how
  rbac.tf                        ALL cross-service data-plane RBAC
  secrets.tf                     Key Vault contents
  variables.tf  outputs.tf

  envs/
    dev/  backend.hcl  dev.tfvars
    test/ backend.hcl  test.tfvars
    prod/ backend.hcl  prod.tfvars

  modules/
    network/       VNet, NSG, 9 private DNS zones, runner peering
    storage/       ADLS Gen2, filesystems, lifecycle, 2 private endpoints
    keyvault/      RBAC-authorised vault + private endpoint
    sql/           logical server, database, auditing, private endpoint
    synapse/       workspace, 3 private endpoints, managed private endpoints
    datafactory/   factory, managed VNet IR, managed private endpoints
    monitoring/    Log Analytics, action group, saved queries
    alerts/        5 alert rules
```

### No workspaces

Environment selection is entirely on the command line:

```bash
terraform init  -reconfigure -backend-config=envs/dev/backend.hcl
terraform plan  -var-file=envs/dev/dev.tfvars
```

`terraform workspace` was rejected deliberately. Workspaces share one backend
key and one provider configuration, and the current workspace is invisible
state on your machine. `terraform apply` after forgetting to switch is a
one-keystroke path to applying a dev change to prod. Separate state keys and
separate var files put the blast radius in the command itself, where a reviewer
watching over your shoulder can see it.

---

## Rule 1 — RBAC lives at the root, not in modules

Every cross-service role assignment is in
[`infra/terraform/rbac.tf`](../infra/terraform/rbac.tf), not inside the module
that owns the resource. This is not a style preference; it is forced.

Terraform resolves dependencies at **module** granularity. If
`modules/storage` took an `adf_principal_id` variable to grant blob access, then:

```
modules/storage    needs  modules/datafactory   (for the principal ID)
modules/datafactory needs modules/storage       (for the account ID)
```

— a cycle, and `terraform graph` says so in an error that does not obviously
name the cause. Hoisting the assignments to the root breaks it, and has the
side benefit of giving you one file to read when somebody asks "what can touch
the lake?".

The modules still expose a `data_plane_role_assignments` variable for
principals known ahead of time (an existing group, a user-assigned identity).
The root passes `{}`.

---

## Rule 2 — monitoring and alerts are separate modules

Same problem, same shape:

```
alerts   needs  datafactory, synapse, sql   (resource IDs to watch)
those    need   monitoring                  (workspace ID for diagnostics)
```

One `monitoring` module containing both the workspace and the alert rules would
be a cycle. Two modules is a straight line:

```
monitoring (workspace + action group)
   → network → storage → keyvault → sql → synapse → datafactory
       → alerts (rules pointing at all of the above)
```

---

## State

One storage account, one container, one blob key per environment:

```
stedwtaxitfstateab12/tfstate/
  dev.tfstate
  test.tfstate
  prod.tfstate
```

The account has `shared_access_key_enabled = false`. There is no account key to
leak, and no key path to fall back on — which is why every `backend.hcl` sets:

```hcl
use_azuread_auth = true    # required: there is no key
use_oidc         = true    # ignored harmlessly outside GitHub Actions
```

Versioning and 30-day soft delete are on. That turns a catastrophic
`terraform state rm` into a two-minute restore:

```bash
az storage blob list --account-name <acct> -c tfstate --include v \
  --query "[?name=='prod.tfstate'].{version:versionId, modified:properties.lastModified}" -o table

az storage blob copy start --account-name <acct> \
  --destination-container tfstate --destination-blob prod.tfstate \
  --source-uri "https://<acct>.blob.core.windows.net/tfstate/prod.tfstate?versionid=<version>" \
  --auth-mode login
```

### Locking

The azurerm backend uses a blob lease. If a run is killed mid-apply the lease
survives:

```
Error: Error acquiring the state lock
Lock Info:
  ID:        6f2a...
  Operation: OperationTypeApply
  Created:   2026-08-21 03:14:22 UTC
```

Before breaking it, **check nothing is actually running** — the Actions tab,
and the Azure Activity Log for the resource group. Then:

```bash
terraform force-unlock 6f2a-...
```

Breaking a live lock is how two applies race and corrupt state.

---

## Naming

```hcl
name_prefix          = "${project}-${environment}"                     # edwtaxi-dev
resource_group_name  = "rg-${project}-${environment}-${location_short}" # rg-edwtaxi-dev-eus2
storage_account_name = substr("st${project}${environment}${suffix}", 0, 24)
key_vault_name       = substr("kv-${project}-${environment}-${suffix}", 0, 24)
synapse_name         = "syn-${project}-${environment}-${suffix}"
sql_server_name      = "sql-${project}-${environment}-${suffix}"
data_factory_name    = "adf-${project}-${environment}-${suffix}"
```

`project` is validated at 3–8 lowercase alphanumerics because it is
concatenated into storage account names, which Azure caps at 24.

`suffix` is a four-character random string held in state. Globally-unique names
need it. Two consequences:

- **Record it.** `terraform output name_suffix`. If you lose state, you need it
  to import rather than re-create.
- **Pin it if you prefer.** Set `name_suffix = "a7k2"` in tfvars and the random
  resource is not created at all.

Two naming quirks Azure imposes, both handled in `main.tf`:

- Synapse workspace names may not contain `-ondemand` (Azure reserves
  `<ws>-ondemand` for the serverless endpoint). There is a validation rule.
- Synapse **Private Link Hub** names are alphanumeric only — no hyphens, unlike
  every other Synapse name. Hence a separate `private_link_hub_name` local.

---

## Data-plane resources

Three resource types in this configuration call a **data plane**, not ARM:

| Resource | API | Consequence |
|---|---|---|
| `azurerm_storage_data_lake_gen2_filesystem` | dfs | needs private endpoint + DNS |
| `azurerm_storage_data_lake_gen2_path` | dfs | same |
| `azurerm_key_vault_secret` | vault | needs private endpoint + DNS |
| `azurerm_synapse_managed_private_endpoint` | `<ws>.dev.azuresynapse.net` | needs the Dev private endpoint to exist first |

This is why `terraform apply` must run from inside the runner's VNet, and why
the modules carry explicit `depends_on` forcing the private endpoints to be
created first. From outside, they fail with a timeout or a 403 that mentions
neither DNS nor networking.

If you must plan from a laptop, set `create_data_lake_directories = false` — it
removes the `azurerm_storage_data_lake_gen2_path` resources, though the
filesystems themselves still need data-plane access.

---

## RBAC propagation

Entra role assignments take up to a couple of minutes to reach a data plane.
Terraform creates the assignment and immediately tries to use it, and the first
apply fails with:

```
Caller is not authorized to perform action on resource
```

Two `time_sleep` resources exist for exactly this:

- `bootstrap/main.tf` → `wait_for_sp_replication` (45s, after creating SPs)
- `infra/terraform/secrets.tf` → `wait_for_keyvault_rbac` (60s, after granting
  Key Vault Secrets Officer)

They look like a hack and are the documented mitigation. Removing them makes
the first apply of a new environment fail roughly half the time.

---

## Managed private endpoint approval

A managed private endpoint is half a connection. The source side appears
immediately; the **target** receives a request in state `Pending`, and until
someone approves it, traffic does not flow — silently.

When Terraform owns both sides there is nobody to ask, so a `null_resource`
provisioner runs
[`scripts/Approve-PrivateEndpointConnections.ps1`](../scripts/Approve-PrivateEndpointConnections.ps1)
after creating them. It polls (the request takes 30–60 seconds to appear),
filters by the factory or workspace name so it cannot approve a stray request
from something else, and exits 0 when nothing is pending — which is the normal
case on re-apply.

To hand approvals to a security team, set:

```hcl
auto_approve_managed_private_endpoints = false
```

and expect the platform to be non-functional until they act. Check state with:

```bash
az network private-endpoint-connection list --id <storage-account-id> \
  --query "[].{name:name, state:properties.privateLinkServiceConnectionState.status}" -o table
```

---

## Things that force a replace

Changing any of these destroys and re-creates the resource, taking its contents
with it. Each is called out in the module, and repeated here because the cost
is high.

| Setting | Resource | What is lost |
|---|---|---|
| `is_hns_enabled` | storage account | **the entire lake** |
| `data_exfiltration_protection_enabled` | Synapse workspace | every serverless database, view, external table |
| `managed_virtual_network_enabled` | Synapse / ADF | the workspace or factory |
| `storage_data_lake_gen2_filesystem_id` | Synapse workspace | the workspace |
| `collation` | Azure SQL database | the database |

`prod.tfvars` deliberately avoids touching these. Before any `terraform apply`
in prod, read the plan for `# forces replacement`:

```bash
terraform plan -var-file=envs/prod/prod.tfvars | grep -B5 'forces replacement'
```

The `_terraform-apply.yml` workflow publishes the plan as an artefact and as a
job summary, so the reviewer on the prod approval gate can do this without
running anything.

---

## Adding a module

1. Create `modules/<name>/{main,variables,outputs}.tf`.
2. Add the block to `infra/terraform/main.tf`.
3. Put any cross-service role assignment in `rbac.tf`, **not** in the module.
4. Add per-environment knobs to `variables.tf` and all three tfvars files.
5. `terraform fmt -recursive` — CI fails on unformatted files.
6. `terraform validate` — the PR workflow validates the root, `bootstrap/`, and
   every module independently.

---

Next: [04 — Networking](04-networking.md)
