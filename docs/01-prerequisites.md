# 01 — Prerequisites

Check all of this before starting. Every item here has cost somebody an
afternoon at some point.

---

## Tools

| Tool | Minimum | Why | Install |
|---|---|---|---|
| Azure CLI | 2.60 | Everything. Private endpoint approvals, token acquisition, ADF pipeline runs. | [docs](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| Terraform | 1.5 | The configuration avoids 1.6+ syntax so it validates on 1.5. CI pins 1.9.8. | [releases](https://developer.hashicorp.com/terraform/install) |
| PowerShell | 7.4 | Every deployment script. **Not** Windows PowerShell 5.1 — the scripts use `??`, ternaries and `-Parallel`. | [docs](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) |
| .NET SDK | 8.0 | Builds the SDK-style `.sqlproj`. | [dotnet.microsoft.com](https://dotnet.microsoft.com/download) |
| sqlpackage | 162.x | Publishes the DACPAC. `dotnet tool install --global microsoft.sqlpackage` | [docs](https://learn.microsoft.com/sql/tools/sqlpackage/sqlpackage-download) |
| GitHub CLI | 2.40 | `Set-GitHubOidcSecrets.ps1` only. | [cli.github.com](https://cli.github.com/) |

PowerShell modules (the scripts install them on first run if absent):

```powershell
Install-Module Az.Accounts, Az.DataFactory, Az.Synapse -Scope CurrentUser
Install-Module SqlServer -MinimumVersion 22.0.0 -Scope CurrentUser
Install-Module azure.datafactory.tools -RequiredVersion 1.11.0 -Scope CurrentUser
Install-Module azure.synapse.tools     -RequiredVersion 1.6.0  -Scope CurrentUser
```

Verify everything at once:

```bash
for t in az terraform pwsh dotnet sqlpackage gh; do
  printf '%-12s ' "$t"
  command -v $t >/dev/null 2>&1 && $t --version 2>/dev/null | head -1 || echo 'MISSING'
done
```

> **On module versions.** `Deploy-DataFactory.ps1` and `Deploy-Synapse.ps1`
> pin exact versions with `-RequiredVersion`. That is intentional: these
> modules deploy to production, and a floating version means a deployment can
> change behaviour without a single commit in this repository. Upgrade
> deliberately, in a pull request, after testing in dev.

---

## Azure permissions

### For the bootstrap (a human, once)

| Scope | Role | For |
|---|---|---|
| Subscription | **Owner**, or Contributor + User Access Administrator | Creating role assignments for the deployment identities. |
| Entra tenant | **Application Administrator** or Global Administrator | Creating app registrations and service principals. |
| Entra tenant | **Groups Administrator** | Creating the SQL and Synapse admin security groups. |

If your tenant restricts app registration to administrators (common, and
correct), you need someone with that role for step 1 only. Everything after
bootstrap runs as the service principals it creates.

Check what you have:

```bash
# Azure roles at subscription scope
az role assignment list --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --scope "/subscriptions/$(az account show --query id -o tsv)" \
  --query "[].roleDefinitionName" -o tsv

# Can you create an app registration? This is the honest test.
az ad app create --display-name "delete-me-permission-probe" --query appId -o tsv
# then: az ad app delete --id <appId>
```

### For the pipelines (created by bootstrap)

Created for you; listed so you know what exists.

| Identity | Scope | Roles |
|---|---|---|
| `sp-<project>-github-deploy-<env>` | subscription | Contributor + Role Based Access Control Administrator (ABAC-constrained to five data-plane roles) |
| | tfstate container | Storage Blob Data Contributor |
| | Entra | member of the SQL and Synapse admin groups |
| `sp-<project>-github-ci` | subscription | Reader |
| | tfstate container | Storage Blob Data Contributor (plan takes the state lock) |

The RBAC Administrator grant carries an ABAC condition restricting it to the
exact role definitions this template assigns. Without that condition, an
identity that can assign roles can assign itself Owner. See
[`bootstrap/main.tf`](../bootstrap/main.tf).

---

## Resource providers

Registration is per-subscription and takes a few minutes. Doing it up front
avoids a failed apply twenty minutes in.

```bash
for ns in Microsoft.Storage Microsoft.Sql Microsoft.Synapse Microsoft.DataFactory \
          Microsoft.KeyVault Microsoft.Network Microsoft.OperationalInsights \
          Microsoft.Insights Microsoft.Authorization; do
  az provider register --namespace "$ns" --wait &
done
wait

az provider list --query "[?registrationState=='Registered'].namespace" -o tsv | sort
```

---

## Quotas

Nothing here is large, but two limits bite:

```bash
LOC=eastus2

# Private endpoints. This template creates ~10 per environment, 30 for all three.
az network list-usages --location $LOC \
  --query "[?contains(name.value, 'PrivateEndpoints')]" -o table

# vCores for Azure SQL. prod uses GP_Gen5_4.
az sql list-usages --location $LOC -o table
```

New subscriptions sometimes have a private endpoint limit that three
environments exceed. Raising it is a support request that takes a day, so check
now rather than at the prod deployment.

---

## Your self-hosted runner

This is the prerequisite that is easiest to get wrong, because you already have
runners and they already work — for other repositories.

### It must be inside a VNet

Every data-plane endpoint in this platform has public network access disabled.
A GitHub-hosted runner cannot:

- create ADLS filesystems (`terraform apply` calls the dfs data plane)
- publish Synapse artifacts (`<workspace>.dev.azuresynapse.net`)
- run the serverless DDL (`<workspace>-ondemand.sql.azuresynapse.net`, TDS)
- publish the DACPAC (`sqlpackage`, TDS 1433)

None of those fail with a network error. They hang, then time out, with a
message blaming SQL or the REST API.

### Checklist

```bash
RUNNER_VNET=/subscriptions/.../resourceGroups/rg-runners/providers/Microsoft.Network/virtualNetworks/vnet-runners

# 1. Address space must NOT overlap the EDW VNets (10.60/61/62.0.0/24 by default).
az network vnet show --ids "$RUNNER_VNET" --query addressSpace.addressPrefixes -o tsv

# 2. Outbound internet — for GitHub, Entra, ARM, Graph, PowerShell Gallery, NuGet.
#    A NAT gateway or a firewall with those FQDNs allowed.
az network vnet subnet list --ids "$RUNNER_VNET" \
  --query "[].{name:name, natGateway:natGateway.id, routeTable:routeTable.id}" -o table

# 3. Custom DNS? This determines whether Terraform can link the privatelink
#    zones directly, or whether you need forwarding rules instead.
az network vnet show --ids "$RUNNER_VNET" --query dhcpOptions.dnsServers -o tsv
```

- **No custom DNS servers listed** → the VNet uses Azure-provided DNS. Terraform
  links the `privatelink.*` zones to it and everything works. Leave
  `link_private_dns_to_runner_vnet = true`.
- **Custom DNS servers listed** → those servers must forward the nine
  `privatelink.*` zones to Azure DNS (168.63.129.16) or to a DNS Private
  Resolver. Set `link_private_dns_to_runner_vnet = false` and configure
  forwarding. See [05-runner-connectivity](05-runner-connectivity.md#custom-dns).

### Software on the runner

```bash
# On the runner:
for t in az terraform pwsh dotnet git; do
  printf '%-10s ' "$t"; command -v $t >/dev/null && echo present || echo MISSING
done
pwsh -c '$PSVersionTable.PSVersion'    # must be 7.x
```

The workflows install `sqlpackage`, `SqlServer`, `azure.datafactory.tools` and
`azure.synapse.tools` on demand, but pre-installing them saves two to three
minutes per run.

### Labels

The workflows target:

```yaml
runs-on: ${{ fromJSON(vars.RUNNER_LABELS || '["self-hosted","linux","X64","edw"]') }}
```

Either add the `edw` label to your runners, or set the repository variable
`RUNNER_LABELS` to a JSON array matching yours:

```bash
gh variable set RUNNER_LABELS --body '["self-hosted","linux","X64","data-platform"]'
```

Do **not** change these to `ubuntu-latest`. It will look like it works — the
lint and build jobs pass — and then every deployment job will hang.

---

## GitHub repository

| Requirement | Note |
|---|---|
| Actions enabled | Settings → Actions → General |
| Environments available | Public repos, or GitHub Team/Enterprise on private repos. Without Environments you lose approval gates and the OIDC subject changes — see [09-cicd-workflows](09-cicd-workflows.md#if-you-cannot-use-environments). |
| Default branch `main` | Or change `default_branch` in `bootstrap/terraform.tfvars`; it forms part of the OIDC subject. |
| Branch protection on `main` | Not required to deploy, required to be sane. |

---

## Cost expectation

Do not start until somebody has agreed to this. Rough monthly figures for
East US 2 at list price, with the pipelines idle:

| | dev | test | prod |
|---|---|---|---|
| Private endpoints (~10 × $7.30) | $73 | $73 | $73 |
| Azure SQL | ~$15 (auto-paused) | ~$40 | ~$580 (GP_Gen5_4, ZRS) |
| Storage (1 yr of trips ≈ 25 GB) | ~$1 | ~$2 | ~$3 |
| Log Analytics | ~$5 | ~$10 | ~$40 |
| Bastion | — | — | ~$140 |
| **Idle subtotal** | **~$95** | **~$125** | **~$835** |

Plus per-run: ADF activity runs and managed-VNet IR time (pennies per month
loaded), and Synapse serverless at roughly $5/TB scanned (a month rebuild scans
~3 GB).

The private endpoints are the surprise. Ten per environment is what
"private-only" costs, and it is charged whether traffic flows or not. Full
breakdown and the levers that matter: [13-cost](13-cost.md).

---

Next: [02 — Bootstrap](02-bootstrap.md)
