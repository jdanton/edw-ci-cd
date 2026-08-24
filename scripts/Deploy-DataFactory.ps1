#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the ADF artifacts in src/adf to a target factory using
    azure.datafactory.tools.

.DESCRIPTION
    https://github.com/Azure-Player/azure.datafactory.tools

    What this script does that a bare Publish-AdfV2FromJson call does not:

      * Regenerates config-<env>.generated.csv from Terraform outputs first, so
        endpoints can never be stale.
      * Translates src/adf/deployment/publish-options.json into the module's
        option object, keeping our configuration in one reviewable file rather
        than spread across three workflow YAMLs.
      * Excludes integrationRuntime and managedVirtualNetwork, which Terraform
        owns. Without that exclusion Terraform and this deployment flip-flop the
        integration runtime on alternate runs.
      * Emits a GitHub Actions job summary of what was deployed.

.PARAMETER Environment
    dev, test or prod. Also the -Stage value, which selects the config CSV.

.PARAMETER WhatIf
    Runs the module's dry-run mode: it reports what it WOULD do without
    touching the factory. Worth doing before the first prod deployment.

.NOTES
    Authentication is the ambient Az PowerShell context. In GitHub Actions that
    means azure/login@v2 with `enable-AzPSSession: true` - without that flag the
    action authenticates the Azure CLI only, and this script fails with
    "Run Connect-AzAccount to login".
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'prod')]
    [string] $Environment,

    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,

    [string] $ModuleVersion = '1.11.0',

    [switch] $SkipConfigGeneration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Tooling.ps1')   # PATH repair + Resolve-RequiredTool

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }

$adfRoot      = Join-Path $RepositoryRoot 'src' 'adf'
$deploymentDir = Join-Path $adfRoot 'deployment'
$terraformDir = Join-Path $RepositoryRoot 'infra' 'terraform'

# ---------------------------------------------------------------------------
# 1. Module
# ---------------------------------------------------------------------------

Write-Step "Ensuring azure.datafactory.tools $ModuleVersion is available."

if (-not (Get-Module -ListAvailable -Name azure.datafactory.tools |
          Where-Object { $_.Version -eq [version]$ModuleVersion })) {
    Install-Module -Name azure.datafactory.tools `
                   -RequiredVersion $ModuleVersion `
                   -Scope CurrentUser -Force -AllowClobber
}

Import-Module azure.datafactory.tools -RequiredVersion $ModuleVersion -Force
Write-Ok "Module loaded: $((Get-Module azure.datafactory.tools).Version)"

# The Az modules the publish path actually reaches for. azure.datafactory.tools
# declares no RequiredModules, so a missing one surfaces as a bare "The term
# 'X' is not recognized" from inside the module, mid-deployment, with the
# triggers already stopped:
#
#   Az.Resources   New-AzResource. The default publish Method is 'AzResource',
#                  so every artifact goes through it.
#   Az.DataFactory Get-/Remove-AzDataFactoryV2*, used to read the live factory
#                  for deleteNotInSource and to stop and start triggers.
#   Az.Accounts    the authenticated context both of the above run in.
#
# Az.Storage is NOT needed: the module only touches it for incremental
# deployment state, which this template does not enable.
foreach ($module in @('Az.Accounts', 'Az.Resources', 'Az.DataFactory')) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Step "Installing $module (required by azure.datafactory.tools)."
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
    }
}
Write-Ok 'Az modules present: Az.Accounts, Az.Resources, Az.DataFactory'

# ---------------------------------------------------------------------------
# 2. Target, from Terraform
# ---------------------------------------------------------------------------

Write-Step "Reading target from Terraform state ($Environment)."

Push-Location $terraformDir
try {
    $tf = terraform output -json deployment_config | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'terraform output failed. Has the backend been initialised for this environment?' }
}
finally {
    Pop-Location
}

$dataFactoryName   = $tf.dataFactoryName
$resourceGroupName = $tf.resourceGroupName
$location          = $tf.location

Write-Ok "Factory        : $dataFactoryName"
Write-Ok "Resource group : $resourceGroupName"
Write-Ok "Location       : $location"

# ---------------------------------------------------------------------------
# 3. Configuration
# ---------------------------------------------------------------------------

if (-not $SkipConfigGeneration) {
    Write-Step 'Generating deployment configuration from Terraform outputs.'
    & (Join-Path $PSScriptRoot 'New-DeploymentConfig.ps1') -Environment $Environment -RepositoryRoot $RepositoryRoot
    if ($LASTEXITCODE -ne 0) { throw 'New-DeploymentConfig.ps1 failed.' }
}

$configPath = Join-Path $deploymentDir "config-$Environment.generated.csv"
if (-not (Test-Path $configPath)) {
    throw "Generated config not found at $configPath. Run New-DeploymentConfig.ps1 -Environment $Environment first, or drop -SkipConfigGeneration."
}

Write-Ok "Config: $configPath ($((Import-Csv $configPath).Count) replacement rows)"

# ---------------------------------------------------------------------------
# 4. Publish options
#
# Translated from OUR json schema into the module's option object. The
# indirection is deliberate: an upstream property rename becomes a one-line fix
# here instead of an edit to three workflow files.
# ---------------------------------------------------------------------------

Write-Step 'Building publish options.'

$optionsFile = Join-Path $deploymentDir 'publish-options.json'
$optionsJson = Get-Content $optionsFile -Raw | ConvertFrom-Json

# Merge default <- environment override.
$effective = @{}
foreach ($property in $optionsJson.default.PSObject.Properties) {
    if ($property.Name -like '$*') { continue }
    $effective[$property.Name] = $property.Value
}
if ($optionsJson.environments.PSObject.Properties.Name -contains $Environment) {
    foreach ($property in $optionsJson.environments.$Environment.PSObject.Properties) {
        if ($property.Name -like '$*') { continue }
        $effective[$property.Name] = $property.Value
    }
}

$opt = New-AdfPublishOption

foreach ($pattern in $effective['excludes']) {
    $opt.Excludes.Add($pattern, '')
    Write-Host "    exclude: $pattern"
}
foreach ($pattern in $effective['includes']) {
    $opt.Includes.Add($pattern, '')
    Write-Host "    include: $pattern"
}

# AdfPublishOption is a PowerShell CLASS, not a PSCustomObject, so assigning a
# property it does not define throws "The property 'X' cannot be found on this
# object" - naming the module's property, never our key, and not listing what
# the module does accept. Map explicitly and check before assigning, so an
# option the installed version dropped or renamed says so in one line.
$optionMap = [ordered]@{
    deleteNotInSource  = 'DeleteNotInSource'
    stopStartTriggers  = 'StopStartTriggers'
    createNewInstance  = 'CreateNewInstance'
    deployGlobalParams = 'DeployGlobalParams'
}

$supported = ($opt | Get-Member -MemberType Property).Name

foreach ($key in $optionMap.Keys) {
    if (-not $effective.ContainsKey($key)) { continue }
    $property = $optionMap[$key]
    if ($supported -notcontains $property) {
        throw ("azure.datafactory.tools $ModuleVersion has no publish option " +
               "'$property' (from '$key' in publish-options.json). It accepts: " +
               ($supported -join ', ') + '.')
    }
    $opt.$property = [bool]$effective[$key]
}

# A key nothing maps is a key that does nothing. Fail rather than let a publish
# option sit in the file for a year looking like it is in force.
$known    = @('excludes', 'includes') + [string[]]$optionMap.Keys
$unmapped = $effective.Keys | Where-Object { $_ -notin $known }
if ($unmapped) {
    throw ("publish-options.json sets option(s) this script does not translate: " +
           ($unmapped -join ', ') + '. Known keys: ' + ($known -join ', ') + '.')
}

# Fail loudly when the config CSV names an artifact or property that does not
# exist. The module's default is to warn and continue, which means a typo in a
# path silently leaves the DEV endpoint in the PROD factory.
$opt.FailsWhenConfigItemNotFound = $true
$opt.FailsWhenPathNotFound       = $true

Write-Ok "deleteNotInSource=$($opt.DeleteNotInSource)  stopStartTriggers=$($opt.StopStartTriggers)"

# ---------------------------------------------------------------------------
# 5. Publish
# ---------------------------------------------------------------------------

$artifactCount = (Get-ChildItem -Path $adfRoot -Filter *.json -Recurse |
                  Where-Object { $_.FullName -notlike "*$([IO.Path]::DirectorySeparatorChar)deployment$([IO.Path]::DirectorySeparatorChar)*" }).Count

Write-Step "Publishing $artifactCount artifact(s) to $dataFactoryName."

$publishParams = @{
    RootFolder        = $adfRoot
    ResourceGroupName = $resourceGroupName
    DataFactoryName   = $dataFactoryName
    Location          = $location
    Stage             = $configPath
    Option            = $opt
}

if (-not $PSCmdlet.ShouldProcess($dataFactoryName, 'Publish ADF artifacts')) {
    Write-Host ''
    Write-Host 'WHATIF - not publishing. Would have run:' -ForegroundColor Yellow
    $publishParams.GetEnumerator() |
        Where-Object { $_.Key -ne 'Option' } |
        ForEach-Object { Write-Host "    -$($_.Key) $($_.Value)" -ForegroundColor Yellow }
    exit 0
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Publish-AdfV2FromJson @publishParams
$stopwatch.Stop()

Write-Ok "Published in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s."

# ---------------------------------------------------------------------------
# 6. Job summary
# ---------------------------------------------------------------------------

if ($env:GITHUB_STEP_SUMMARY) {
    $triggerRows = Import-Csv $configPath | Where-Object { $_.type -eq 'trigger' -and $_.path -eq 'runtimeState' }

    $summary = @"
## Data Factory deployment - ``$Environment``

| | |
|---|---|
| Factory | ``$dataFactoryName`` |
| Resource group | ``$resourceGroupName`` |
| artifacts | $artifactCount |
| Duration | $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s |
| Delete not in source | ``$($opt.DeleteNotInSource)`` |

### Trigger state after this deployment

| Trigger | State |
|---|---|
$(($triggerRows | ForEach-Object { "| ``$($_.name)`` | $($_.value) |" }) -join "`n")

> Triggers are stopped before publishing and restarted afterwards - ADF refuses
> to modify a pipeline referenced by a running trigger.
"@
    $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

Write-Step 'Data Factory deployment complete.'
