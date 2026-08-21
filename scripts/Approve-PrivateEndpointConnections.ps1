#Requires -Version 7.0
<#
.SYNOPSIS
    Approves pending private endpoint connections on the resources that ADF and
    Synapse raise managed private endpoints against.

.DESCRIPTION
    A managed private endpoint is only half a connection.

    When Data Factory or Synapse creates one, the endpoint appears on the SOURCE
    side immediately, but the TARGET resource (the storage account, the SQL
    server, the Key Vault) receives a connection request in state 'Pending'.
    Until somebody approves it, traffic does not flow - and nothing tells you.
    The symptom is a pipeline that hangs and then times out with a connectivity
    error naming the target, which sends people off checking DNS and firewalls.

    When Terraform owns BOTH sides - the normal case in this template - there is
    nobody else to ask, so this script approves them programmatically. It is
    invoked by a null_resource provisioner in
    infra/terraform/modules/datafactory and infra/terraform/modules/synapse.

    Set auto_approve_managed_private_endpoints = false in tfvars if a security
    team owns approvals in your organisation, and expect the platform to be
    non-functional until they act.

.PARAMETER TargetResourceIds
    Comma-separated ARM resource IDs to inspect. Defaults to the
    TARGET_RESOURCE_IDS environment variable, which is how Terraform passes it.

.PARAMETER ConnectionPrefix
    Only approve connections whose name contains this string. Terraform passes
    the factory or workspace name, so a run for the dev factory cannot approve a
    stray connection request raised by something else - which would be a real
    security hole in a shared subscription.

.PARAMETER ApprovalReason
    Text recorded in the connection's approval description. Shows up in the
    portal and in `az network private-endpoint-connection show`.

.PARAMETER WhatIf
    Report what would be approved without approving it.

.EXAMPLE
    ./scripts/Approve-PrivateEndpointConnections.ps1 `
        -TargetResourceIds "/subscriptions/.../storageAccounts/stedwtaxidev" `
        -ConnectionPrefix "adf-edwtaxi-dev"

.NOTES
    Requires the Azure CLI, authenticated. On a GitHub runner that means
    azure/login@v2 ran first. Exits non-zero only on a genuine failure -
    "nothing pending" is a success.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $TargetResourceIds = $env:TARGET_RESOURCE_IDS,
    [string] $ConnectionPrefix  = $env:CONNECTION_PREFIX,
    [string] $ApprovalReason    = $(if ($env:APPROVAL_REASON) { $env:APPROVAL_REASON } else { 'Auto-approved by Terraform' }),
    [int]    $MaxAttempts       = 12,
    [int]    $RetryDelaySeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    OK  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    !!  $Message" -ForegroundColor Yellow }

if ([string]::IsNullOrWhiteSpace($TargetResourceIds)) {
    Write-Warn 'No target resource IDs supplied. Nothing to do.'
    exit 0
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'The Azure CLI (az) is not on PATH. This script is invoked by Terraform and needs an authenticated az context.'
}

$ids = $TargetResourceIds.Split(',', [StringSplitOptions]::RemoveEmptyEntries) |
       ForEach-Object { $_.Trim() } |
       Where-Object   { $_ } |
       Select-Object -Unique

Write-Step "Checking $($ids.Count) target resource(s) for pending private endpoint connections."
if ($ConnectionPrefix) {
    Write-Host "    Only connections whose name contains '$ConnectionPrefix' will be approved."
}

$totalApproved = 0
$totalPending  = 0

foreach ($id in $ids) {
    $resourceName = $id.Split('/')[-1]

    # ---------------------------------------------------------------------
    # A managed private endpoint takes a little while to register on the
    # target. Poll rather than checking once: Terraform calls this immediately
    # after creating the endpoints, and on a cold subscription the connection
    # request routinely takes 30-60 seconds to appear.
    #
    # Not finding anything is NOT an error - the endpoint may already have been
    # approved by a previous run, which is the common case on re-apply.
    # ---------------------------------------------------------------------
    $pending  = @()
    $attempt  = 0

    while ($attempt -lt $MaxAttempts) {
        $attempt++

        $raw = az network private-endpoint-connection list --id $id --output json 2>$null

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
            # Some resource types do not expose this sub-resource at all until
            # the first connection exists. Treat as "nothing yet".
            $connections = @()
        }
        else {
            $connections = $raw | ConvertFrom-Json
        }

        $pending = @($connections | Where-Object {
            $_.properties.privateLinkServiceConnectionState.status -eq 'Pending' -and
            (-not $ConnectionPrefix -or $_.name -like "*$ConnectionPrefix*")
        })

        if ($pending.Count -gt 0) { break }

        $anyApproved = @($connections | Where-Object {
            $_.properties.privateLinkServiceConnectionState.status -eq 'Approved' -and
            (-not $ConnectionPrefix -or $_.name -like "*$ConnectionPrefix*")
        })

        if ($anyApproved.Count -gt 0) {
            Write-Ok "$resourceName - $($anyApproved.Count) connection(s) already approved."
            break
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Host "    $resourceName - nothing pending yet (attempt $attempt/$MaxAttempts), waiting ${RetryDelaySeconds}s..."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    $totalPending += $pending.Count

    foreach ($connection in $pending) {
        $connectionName = $connection.name

        if ($PSCmdlet.ShouldProcess("$resourceName / $connectionName", 'Approve private endpoint connection')) {
            Write-Host "    Approving $connectionName on $resourceName..."

            az network private-endpoint-connection approve `
                --id $connection.id `
                --description $ApprovalReason `
                --output none 2>&1 | Out-Null

            if ($LASTEXITCODE -ne 0) {
                throw "Failed to approve private endpoint connection '$connectionName' on '$resourceName'. Approve it manually in the portal (Networking -> Private endpoint connections) and re-run terraform apply."
            }

            Write-Ok "$connectionName approved."
            $totalApproved++
        }
    }
}

Write-Step "Done. $totalApproved of $totalPending pending connection(s) approved."

# ---------------------------------------------------------------------------
# Deliberately exit 0 when nothing was pending. Terraform re-runs this
# provisioner whenever the endpoint set changes, and the overwhelmingly common
# case on re-apply is "everything is already approved". Failing there would
# make every subsequent apply red for no reason.
# ---------------------------------------------------------------------------
exit 0
