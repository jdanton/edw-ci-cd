#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the config-<env>.generated.csv files that azure.datafactory.tools and
    azure.synapse.tools consume, by merging the hand-maintained CSV with
    endpoints read from Terraform outputs.

.DESCRIPTION
    Per-environment configuration is split in two on purpose:

      config-<env>.csv             committed, reviewed. Human DECISIONS:
                                   which triggers run, batch sizes, timeouts.

      config-<env>.generated.csv   built here, gitignored. FACTS about the
                                   infrastructure: storage URLs, SQL FQDNs,
                                   Synapse endpoints.

    Committing the endpoints would mean every environment rebuild produces a
    pull request full of mechanical noise - and, worse, a stale CSV silently
    deploys a linked service pointing at a storage account that no longer
    exists. That failure surfaces hours later as an authentication error, not
    as a deployment error.

    Generating the DECISIONS would be equally wrong: "is the production trigger
    enabled?" belongs in a file a reviewer reads.

    Generated rows win on conflict, so a hand-edited endpoint row is overridden
    rather than silently disagreeing with reality.

.PARAMETER Environment
    dev, test or prod.

.PARAMETER Verify
    Do not write anything. Exit non-zero if a committed CSV contains a row that
    the generator would override with a DIFFERENT value - i.e. somebody hard-
    coded an endpoint that has since changed. Used by the PR validation
    workflow.

.EXAMPLE
    ./scripts/New-DeploymentConfig.ps1 -Environment dev

.EXAMPLE
    ./scripts/New-DeploymentConfig.ps1 -Environment prod -Verify
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'prod')]
    [string] $Environment,

    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,

    [switch] $Verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Tooling.ps1')   # PATH repair + Resolve-RequiredTool

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }

$terraformDir = Join-Path $RepositoryRoot 'infra' 'terraform'

# ---------------------------------------------------------------------------
# 1. Read the infrastructure facts
# ---------------------------------------------------------------------------

Write-Step "Reading Terraform outputs for '$Environment'."

Push-Location $terraformDir
try {
    $outputJson = terraform output -json deployment_config 2>&1
    $terraformExitCode = $LASTEXITCODE

    # ---------------------------------------------------------------------
    # "Output not found" means the environment has never been applied - the
    # state file is empty. That is a NORMAL state on a brand-new environment,
    # and the two callers want opposite things from it:
    #
    #   -Verify   (pr-validate) There is nothing to verify against yet. Failing
    #             here would make the FIRST pull request on a fresh repository
    #             red for a reason the author did not cause and cannot fix
    #             without deploying infrastructure - which is exactly what the
    #             pull request is asking permission to do. Skip, and say so.
    #
    #   generate  (a deployment) This is fatal. Artifacts cannot be deployed
    #             into infrastructure that does not exist, and the endpoints
    #             they need are the outputs that are missing.
    # ---------------------------------------------------------------------
    $stateIsEmpty = ($terraformExitCode -ne 0) -and
                    ("$outputJson" -match 'Output "deployment_config" not found|No outputs found')

    if ($stateIsEmpty) {
        if ($Verify) {
            Write-Host ''
            Write-Host "::notice::Environment '$Environment' has no Terraform state yet, so there is nothing to verify the committed configuration against. Skipping. This check becomes meaningful once the environment has been deployed once."
            Write-Ok "Skipped - '$Environment' not deployed yet."
            exit 0
        }

        # Written with Write-Host rather than embedded in the throw: PowerShell's
        # default error view collapses newlines in an exception message, which
        # turns a carefully formatted set of instructions into one unreadable
        # paragraph. Print the detail, throw a single line.
        Write-Host ''
        Write-Host "Environment '$Environment' has not been deployed." -ForegroundColor Red
        Write-Host ''
        Write-Host "  'terraform output deployment_config' found no outputs, which means the"
        Write-Host "  state file is empty. Artifacts cannot be deployed into infrastructure"
        Write-Host "  that does not exist - the endpoints they need ARE the missing outputs."
        Write-Host ''
        Write-Host '  Deploy it first:' -ForegroundColor Yellow
        Write-Host "      gh workflow run infra-cd.yml -f environment=$Environment"
        Write-Host ''
        Write-Host "  ...or locally, from a host inside the runner's VNet:" -ForegroundColor Yellow
        Write-Host '      cd infra/terraform'
        Write-Host "      terraform init -reconfigure -backend-config=envs/$Environment/backend.hcl"
        Write-Host "      terraform apply -var-file=envs/$Environment/$Environment.tfvars"
        Write-Host ''

        throw "Environment '$Environment' is not deployed - see the instructions above."
    }

    if ($terraformExitCode -ne 0) {
        throw @"
terraform output failed. Initialise the backend for this environment first:

    cd infra/terraform
    terraform init -reconfigure -backend-config=envs/$Environment/backend.hcl

Raw error:
$outputJson
"@
    }

    $tf = $outputJson | ConvertFrom-Json
}
finally {
    Pop-Location
}

Write-Ok "Data Factory : $($tf.dataFactoryName)"
Write-Ok "Synapse      : $($tf.synapseWorkspaceName)"
Write-Ok "SQL server   : $($tf.sqlServerFqdn)"
Write-Ok "Storage      : $($tf.storageAccountName)"

# ---------------------------------------------------------------------------
# 2. The generated rows
#
# `path` is relative to the artifact's `properties` node - NOT the document
# root. So for {"name":"LS_X","properties":{"typeProperties":{"url":"..."}}}
# the path is `typeProperties.url`. Getting this wrong is silent: the tool
# reports the row as not-found rather than failing.
# ---------------------------------------------------------------------------

$adfRows = @(
    [pscustomobject]@{
        type  = 'linkedService'
        name  = 'LS_ADLS_Lake'
        path  = 'typeProperties.url'
        # Trailing slash removed: ADF stores the URL without one, and leaving
        # it produces a perpetual diff in the factory.
        value = $tf.lakeDfsEndpoint.TrimEnd('/')
    },
    [pscustomobject]@{
        type  = 'linkedService'
        name  = 'LS_Synapse_Serverless'
        path  = 'typeProperties.server'
        value = $tf.synapseServerlessEndpoint
    },
    [pscustomobject]@{
        type  = 'linkedService'
        name  = 'LS_Synapse_Serverless'
        path  = 'typeProperties.database'
        value = $tf.synapseServerlessDatabase
    },
    [pscustomobject]@{
        type  = 'linkedService'
        name  = 'LS_AzureSql_Edw'
        path  = 'typeProperties.server'
        value = $tf.sqlServerFqdn
    },
    [pscustomobject]@{
        type  = 'linkedService'
        name  = 'LS_AzureSql_Edw'
        path  = 'typeProperties.database'
        value = $tf.sqlDatabaseName
    },
    [pscustomobject]@{
        type  = 'linkedService'
        name  = 'LS_KeyVault'
        path  = 'typeProperties.baseUrl'
        # Key Vault DOES want the trailing slash. The two services genuinely
        # differ; this is not an oversight.
        value = $tf.keyVaultUri
    }
)

$synapseRows = @(
    [pscustomobject]@{
        type  = 'linkedService'
        name  = 'LS_ADLS_Lake'
        path  = 'typeProperties.url'
        value = $tf.lakeDfsEndpoint.TrimEnd('/')
    },
    [pscustomobject]@{
        type  = 'linkedService'
        name  = 'LS_KeyVault'
        path  = 'typeProperties.baseUrl'
        value = $tf.keyVaultUri
    }
)

# ---------------------------------------------------------------------------
# 3. Merge and write
# ---------------------------------------------------------------------------

function Merge-ConfigCsv {
    param(
        [string]   $Label,
        [string]   $CommittedPath,
        [string]   $GeneratedPath,
        [object[]] $GeneratedRows
    )

    if (-not (Test-Path $CommittedPath)) {
        throw "Expected committed config file not found: $CommittedPath"
    }

    $committed = @(Import-Csv -Path $CommittedPath)

    # Key on type+name+path. Generated wins.
    $generatedKeys = @{}
    foreach ($row in $GeneratedRows) {
        $generatedKeys["$($row.type)|$($row.name)|$($row.path)"] = $row.value
    }

    $conflicts = @()
    $kept      = @()

    foreach ($row in $committed) {
        $key = "$($row.type)|$($row.name)|$($row.path)"
        if ($generatedKeys.ContainsKey($key)) {
            if ($row.value -ne $generatedKeys[$key]) {
                $conflicts += [pscustomobject]@{
                    File      = Split-Path $CommittedPath -Leaf
                    Key       = $key
                    Committed = $row.value
                    Actual    = $generatedKeys[$key]
                }
            }
        }
        else {
            $kept += $row
        }
    }

    $merged = @($kept) + @($GeneratedRows)

    if ($Verify) {
        return $conflicts
    }

    $merged | Export-Csv -Path $GeneratedPath -NoTypeInformation -Encoding utf8
    Write-Ok "$Label -> $(Split-Path $GeneratedPath -Leaf) ($($kept.Count) decision row(s) + $($GeneratedRows.Count) generated row(s))"
    return @()
}

$adfDeployDir     = Join-Path $RepositoryRoot 'src' 'adf'     'deployment'
$synapseDeployDir = Join-Path $RepositoryRoot 'src' 'synapse' 'deployment'

Write-Step $(if ($Verify) { 'Verifying committed configuration against live infrastructure.' } else { 'Generating deployment configuration.' })

$allConflicts = @()

$allConflicts += Merge-ConfigCsv `
    -Label 'Data Factory' `
    -CommittedPath (Join-Path $adfDeployDir "config-$Environment.csv") `
    -GeneratedPath (Join-Path $adfDeployDir "config-$Environment.generated.csv") `
    -GeneratedRows $adfRows

$allConflicts += Merge-ConfigCsv `
    -Label 'Synapse' `
    -CommittedPath (Join-Path $synapseDeployDir "config-$Environment.csv") `
    -GeneratedPath (Join-Path $synapseDeployDir "config-$Environment.generated.csv") `
    -GeneratedRows $synapseRows

if ($Verify) {
    if ($allConflicts.Count -eq 0) {
        Write-Ok 'No hard-coded endpoints conflict with live infrastructure.'
        exit 0
    }

    Write-Host ''
    Write-Host 'Committed configuration disagrees with the deployed infrastructure:' -ForegroundColor Red
    $allConflicts | Format-Table -AutoSize | Out-String | Write-Host

    Write-Host @'
These rows are overridden at deploy time, so nothing is currently broken - but
a hard-coded endpoint in a committed CSV is a trap. Remove them: endpoints are
generated from Terraform outputs by this script and do not belong in
config-<env>.csv.
'@ -ForegroundColor Yellow
    exit 1
}

Write-Step 'Done.'
