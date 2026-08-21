#!/usr/bin/env pwsh
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

. (Join-Path $PSScriptRoot '_Tooling.ps1')   # PATH repair + Resolve-RequiredTool

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    OK  $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    !!  $Message" -ForegroundColor Yellow }

if ([string]::IsNullOrWhiteSpace($TargetResourceIds)) {
    Write-Warn 'No target resource IDs supplied. Nothing to do.'
    exit 0
}

Resolve-RequiredTool -Name 'az' `
    -InstallHint 'Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli' `
    -PostCheck { az account show *>$null; $LASTEXITCODE -eq 0 } `
    -FailureMessage 'The Azure CLI is installed but not authenticated. This script is invoked by Terraform and needs an authenticated context - run az login, or azure/login@v2 in CI.' | Out-Null

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
$failures      = @()

function Get-Connection {
    param([string]$ResourceId, [string]$Query)

    $raw = az network private-endpoint-connection list --id $ResourceId --query $Query --output json 2>$null

    # Some resource types do not expose this sub-resource until the first
    # connection exists; an empty result is normal, not an error.
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return @() }

    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }

    # Filter by name here rather than in the query so that a null name -
    # which JMESPath renders as $null rather than omitting the key - cannot
    # blow up the comparison.
    return @($parsed | Where-Object {
            -not $ConnectionPrefix -or ("$($_.name)" -like "*$ConnectionPrefix*")
        })
}

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
    # ---------------------------------------------------------------------
    # Filtering happens SERVER-SIDE, in JMESPath, not in PowerShell.
    #
    # The first version of this pipelined the raw JSON through Where-Object and
    # read $_.properties...status and $_.name. Under `Set-StrictMode -Version
    # Latest` that throws the moment ANY element lacks the property:
    #
    #     The property 'name' cannot be found on this object.
    #
    # and it did - part way through a run, AFTER approving one connection,
    # leaving the remaining managed private endpoints Pending and the whole
    # terraform apply failed. JMESPath simply yields nothing for a missing
    # field, so the shape of what Azure returns can vary without breaking us.
    #
    # Projecting to {id, name} also means nothing downstream depends on the
    # rest of the object graph.
    # ---------------------------------------------------------------------
    $pending = @()
    $attempt = 0

    $pendingQuery  = "[?properties.privateLinkServiceConnectionState.status=='Pending'].{id:id,name:name}"
    $approvedQuery = "[?properties.privateLinkServiceConnectionState.status=='Approved'].{id:id,name:name}"

    while ($attempt -lt $MaxAttempts) {
        $attempt++

        $pending = Get-Connection -ResourceId $id -Query $pendingQuery
        if ($pending.Count -gt 0) { break }

        $anyApproved = Get-Connection -ResourceId $id -Query $approvedQuery
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
                # Record and keep going. Throwing here would leave every
                # REMAINING endpoint pending - which is exactly what happened
                # when this script first ran: it approved one connection, hit an
                # error, and left three managed private endpoints unapproved.
                # A partially-connected platform is harder to diagnose than a
                # cleanly failed one, so approve everything we can and report
                # the failures together at the end.
                Write-Warn "$connectionName could NOT be approved."
                $failures += "$resourceName / $connectionName"
                continue
            }

            Write-Ok "$connectionName approved."
            $totalApproved++
        }
    }
}

Write-Step "Done. $totalApproved of $totalPending pending connection(s) approved."

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'These connections could not be approved:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Approve them in the portal (target resource -> Networking ->' -ForegroundColor Yellow
    Write-Host 'Private endpoint connections) or with:' -ForegroundColor Yellow
    Write-Host '  az network private-endpoint-connection approve --id <connection-id>' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Until then the source service cannot reach the target, and pipelines' -ForegroundColor Yellow
    Write-Host 'will fail with connection timeouts rather than permission errors.' -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
# Deliberately exit 0 when nothing was pending. Terraform re-runs this
# provisioner whenever the endpoint set changes, and the overwhelmingly common
# case on re-apply is "everything is already approved". Failing there would
# make every subsequent apply red for no reason.
# ---------------------------------------------------------------------------
exit 0
