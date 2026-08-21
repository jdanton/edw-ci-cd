# 04 — Networking

Private endpoints, managed virtual networks, and the nine DNS zones that decide
whether any of it works.

---

## Two kinds of private endpoint

They point in opposite directions and solve different problems. Conflating them
is the root of most private-networking confusion.

```
        ┌──────────────────────────────────────────────────────────────┐
        │  Your VNet (vnet-edwtaxi-dev)                                │
        │    snet-private-endpoints                                    │
        │                                                              │
        │   ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
        │   │ pe-...   │  │ pe-...   │  │ pe-...   │  │ pe-...   │    │
        │   │ storage  │  │ sql      │  │ synapse  │  │ adf      │    │
        │   └────▲─────┘  └────▲─────┘  └────▲─────┘  └────▲─────┘    │
        └────────┼─────────────┼─────────────┼─────────────┼──────────┘
                 │             │             │             │
       ══════════╪═════════════╪═════════════╪═════════════╪══════════
        INBOUND: callers reach the service. "Private endpoint."
        Who uses them: your self-hosted runner, ADF's managed VNet,
        Synapse's managed VNet, a jumpbox, Power BI gateway.
       ══════════╪═════════════╪═════════════╪═════════════╪══════════

        ┌────────┴─────────────┴──┐   ┌──────┴─────────────┴──────────┐
        │  ADF managed VNet       │   │  Synapse managed VNet         │
        │  (Microsoft-owned)      │   │  (Microsoft-owned)            │
        │                         │   │                               │
        │  mpe-lake-dfs           │   │  mpe-lake-dfs                 │
        │  mpe-lake-blob          │   │  mpe-lake-blob                │
        │  mpe-azure-sql          │   │  mpe-keyvault                 │
        │  mpe-synapse-sqlondemand│   │  mpe-azure-sql                │
        │  mpe-synapse-dev        │   │                               │
        │  mpe-keyvault           │   │                               │
        └─────────────────────────┘   └───────────────────────────────┘
        OUTBOUND: the service reaches data. "Managed private endpoint."
        You do not own the address space. You cannot route to it.
```

**Private endpoint** — a NIC in *your* subnet with a private IP. Created by
`azurerm_private_endpoint`. Governed by your NSG. This is how a caller reaches
a PaaS service.

**Managed private endpoint** — an outbound connection from a Microsoft-managed
VNet that ADF or Synapse runs its compute in. Created by
`azurerm_data_factory_managed_private_endpoint` /
`azurerm_synapse_managed_private_endpoint`. You never see its IP and cannot
route to it. This is how ADF reaches the lake.

You need both. A managed private endpoint from ADF to storage does not help
your runner, and a private endpoint in your subnet does not help ADF.

---

## The nine DNS zones

Getting this list wrong is the number one cause of "it works in the portal but
the pipeline times out". Every private endpoint registers an A record in exactly
one zone; if the zone is missing, or not linked to the **caller's** VNet, the
caller resolves the public IP and hangs.

| Zone | Sub-resource | Who needs it |
|---|---|---|
| `privatelink.dfs.core.windows.net` | storage `dfs` | ADF Parquet connector, Synapse `OPENROWSET`, Terraform filesystems |
| `privatelink.blob.core.windows.net` | storage `blob` | ADF Binary/Delete activities, AzCopy, SQL auditing |
| `privatelink.vaultcore.azure.net` | Key Vault `vault` | ADF/Synapse linked services, Terraform secrets |
| `privatelink.database.windows.net` | SQL `sqlServer` | `sqlpackage`, ADF Copy sink, SSMS |
| `privatelink.sql.azuresynapse.net` | Synapse `Sql` **and** `SqlOnDemand` | serverless DDL, ADF Script activity, Azure Data Studio |
| `privatelink.dev.azuresynapse.net` | Synapse `Dev` | **`azure.synapse.tools`** — artefact deployment |
| `privatelink.azuresynapse.net` | Private Link Hub `Web` | Synapse Studio from inside the network |
| `privatelink.datafactory.azure.net` | ADF `dataFactory` | ADF runtime, self-hosted IR, Studio data preview |
| `privatelink.adf.azure.com` | ADF `portal` | ADF Studio authoring UI |

Two of these catch people out:

**ADLS needs BOTH `dfs` and `blob`.** Not redundancy — genuinely different
APIs. Deploy one and roughly half your workloads break, in ways that look like
intermittent auth failures.

**Synapse has three sub-resources across two zones.** `Sql` and `SqlOnDemand`
share `privatelink.sql.azuresynapse.net`; `Dev` has its own. The template
creates the `Sql` endpoint even though there is no dedicated pool, because the
two share a DNS zone and having only one produces a confusing
partial-resolution state if a dedicated pool is ever added.

### Zone links

Each zone is linked to every VNet that needs to resolve it:

```hcl
dns_link_vnets = {
  "spoke"  = azurerm_virtual_network.this.id        # always
  "runner" = var.runner_vnet_id                     # if link_private_dns_to_runner_vnet
  "extra-0" = ...                                   # additional_dns_link_vnet_ids
}
```

Nine zones × N VNets links. `registration_enabled = false` throughout — Azure
must never auto-register VM records into a privatelink zone.

### Central DNS

Many organisations own all privatelink zones in a connectivity subscription,
usually enforced by an Azure Policy `DeployIfNotExists` on
`privateDnsZoneGroups`. For that:

```hcl
create_private_dns_zones = false
existing_private_dns_zone_ids = {
  "privatelink.dfs.core.windows.net"  = "/subscriptions/<hub>/.../privatelink.dfs.core.windows.net"
  "privatelink.blob.core.windows.net" = "..."
  # ... all nine
}
```

The full list, with the reason for each, is an output — hand it to your
networking team:

```bash
terraform output required_private_dns_zones
```

---

## The NSG

`snet-private-endpoints` carries an NSG. Private endpoints have honoured NSGs
since 2021, so this is a real control rather than decoration.

| Rule | Priority | Ports |
|---|---|---|
| Allow-VirtualNetwork-Inbound | 100 | 443, 1433, 1443, **11000-11999** |
| Deny-Internet-Inbound | 4000 | * |

`VirtualNetwork` includes peered address space, so the runner VNet is covered.

**The 11000-11999 range is not optional.** Azure SQL uses two connection
policies: *Proxy* (everything through the gateway on 1433) and *Redirect* (the
gateway hands back a node address on a high port, and the client connects
directly). Connections originating **inside Azure** — your runner, ADF's
managed VNet — negotiate Redirect. Block that range and `sqlpackage` fails with:

```
A network-related or instance-specific error occurred while establishing a
connection to SQL Server.
```

which says nothing about ports.

---

## Managed private endpoint approval

Creating one is half the job. The target receives a request in `Pending`, and
until it is approved, traffic does not flow — with no error anywhere until
something times out.

Terraform approves them via a `null_resource` provisioner running
[`scripts/Approve-PrivateEndpointConnections.ps1`](../scripts/Approve-PrivateEndpointConnections.ps1).

Check by hand:

```bash
STORAGE=$(terraform -chdir=infra/terraform output -raw storage_account_name)
RG=$(terraform      -chdir=infra/terraform output -raw resource_group_name)

az network private-endpoint-connection list \
  --resource-group "$RG" --name "$STORAGE" --type Microsoft.Storage/storageAccounts \
  --query "[].{name:name, state:properties.privateLinkServiceConnectionState.status}" -o table
```

Approve one manually:

```bash
az network private-endpoint-connection approve --id <connection-id> \
  --description "Approved by <you> on <date>"
```

From the ADF side you can also see them in Studio → Manage → Managed private
endpoints. A `Pending` badge there means nobody has approved the target side.

---

## The one public egress

`LS_OpenDatasets_NycTlc` reads
`https://azureopendatastorage.blob.core.windows.net` anonymously. There is no
managed private endpoint, and there cannot be — it is a Microsoft-owned public
account you do not control.

This works because a managed-VNet Azure integration runtime **retains outbound
access to public endpoints**. Managed VNet restricts *inbound* and gives you
private outbound where you configure it; it does not sever the internet.

Consequence: if you enable
`synapse_data_exfiltration_protection_enabled = true`, or an equivalent egress
lockdown, this copy is the first thing that breaks. Options then:

1. Mirror the data into your own storage account first (via a self-hosted IR
   with internet access) and read that.
2. Get the Microsoft tenant ID added to the workspace's approved tenant list —
   which weakens exfiltration protection.
3. Accept it and use a different source.

Documented rather than solved, because the right answer depends on why you
turned exfiltration protection on.

---

## What is still public

Honesty about the boundary:

| Endpoint | Public? | Why |
|---|---|---|
| ARM (`management.azure.com`) | yes | Always. Terraform and `azure.datafactory.tools` use it. Protected by Entra, not by network. |
| Entra (`login.microsoftonline.com`) | yes | Token acquisition. |
| Microsoft Graph | yes | `CREATE USER ... FROM EXTERNAL PROVIDER` resolves the principal through Graph. |
| Log Analytics ingestion | yes | Hardening it needs an Azure Monitor Private Link Scope, which is a real project. Deliberately out of scope. |
| Azure Open Datasets | yes | The source. See above. |
| Terraform state account | configurable | `state_storage_allowed_ips` in `bootstrap/terraform.tfvars`. Default open, protected by Entra RBAC + OIDC. Lock it to your runner's egress IP once the runners are proven. |

So "everything is private" means **the data plane is private**. The control
plane is public and authenticated. That is the normal, defensible posture; if
your compliance regime requires private ARM access as well, you need Azure
Private Link for ARM and AMPLS, and this template is a starting point rather
than a finished answer.

---

## Verifying

```bash
./scripts/Test-PlatformConnectivity.ps1 -Environment dev
```

For a single name, from the runner:

```bash
# Must be an RFC1918 address.
nslookup sql-edwtaxi-dev-a7k2.database.windows.net

# The CNAME chain should end in privatelink.*
dig +short sql-edwtaxi-dev-a7k2.database.windows.net
#   sql-edwtaxi-dev-a7k2.privatelink.database.windows.net.
#   10.60.0.7

# Reachability
nc -zv sql-edwtaxi-dev-a7k2.database.windows.net 1433
```

A public IP here is the whole problem. Go to
[05-runner-connectivity](05-runner-connectivity.md).

---

Next: [05 — Runner connectivity](05-runner-connectivity.md)
