# 05 — Runner connectivity

You already run self-hosted GitHub Actions runners in a VNet. This page is about
making them work with a platform whose entire data plane is private.

It is the most important page in this repository. Almost every confusing failure
downstream is one of the three things below.

---

## What has to be true

```
   ┌──────────────────────────────┐            ┌──────────────────────────────┐
   │  Your runner VNet            │            │  vnet-edwtaxi-<env>          │
   │  vnet-github-runners         │            │  snet-private-endpoints      │
   │                              │            │                              │
   │   [runner]                   │◀── (1) ───▶│   pe-storage  pe-sql         │
   │      │                       │  peering   │   pe-synapse  pe-adf         │
   │      │ (2) DNS               │            │   pe-keyvault                │
   │      ▼                       │            └──────────────────────────────┘
   │   privatelink.* zones ───────┼─── (2) linked to THIS VNet
   │                              │
   │   (3) OIDC token ────────────┼──▶ Entra ──▶ deployment service principal
   └──────────────────────────────┘
```

1. **Reachability** — VNet peering, in *both* directions.
2. **Name resolution** — the nine `privatelink.*` zones linked to the runner's
   VNet (or forwarded there by your own DNS).
3. **Identity** — the OIDC federated service principal from `bootstrap/`.

Get (1) and (3) right and forget (2), and every deployment hangs for minutes and
then fails with an error blaming SQL, or Synapse, or "a network-related or
instance-specific error" — none of which mention DNS.

---

## This deployment, concretely

The template is already wired to the runner VNet in this subscription. Recorded
here so the numbers are somewhere other than a tfvars comment.

| | |
|---|---|
| Runner VNet | `vnet-eastus-1` |
| Resource group | `rg-github-runner-eus` |
| Subscription | `424d0f78-5980-4d31-98ec-624616db8e74` (Contoso Ltd) |
| Region | **`eastus`** |
| Address space | `172.16.0.0/16` |
| Runner subnet | `snet-eastus-1` — `172.16.0.0/24`, NAT gateway `ng-github-runner-vnet` |
| Also present | `AzureBastionSubnet` — `172.16.1.0/26` |
| Custom DNS | none → Azure-provided DNS |
| NAT egress IP | `48.195.137.225` |

EDW address spaces, chosen not to overlap `172.16.0.0/16`:

| Environment | VNet | Private endpoint subnet |
|---|---|---|
| dev | `10.60.0.0/24` | `10.60.0.0/26` |
| test | `10.61.0.0/24` | `10.61.0.0/26` |
| prod | `10.62.0.0/24` | `10.62.0.0/26` |

### Three consequences worth knowing

**1. All three environments are in `eastus`, not `eastus2`.** Global VNet
peering across regions works, but every packet between the runner and a private
endpoint would be billed as cross-region egress and carry roughly 15 ms extra
latency. On a `sqlpackage` publish — thousands of round trips — that is minutes.
Same-region peering is free and faster.

**2. No second Bastion.** The runner VNet already has an `AzureBastionSubnet`.
If a **Standard**-sku Bastion is deployed there it reaches VMs in the peered EDW
VNets, so `deploy_bastion = false` everywhere, saving ~$140/month in prod. Basic
sku cannot do cross-VNet — set it true in `prod.tfvars` if that is what you have.

**3. Two `privatelink` zones already exist in this subscription**, linked to
other VNets:

| Zone | Resource group | Linked to |
|---|---|---|
| `privatelink.database.windows.net` | `Infrastructure` | `Infrastructure-vnet` |
| `privatelink.vaultcore.azure.net` | `rg-github-runner` | `gh-runner-01VNET` |

That is not a conflict today — a zone name may exist in several resource groups,
and `vnet-eastus-1` is linked to neither. Terraform creates its own copies in the
EDW resource groups and links those.

**It becomes a conflict if somebody links `vnet-eastus-1` to one of the existing
copies.** A VNet can be linked to only one zone of a given name; that link would
win, and this platform's SQL server would stop resolving privately — silently,
with connections timing out rather than failing. If you would rather reuse the
existing zones, set `create_private_dns_zones = false` and supply
`existing_private_dns_zone_ids` for all nine
([04-networking](04-networking.md#central-dns)).

---

## Configuration

In each `infra/terraform/envs/<env>/<env>.tfvars`:

```hcl
runner_vnet_id = "/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-github-runner-eus/providers/Microsoft.Network/virtualNetworks/vnet-eastus-1"

peer_runner_vnet                = true   # create BOTH peering directions
link_private_dns_to_runner_vnet = true   # link all nine zones to that VNet
```

Find the ID for a different VNet:

```bash
az network vnet list --query "[].{name:name, rg:resourceGroup, location:location, id:id}" -o table
```

### Permissions Terraform needs on your runner VNet

Peering is not one-sided: creating A→B without B→A leaves the peering in state
`Initiated` and no traffic flows. Terraform creates both, which means the
deployment service principal needs write access on the runner VNet too:

```bash
RUNNER_VNET="/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-github-runner-eus/providers/Microsoft.Network/virtualNetworks/vnet-eastus-1"

for env in dev test prod; do
  SP=$(az ad sp list --display-name "sp-edwtaxi-github-deploy-$env" --query "[0].id" -o tsv)
  az role assignment create \
    --assignee-object-id "$SP" --assignee-principal-type ServicePrincipal \
    --role "Network Contributor" \
    --scope "$RUNNER_VNET"
done
```

Run this **after** `bootstrap/` has created the service principals and **before**
the first `terraform apply`, or the apply fails partway through with
`AuthorizationFailed` on `Microsoft.Network/virtualNetworks/peer/action` —
having already created the EDW VNet and half its private endpoints.

If you would rather not grant it at all, set `peer_runner_vnet = false` and
create both peerings by hand:

```bash
EDW_VNET="/subscriptions/424d0f78-5980-4d31-98ec-624616db8e74/resourceGroups/rg-edwtaxi-dev-eus/providers/Microsoft.Network/virtualNetworks/vnet-edwtaxi-dev"

az network vnet peering create -g rg-edwtaxi-dev-eus --vnet-name vnet-edwtaxi-dev \
  -n peer-to-runners --remote-vnet "$RUNNER_VNET" \
  --allow-vnet-access --allow-forwarded-traffic

az network vnet peering create -g rg-github-runner-eus --vnet-name vnet-eastus-1 \
  -n peer-to-edwtaxi-dev --remote-vnet "$EDW_VNET" \
  --allow-vnet-access --allow-forwarded-traffic
```

Both must end up `Connected`. A single direction sits in `Initiated` and carries
no traffic.

If the runner VNet belongs to a network team who will not grant that, set
`peer_runner_vnet = false` and have them create the peering. Terraform then
assumes connectivity exists and `terraform output runner_peering_enabled`
returns `false` as a reminder that you are responsible for it.

### Address space must not overlap

```bash
az network vnet show --ids "$RUNNER_VNET" --query addressSpace.addressPrefixes -o tsv
```

Defaults: `10.60.0.0/24` (dev), `10.61.0.0/24` (test), `10.62.0.0/24` (prod).
Overlap makes peering impossible; change `vnet_address_space` and
`subnet_private_endpoints_prefix` if it collides.

---

## Custom DNS

If your runner VNet specifies custom DNS servers, linking a Private DNS zone to
it does nothing — the VMs ask your servers, not Azure DNS.

```bash
az network vnet show --ids "$RUNNER_VNET" --query dhcpOptions.dnsServers -o tsv
```

**Empty** → Azure-provided DNS. Leave `link_private_dns_to_runner_vnet = true`
and you are done.

**Not empty** → set `link_private_dns_to_runner_vnet = false` and pick one:

### Option A — conditional forwarders on your DNS servers

Forward these nine zones to `168.63.129.16` (Azure's platform DNS, reachable
from inside any VNet):

```
privatelink.dfs.core.windows.net
privatelink.blob.core.windows.net
privatelink.vaultcore.azure.net
privatelink.database.windows.net
privatelink.sql.azuresynapse.net
privatelink.dev.azuresynapse.net
privatelink.azuresynapse.net
privatelink.datafactory.azure.net
privatelink.adf.azure.com
```

Windows Server DNS example:

```powershell
$zones = @(
  'privatelink.dfs.core.windows.net'
  'privatelink.blob.core.windows.net'
  'privatelink.vaultcore.azure.net'
  'privatelink.database.windows.net'
  'privatelink.sql.azuresynapse.net'
  'privatelink.dev.azuresynapse.net'
  'privatelink.azuresynapse.net'
  'privatelink.datafactory.azure.net'
  'privatelink.adf.azure.com'
)
foreach ($z in $zones) {
  Add-DnsServerConditionalForwarderZone -Name $z -MasterServers 168.63.129.16
}
```

The forwarder must run **inside** an Azure VNet — 168.63.129.16 is not routable
from on-premises. If your DNS servers are on-premises, use Option B.

### Option B — Azure DNS Private Resolver

The managed answer, and the right one for a hub-and-spoke estate. Deploy a
resolver in the hub, link the privatelink zones to the **resolver's** VNet, and
point on-premises DNS at the resolver's inbound endpoint.

```hcl
# Then, in each tfvars:
link_private_dns_to_runner_vnet = false
additional_dns_link_vnet_ids    = ["/subscriptions/.../virtualNetworks/vnet-hub-dns"]
```

`additional_dns_link_vnet_ids` links the zones to the resolver's VNet without
creating peering — exactly what this case needs.

---

## Runner requirements

### Software

```bash
for t in az terraform pwsh dotnet git; do
  printf '%-10s ' "$t"; command -v $t >/dev/null && echo present || echo MISSING
done
pwsh -c '$PSVersionTable.PSVersion'    # must be 7.x
```

**The .NET SDK must already be installed — the workflows do not install it.**

`actions/setup-dotnet` is deliberately not used. It does not detect an SDK
installed by the distribution: on Ubuntu, apt installs to `/usr/lib/dotnet`
with a symlink at `/usr/bin/dotnet`, while setup-dotnet hardcodes
`/usr/share/dotnet` and tries to create it as the runner user:

```
mkdir: cannot create directory '/usr/share/dotnet': Permission denied
Error: Failed to install dotnet, exit code: 1
```

Do **not** fix that by chowning `/usr/share/dotnet` — apt owns the .NET tree and
root should keep it, and you would end up with two SDKs and a PATH-order
question. `sql-cd.yml` instead asserts the installed version and fails with a
clear message if it is missing or too old. The reasoning is written out in full
at the top of the `build` job there.

```bash
sudo apt-get install -y dotnet-sdk-8.0
dotnet --list-sdks        # expect 8.0.x or later
```

If you ran `sudo mkdir -p /usr/share/dotnet` while debugging this, remove the
empty directory (`sudo rmdir /usr/share/dotnet`) — leaving it behind changes how
`install-dotnet.sh` behaves if anyone reinstates the action.

**Az PowerShell modules are needed by two workflows.**

`azure/login`'s `enable-AzPSSession: true` imports `Az.Accounts` to call
`Connect-AzAccount`, and it must already be installed. GitHub-hosted runners
ship the Az modules; a self-hosted Ubuntu runner does not, and the action fails
with an error that names neither PowerShell nor the missing module:

```
Running Azure PowerShell Login.
{ Success: false, Error: "Cannot bind argument to parameter 'Name' because it is null." }
```

Only `adf-cd` and `synapse-cd` need it — `azure.datafactory.tools` and
`azure.synapse.tools` are built on the Az cmdlets. Every other workflow uses the
`az` CLI, which `azure/login` authenticates without any PowerShell session, so
they deliberately do **not** set the flag. Requesting a session you never use
turns a missing module into a failed deployment.

Those two workflows install the modules on demand. Pre-installing skips ~60s per
run:

```bash
pwsh -c "Install-Module Az.Accounts, Az.DataFactory, Az.Synapse -Scope AllUsers -Force"
```

The workflows *do* install `sqlpackage`, `SqlServer`, `azure.datafactory.tools`
and `azure.synapse.tools` on demand, into writable per-user locations
(`~/.dotnet/tools` and the PowerShell `CurrentUser` scope). Pre-installing those
saves two to three minutes per run:

```bash
dotnet tool install --global microsoft.sqlpackage
pwsh -c "Install-Module SqlServer -MinimumVersion 22.0.0 -Scope AllUsers -Force"
pwsh -c "Install-Module azure.datafactory.tools -RequiredVersion 1.11.0 -Scope AllUsers -Force"
pwsh -c "Install-Module azure.synapse.tools     -RequiredVersion 1.6.0  -Scope AllUsers -Force"
```

### Outbound internet

The runner still needs the public internet — for GitHub itself, for Entra, and
for package feeds. Required destinations:

| Destination | For |
|---|---|
| `github.com`, `api.github.com`, `*.actions.githubusercontent.com` | the runner agent, job dispatch, OIDC token |
| `login.microsoftonline.com`, `management.azure.com` | Entra, ARM |
| `graph.microsoft.com` | `CREATE USER ... FROM EXTERNAL PROVIDER` |
| `www.powershellgallery.com`, `psg-prod-eastus.azureedge.net` | PowerShell modules |
| `api.nuget.org`, `*.nuget.org` | `dotnet build`, `sqlpackage` |
| `releases.hashicorp.com` | `setup-terraform` |
| `d37ci6vzurychx.cloudfront.net` | the TLC taxi zone lookup |

A NAT gateway is the simple answer and gives a stable egress IP — useful for
locking down the Terraform state account:

```bash
az network nat gateway show -g <rg> -n <natgw> --query publicIpAddresses
```

Then in `bootstrap/terraform.tfvars`:

```hcl
state_storage_allowed_ips = ["203.0.113.10"]
```

### Labels

```yaml
runs-on: ${{ fromJSON(vars.RUNNER_LABELS || '["self-hosted","linux","X64","edw"]') }}
```

Add `edw` to your runners, or:

```bash
gh variable set RUNNER_LABELS --body '["self-hosted","linux","X64","data-platform"]'
```

### Sizing

Modest. Two runners is enough for a team.

| | Recommended |
|---|---|
| vCPU / RAM | 2 / 8 GB |
| Disk | 64 GB (Terraform providers ~500 MB, .NET SDK ~1 GB) |
| Concurrency | 2 runners — the `concurrency:` groups serialise the deployments anyway |

The workflows are I/O-bound waiting on Azure, not CPU-bound.

---

## Verifying

```bash
./scripts/Test-PlatformConnectivity.ps1 -Environment dev
```

Healthy output:

```
==============================================================================
 Data plane reachability
==============================================================================

  Azure SQL (TDS)  (sql-edwtaxi-dev-a7k2.database.windows.net : 1433)
  [PASS] DNS -> 10.60.0.7 (private)
  [PASS] TCP 1433 open

  Synapse serverless SQL (TDS)  (syn-edwtaxi-dev-a7k2-ondemand.sql.azuresynapse.net : 1433)
  [PASS] DNS -> 10.60.0.9 (private)
  [PASS] TCP 1433 open

  Synapse Dev API (azure.synapse.tools)  (syn-edwtaxi-dev-a7k2.dev.azuresynapse.net : 443)
  [PASS] DNS -> 10.60.0.10 (private)
  [PASS] TCP 443 open
  ...
  All checks passed (0 warning(s)).
```

Broken:

```
  Azure SQL (TDS)  (sql-edwtaxi-dev-a7k2.database.windows.net : 1433)
  [FAIL] DNS -> 20.42.65.90 (PUBLIC)
         This host is resolving the PUBLIC endpoint. Every connection will hang
         and then time out with a misleading error.
         Fix: link the 'privatelink.database.windows.net' Private DNS zone to
              your runner's VNet.
```

---

## Symptom → cause

| Symptom | Cause | Fix |
|---|---|---|
| DNS returns a public IP | zone not linked to the runner VNet | `link_private_dns_to_runner_vnet = true`, or forward the zone |
| DNS returns a private IP, TCP times out | peering missing or one-sided | check both peerings are `Connected` |
| Works for SQL, hangs for Synapse artifacts | `privatelink.dev.azuresynapse.net` missing | it is a separate zone from `sql.azuresynapse.net` |
| `sqlpackage` times out, `nc` on 1433 succeeds | ports 11000-11999 blocked | Azure SQL Redirect mode; the NSG rule opens them |
| `terraform apply` fails creating filesystems | `dfs` zone or peering missing | same three checks |
| `Login failed for user '<token-identified principal>'` | **not** networking | layer 3 — [12-troubleshooting](12-troubleshooting.md#adf-cannot-log-in-to-azure-sql) |

Check peering state in both directions — one-sided shows `Initiated`:

```bash
az network vnet peering list -g rg-edwtaxi-dev-eus2 --vnet-name vnet-edwtaxi-dev \
  --query "[].{name:name, state:peeringState, remote:remoteVirtualNetwork.id}" -o table

az network vnet peering list -g rg-github-runners --vnet-name vnet-github-runners \
  --query "[].{name:name, state:peeringState}" -o table
```

Check zone links:

```bash
for z in dfs.core.windows.net blob.core.windows.net database.windows.net \
         sql.azuresynapse.net dev.azuresynapse.net vaultcore.azure.net; do
  echo "== privatelink.$z"
  az network private-dns link vnet list \
    -g rg-edwtaxi-dev-eus2 -z "privatelink.$z" \
    --query "[].{link:name, vnet:virtualNetwork.id}" -o tsv
done
```

---

## If you cannot use a VNet-attached runner

You can, at a real cost in security posture, run from GitHub-hosted runners by
opening public access with an IP allowlist. Recorded because people ask, not
because it is recommended.

The problem: GitHub-hosted runners have no stable egress IP. The published
ranges are enormous and change constantly, so "allowlist GitHub" is close to
"allow the internet".

If you must:

1. Set `public_network_access_enabled = true` on storage, SQL and Synapse.
2. Have the workflow discover its own IP, add a firewall rule, deploy, and
   remove the rule in an `always()` step.

```yaml
- name: Open firewall for this runner
  id: fw
  run: |
    IP=$(curl -s https://api.ipify.org)
    echo "ip=$IP" >> "$GITHUB_OUTPUT"
    az sql server firewall-rule create -g "$RG" -s "$SERVER" \
      -n "gh-${{ github.run_id }}" --start-ip-address "$IP" --end-ip-address "$IP"

# ... deployment steps ...

- name: Close firewall
  if: always()          # MUST be always(), or a failed run leaves it open
  run: |
    az sql server firewall-rule delete -g "$RG" -s "$SERVER" \
      -n "gh-${{ github.run_id }}" || true
```

What you give up:

- The data plane is publicly reachable during every deployment window.
- A cancelled run can leave a rule behind — hence `always()`, and a periodic
  sweep for orphans.
- **Synapse serverless still will not work.** Its firewall is workspace-level
  and slower to propagate, and the Dev API in particular is unreliable through
  it.

The template does not support this path. It is written down so that the
trade-off is explicit rather than discovered.

---

Next: [06 — Data Factory](06-data-factory.md)
