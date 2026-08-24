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

    # 1.16.0 is the floor, not a preference: earlier versions build the ARM
    # Authorization header by hand from Get-AzAccessToken, which breaks twice
    # over on a modern runner - Az.Accounts 5.x returns the token as a
    # SecureString, and the hand-rolled path cannot use a federated (OIDC)
    # credential at all. 1.16.0 replaced it with Invoke-AzRestMethod. 1.18.0 is
    # the current release and is API-compatible with everything used here.
    [string] $ModuleVersion = '1.18.0',

    [switch] $SkipConfigGeneration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Tooling.ps1')   # PATH repair + Resolve-RequiredTool

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    !! $m" -ForegroundColor Yellow }

$adfRoot      = Join-Path $RepositoryRoot 'src' 'adf'
$deploymentDir = Join-Path $adfRoot 'deployment'
$terraformDir = Join-Path $RepositoryRoot 'infra' 'terraform'

# ---------------------------------------------------------------------------
# 1. Module
# ---------------------------------------------------------------------------

# The Az modules the publish path reaches for. Installed BEFORE
# azure.datafactory.tools is imported: from its 1.12.0 the import itself expects
# Az.Resources and Az.DataFactory. The module still declares no RequiredModules,
# so a missing one otherwise surfaces as a bare "The term 'X' is not recognized"
# from inside the module, mid-deployment, with the triggers already stopped:
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

Write-Step "Ensuring azure.datafactory.tools $ModuleVersion is available."

if (-not (Get-Module -ListAvailable -Name azure.datafactory.tools |
          Where-Object { $_.Version -eq [version]$ModuleVersion })) {
    Install-Module -Name azure.datafactory.tools `
                   -RequiredVersion $ModuleVersion `
                   -Scope CurrentUser -Force -AllowClobber
}

Import-Module azure.datafactory.tools -RequiredVersion $ModuleVersion -Force
Write-Ok "Module loaded: $((Get-Module azure.datafactory.tools).Version)"

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
# stopStartTriggers is not merely recommended - refuse to run without it.
#
# ADF will not modify a pipeline that a STARTED trigger references. With this
# off, a deployment does not fail cleanly: it publishes the artifacts it can
# and fails on the ones a running trigger holds, leaving the factory half
# updated. That is the worst of the three possible outcomes.
#
# publish-options.json documents it as mandatory; this makes it so, rather
# than trusting that nobody edits the environment block.
# ---------------------------------------------------------------------------
if (-not $opt.StopStartTriggers) {
    throw @"
stopStartTriggers is false for environment '$Environment'.

ADF refuses to modify a pipeline referenced by a running trigger, so this
setting leaves the factory half-published rather than failing cleanly.

Set it back to true in src/adf/deployment/publish-options.json. If you are
deliberately deploying to a factory with no triggers at all, delete the
trigger artifacts instead of disabling this.
"@
}

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

# ---------------------------------------------------------------------------
# Which triggers is this environment supposed to leave RUNNING?
#
# The config CSV is the declaration - a `trigger,<name>,runtimeState,Started`
# row. Captured BEFORE publishing because it is also what we restore from if
# the publish dies half way through.
# ---------------------------------------------------------------------------
$declaredStarted = @(
    Import-Csv $configPath |
        Where-Object { $_.type -eq 'trigger' -and $_.path -eq 'runtimeState' -and $_.value -eq 'Started' } |
        ForEach-Object { $_.name }
)

function Expand-DeclaredTriggerName {
    param(
        [string[]] $Names,
        [string[]] $Candidates
    )

    $expanded = foreach ($name in $Names) {
        if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($name)) {
            $Candidates | Where-Object { $_ -like $name }
        }
        else {
            $name
        }
    }

    return @($expanded | Sort-Object -Unique)
}

$sourceTriggerNames = @(
    Get-ChildItem -Path (Join-Path $adfRoot 'trigger') -Filter *.json -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName }
)

$liveTriggerNames = @()
try {
    $liveTriggerNames = @(
        Get-AzDataFactoryV2Trigger -ResourceGroupName $resourceGroupName `
            -DataFactoryName $dataFactoryName -ErrorAction Stop |
            ForEach-Object { $_.Name }
    )
}
catch {
    Write-Warn "Could not read live triggers for wildcard expansion: $($_.Exception.Message)"
}

$triggerNameCandidates = @(
    @($sourceTriggerNames + $liveTriggerNames) |
        Where-Object { $_ } |
        Sort-Object -Unique
)

$shouldBeStarted = Expand-DeclaredTriggerName -Names $declaredStarted -Candidates $triggerNameCandidates

function Start-DeclaredTrigger {
    <#
        Restart every trigger this environment declares as Started, reporting
        each one. Used on the failure path, where the module has already
        stopped them and will not get to its own restart step.
    #>
    param([string[]] $Names)

    $failed = @()
    foreach ($name in $Names) {
        try {
            Start-AzDataFactoryV2Trigger -ResourceGroupName $resourceGroupName `
                -DataFactoryName $dataFactoryName -Name $name -Force -ErrorAction Stop | Out-Null
            Write-Ok "restarted trigger $name"
        }
        catch {
            Write-Warn "could NOT restart trigger ${name}: $($_.Exception.Message)"
            $failed += $name
        }
    }
    return , $failed
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# ---------------------------------------------------------------------------
# The publish is wrapped because of what StopStartTriggers does on failure:
# NOTHING. The module stops every trigger, publishes, then restarts them. If
# the publish throws in between - a bad config path, a transient 429, an
# artifact referencing a linked service that does not exist yet - it never
# reaches the restart, and the triggers stay STOPPED.
#
# That failure is silent and expensive. The workflow goes red, somebody fixes
# the artifact and redeploys tomorrow, and in between the platform quietly
# ingests nothing. Nobody is paged, because nothing errored - the schedule
# simply never fired.
#
# So: on failure, put the triggers back the way the environment declares them,
# THEN rethrow. The deployment still fails, loudly and with its original
# error; it just does not leave ingestion switched off behind it.
# ---------------------------------------------------------------------------
try {
    Publish-AdfV2FromJson @publishParams
}
catch {
    $publishError = $_
    Write-Host ''
    Write-Warn 'Publish FAILED. Restoring trigger state before exiting.'

    if ($shouldBeStarted.Count -gt 0) {
        $couldNotStart = Start-DeclaredTrigger -Names $shouldBeStarted
        if ($couldNotStart.Count -gt 0) {
            Write-Host ''
            Write-Host 'THESE TRIGGERS ARE STILL STOPPED AND MUST BE STARTED BY HAND:' -ForegroundColor Red
            $couldNotStart | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
            Write-Host '  az datafactory trigger start --factory-name' $dataFactoryName '-g' $resourceGroupName '--name <trigger>' -ForegroundColor Yellow
        }
    }
    else {
        Write-Ok 'No triggers are declared Started in this environment - nothing to restore.'
    }

    throw $publishError
}

$stopwatch.Stop()

Write-Ok "Published in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s."

# ---------------------------------------------------------------------------
# 6. Job summary
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Verify the triggers actually came back up.
#
# This used to report the CSV - that is the INTENT, not the outcome, so the
# summary said "Started" whether or not anything was running. The whole point
# of the table is to answer "is ingestion on?", so it has to ask Azure.
# ---------------------------------------------------------------------------
Write-Step 'Verifying trigger state.'

$triggerState = @()
$notRunning   = @()
$mismatches   = @()
try {
    $liveTriggers = Get-AzDataFactoryV2Trigger -ResourceGroupName $resourceGroupName `
        -DataFactoryName $dataFactoryName -ErrorAction Stop

    foreach ($trigger in $liveTriggers) {
        $expected = if ($shouldBeStarted -contains $trigger.Name) { 'Started' } else { 'Stopped' }
        $actual   = $trigger.RuntimeState

        $triggerState += [pscustomobject]@{
            Name = $trigger.Name; Expected = $expected; Actual = $actual
            Ok   = ($expected -eq $actual)
        }

        if ($expected -ne $actual) {
            $mismatches += $trigger.Name

            if ($expected -eq 'Started') {
                $notRunning += $trigger.Name
            }

            Write-Warn "$($trigger.Name) should be $expected but is $actual"
        }
        else {
            Write-Ok "$($trigger.Name): $actual"
        }
    }
}
catch {
    Write-Warn "Could not read trigger state: $($_.Exception.Message)"
}

if ($notRunning.Count -gt 0) {
    Write-Host ''
    Write-Host 'A trigger that should be running is not. Ingestion is OFF for it.' -ForegroundColor Red
    $notRunning | ForEach-Object {
        Write-Host "  az datafactory trigger start --factory-name $dataFactoryName -g $resourceGroupName --name $_" -ForegroundColor Yellow
    }
}

if ($env:GITHUB_STEP_SUMMARY) {
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

Read from Azure, not from the config - this is what is actually running.

| Trigger | Expected | Actual | |
|---|---|---|---|
$(if ($triggerState.Count -gt 0) {
    ($triggerState | ForEach-Object {
        "| ``$($_.Name)`` | $($_.Expected) | $($_.Actual) | $(if ($_.Ok) { 'OK' } else { '**MISMATCH**' }) |"
    }) -join "`n"
} else {
    "| _trigger state could not be read_ | | | |"
})
$(if ($notRunning.Count -gt 0) {
"`n> **A trigger that should be running is stopped, so ingestion is OFF for it.**`n> Start it with:`n> ``````
> az datafactory trigger start --factory-name $dataFactoryName -g $resourceGroupName --name <trigger>
> ``````"
})

> Triggers are stopped before publishing and restarted afterwards - ADF refuses
> to modify a pipeline referenced by a running trigger. If the publish fails in
> between, this script restarts them before rethrowing, so a failed deployment
> does not leave ingestion silently switched off.
"@
    $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

if ($mismatches.Count -gt 0) {
    throw "Trigger verification failed for $($mismatches.Count) trigger(s). See summary for mismatches."
}

Write-Step 'Data Factory deployment complete.'
