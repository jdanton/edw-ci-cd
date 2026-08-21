#Requires -Version 7.0
<#
.SYNOPSIS
    Proves that this host can actually reach the private data plane. Run it on
    your self-hosted runner BEFORE debugging anything else.

.DESCRIPTION
    Every data-plane endpoint in this platform has public network access
    disabled. That means a deployment can fail for three quite different
    reasons, which produce nearly identical symptoms:

      1. DNS      - the name resolves to a PUBLIC IP because the runner's VNet
                    is not linked to the privatelink zone. Connections then hang
                    until they time out. This is by far the most common cause,
                    and the error message never mentions DNS.

      2. Routing  - the name resolves correctly to a private IP, but there is no
                    peering (or the peering is one-sided, which Azure reports as
                    'Initiated' rather than 'Connected'), so packets go nowhere.

      3. Identity - the network is fine and the token is wrong, missing, or the
                    principal has no grant inside the database.

    This script tells the three apart in about twenty seconds. It is the first
    thing docs/12-troubleshooting.md asks you to run.

.PARAMETER Environment
    dev, test or prod. Endpoints are read from `terraform output`.

.PARAMETER TerraformDirectory
    Root Terraform module. Defaults to infra/terraform relative to the repo root.

.PARAMETER SkipTerraform
    Supply the endpoints by parameter instead of reading Terraform state -
    useful from a jumpbox with no state access.

.EXAMPLE
    ./scripts/Test-PlatformConnectivity.ps1 -Environment dev

.EXAMPLE
    ./scripts/Test-PlatformConnectivity.ps1 -SkipTerraform `
        -SqlServerFqdn sql-edwtaxi-dev-a7k2.database.windows.net `
        -SynapseServerlessEndpoint syn-edwtaxi-dev-a7k2-ondemand.sql.azuresynapse.net `
        -StorageAccountName stedwtaxideva7k2 `
        -SynapseWorkspaceName syn-edwtaxi-dev-a7k2
#>
[CmdletBinding()]
param(
    [ValidateSet('dev', 'test', 'prod')]
    [string] $Environment = 'dev',

    [string] $TerraformDirectory = (Join-Path $PSScriptRoot '..' 'infra' 'terraform'),

    [switch] $SkipTerraform,
    [string] $SqlServerFqdn,
    [string] $SynapseServerlessEndpoint,
    [string] $SynapseWorkspaceName,
    [string] $StorageAccountName,
    [string] $KeyVaultName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Failures = 0
$script:Warnings = 0

function Write-Header {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkGray
}

function Write-Pass { param([string]$m) Write-Host "  [PASS] $m" -ForegroundColor Green }
function Write-Fail { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:Failures++ }
function Write-Warn { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow; $script:Warnings++ }
function Write-Info { param([string]$m) Write-Host "         $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# RFC1918 / private address detection.
#
# Azure private endpoints always land in your VNet address space, which is
# private. A public resolution is therefore proof that the privatelink zone is
# not reachable from this host.
# ---------------------------------------------------------------------------
function Test-IsPrivateAddress {
    param([string]$IpAddress)

    $octets = $IpAddress.Split('.')
    if ($octets.Count -ne 4) { return $false }

    $a = [int]$octets[0]
    $b = [int]$octets[1]

    return ($a -eq 10) -or
           ($a -eq 192 -and $b -eq 168) -or
           ($a -eq 172 -and $b -ge 16 -and $b -le 31)
}

function Test-Endpoint {
    param(
        [string]$Name,
        [string]$Hostname,
        [int]$Port,
        [string]$ExpectedPrivateLinkZone
    )

    if ([string]::IsNullOrWhiteSpace($Hostname)) {
        Write-Warn "$Name - no hostname supplied, skipped."
        return
    }

    Write-Host ''
    Write-Host "  $Name  ($Hostname : $Port)" -ForegroundColor White

    # ---- DNS -------------------------------------------------------------
    $addresses = @()
    try {
        $addresses = @([System.Net.Dns]::GetHostAddresses($Hostname) |
                       Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                       ForEach-Object { $_.IPAddressToString })
    }
    catch {
        Write-Fail "DNS resolution failed entirely: $($_.Exception.Message)"
        Write-Info "The name does not resolve at all. Either the resource does not exist, or this host has no DNS server that knows about it."
        return
    }

    if ($addresses.Count -eq 0) {
        Write-Fail 'DNS returned no IPv4 addresses.'
        return
    }

    $ip = $addresses[0]

    if (Test-IsPrivateAddress -IpAddress $ip) {
        Write-Pass "DNS -> $ip (private)"
    }
    else {
        Write-Fail "DNS -> $ip (PUBLIC)"
        Write-Info "This host is resolving the PUBLIC endpoint. Every connection will hang and then time out with a misleading error."
        Write-Info "Fix: link the '$ExpectedPrivateLinkZone' Private DNS zone to your runner's VNet."
        Write-Info "     Terraform does this when link_private_dns_to_runner_vnet = true and runner_vnet_id is set."
        Write-Info "     Verify with: terraform output runner_vnet_dns_linked"
        Write-Info "     If your runner VNet uses custom DNS or a DNS Private Resolver, forward that zone there instead."
        return
    }

    # ---- TCP -------------------------------------------------------------
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $tcp.ConnectAsync($ip, $Port)
        if ($connectTask.Wait(10000) -and $tcp.Connected) {
            Write-Pass "TCP $Port open"
        }
        else {
            Write-Fail "TCP $Port did not connect within 10s"
            Write-Info "DNS is correct but packets are not arriving. Check, in this order:"
            Write-Info "  1. VNet peering exists AND is 'Connected' in BOTH directions."
            Write-Info "     az network vnet peering list -g <rg> --vnet-name <vnet> -o table"
            Write-Info "     A one-sided peering shows 'Initiated' and carries no traffic."
            Write-Info "  2. The NSG on snet-private-endpoints allows this port inbound."
            Write-Info "  3. For Azure SQL specifically, ports 11000-11999 must also be open -"
            Write-Info "     connections originating inside Azure negotiate Redirect mode."
        }
    }
    catch {
        Write-Fail "TCP $Port failed: $($_.Exception.Message)"
    }
    finally {
        $tcp.Dispose()
    }
}

# ===========================================================================
# Resolve endpoints
# ===========================================================================

Write-Header "EDW platform connectivity check - $Environment"
Write-Info "Host: $([System.Net.Dns]::GetHostName())"

if (-not $SkipTerraform) {
    Write-Host ''
    Write-Host '  Reading endpoints from Terraform state...' -ForegroundColor DarkGray

    Push-Location $TerraformDirectory
    try {
        $json = terraform output -json deployment_config 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
            throw "terraform output failed. Run 'terraform init -backend-config=envs/$Environment/backend.hcl' first, or use -SkipTerraform and pass the endpoints directly."
        }

        $cfg = $json | ConvertFrom-Json

        $SqlServerFqdn             = $cfg.sqlServerFqdn
        $SynapseServerlessEndpoint = $cfg.synapseServerlessEndpoint
        $SynapseWorkspaceName      = $cfg.synapseWorkspaceName
        $StorageAccountName        = $cfg.storageAccountName
        $KeyVaultName              = $cfg.keyVaultName
    }
    finally {
        Pop-Location
    }
}

# ===========================================================================
# The checks
# ===========================================================================

Write-Header 'Data plane reachability'

Test-Endpoint -Name 'Azure SQL (TDS)' `
              -Hostname $SqlServerFqdn -Port 1433 `
              -ExpectedPrivateLinkZone 'privatelink.database.windows.net'

Test-Endpoint -Name 'Synapse serverless SQL (TDS)' `
              -Hostname $SynapseServerlessEndpoint -Port 1433 `
              -ExpectedPrivateLinkZone 'privatelink.sql.azuresynapse.net'

if ($SynapseWorkspaceName) {
    Test-Endpoint -Name 'Synapse Dev API (azure.synapse.tools)' `
                  -Hostname "$SynapseWorkspaceName.dev.azuresynapse.net" -Port 443 `
                  -ExpectedPrivateLinkZone 'privatelink.dev.azuresynapse.net'
}

if ($StorageAccountName) {
    Test-Endpoint -Name 'ADLS Gen2 (dfs)' `
                  -Hostname "$StorageAccountName.dfs.core.windows.net" -Port 443 `
                  -ExpectedPrivateLinkZone 'privatelink.dfs.core.windows.net'

    Test-Endpoint -Name 'ADLS Gen2 (blob)' `
                  -Hostname "$StorageAccountName.blob.core.windows.net" -Port 443 `
                  -ExpectedPrivateLinkZone 'privatelink.blob.core.windows.net'
}

if ($KeyVaultName) {
    Test-Endpoint -Name 'Key Vault' `
                  -Hostname "$KeyVaultName.vault.azure.net" -Port 443 `
                  -ExpectedPrivateLinkZone 'privatelink.vaultcore.azure.net'
}

# ===========================================================================
# Control plane and identity - these stay PUBLIC and must remain reachable
# ===========================================================================

Write-Header 'Control plane and identity (these are public by design)'

foreach ($endpoint in @(
    @{ Name = 'ARM (Terraform, azure.datafactory.tools)'; Host = 'management.azure.com' },
    @{ Name = 'Entra ID (token acquisition)';             Host = 'login.microsoftonline.com' },
    @{ Name = 'Microsoft Graph (CREATE USER FROM EXTERNAL PROVIDER)'; Host = 'graph.microsoft.com' }
)) {
    try {
        $null = [System.Net.Dns]::GetHostAddresses($endpoint.Host)
        $tcp  = [System.Net.Sockets.TcpClient]::new()
        $task = $tcp.ConnectAsync($endpoint.Host, 443)
        if ($task.Wait(10000) -and $tcp.Connected) {
            Write-Pass "$($endpoint.Name)"
        } else {
            Write-Fail "$($endpoint.Name) - cannot reach $($endpoint.Host):443"
            Write-Info 'The runner needs outbound internet access for these. Check the NAT gateway / firewall on the runner subnet.'
        }
        $tcp.Dispose()
    }
    catch {
        Write-Fail "$($endpoint.Name) - $($_.Exception.Message)"
    }
}

# ===========================================================================
# Identity
# ===========================================================================

Write-Header 'Azure identity'

if (Get-Command az -ErrorAction SilentlyContinue) {
    $account = az account show --output json 2>$null | ConvertFrom-Json
    if ($account) {
        Write-Pass "Signed in as $($account.user.name) ($($account.user.type))"
        Write-Info "Subscription: $($account.name) [$($account.id)]"
        Write-Info "Tenant:       $($account.tenantId)"
    }
    else {
        Write-Fail 'Azure CLI is not authenticated. Run azure/login@v2 (CI) or az login (local).'
    }
}
else {
    Write-Warn 'Azure CLI not found on PATH.'
}

# ===========================================================================
# Verdict
# ===========================================================================

Write-Header 'Result'

if ($script:Failures -eq 0) {
    Write-Host "  All checks passed ($script:Warnings warning(s))." -ForegroundColor Green
    Write-Host '  This host can deploy to the private data plane.' -ForegroundColor Green
    exit 0
}

Write-Host "  $script:Failures check(s) FAILED, $script:Warnings warning(s)." -ForegroundColor Red
Write-Host ''
Write-Host '  Do not attempt to debug a deployment until these pass - every' -ForegroundColor Yellow
Write-Host '  downstream error will be a misleading symptom of one of them.' -ForegroundColor Yellow
Write-Host '  See docs/12-troubleshooting.md' -ForegroundColor Yellow
exit 1
