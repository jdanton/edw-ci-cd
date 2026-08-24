#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys Synapse WORKSPACE artifacts from src/synapse/workspace using
    azure.synapse.tools.

.DESCRIPTION
    https://github.com/Azure-Player/azure.synapse.tools

    IMPORTANT - THIS IS HALF OF THE SYNAPSE DEPLOYMENT.

      This script    workspace ARTIFACTS: linked services, datasets, notebooks,
                     SQL script tabs, Synapse pipelines, triggers. They live in
                     the workspace artifact store and are reached through the
                     Dev API at <workspace>.dev.azuresynapse.net.

      Deploy-ServerlessSql.ps1
                     everything INSIDE the serverless database: the database
                     itself, schemas, external data sources, file formats,
                     views, procedures and grants. These are ordinary T-SQL
                     objects. No artifact API can create them.

    That distinction is the most common misconception about deploying Synapse.
    A "SQL script" artifact is a saved query TAB in Studio - deploying it does
    not execute anything. If you only run this script, the workspace will look
    correct in Studio and every pipeline will fail, because edw_lake does not
    exist.

    .github/workflows/synapse-cd.yml runs both, in order.

    NETWORK REQUIREMENT: the Dev endpoint is private. This script only works
    from a host whose VNet is linked to privatelink.dev.azuresynapse.net -
    i.e. your self-hosted runner. Run scripts/Test-PlatformConnectivity.ps1
    first if it hangs.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'prod')]
    [string] $Environment,

    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,

    # Newest azure.synapse.tools on the PowerShell Gallery. The module has
    # never published a 1.x, and a pin it cannot resolve fails as "No match
    # was found for the specified search criteria", not as a version error.
    [string] $ModuleVersion = '0.27.0',

    [switch] $SkipConfigGeneration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Tooling.ps1')   # PATH repair + Resolve-RequiredTool

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }

$workspaceRoot = Join-Path $RepositoryRoot 'src' 'synapse' 'workspace'
$deploymentDir = Join-Path $RepositoryRoot 'src' 'synapse' 'deployment'
$terraformDir  = Join-Path $RepositoryRoot 'infra' 'terraform'

# ---------------------------------------------------------------------------
# 1. Module
# ---------------------------------------------------------------------------

# Same Az dependency set as Deploy-DataFactory.ps1, for the same reason:
# azure.synapse.tools declares no RequiredModules, and its
# Deploy-SynapseObjectOnly calls New-AzResource from Az.Resources.
foreach ($module in @('Az.Accounts', 'Az.Resources', 'Az.Synapse')) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Step "Installing $module (required by azure.synapse.tools)."
        Install-Module -Name $module -Scope CurrentUser -Force -AllowClobber
    }
}
Write-Ok 'Az modules present: Az.Accounts, Az.Resources, Az.Synapse'

Write-Step "Ensuring azure.synapse.tools $ModuleVersion is available."

if (-not (Get-Module -ListAvailable -Name azure.synapse.tools |
          Where-Object { $_.Version -eq [version]$ModuleVersion })) {
    Install-Module -Name azure.synapse.tools `
                   -RequiredVersion $ModuleVersion `
                   -Scope CurrentUser -Force -AllowClobber
}

Import-Module azure.synapse.tools -RequiredVersion $ModuleVersion -Force
Write-Ok "Module loaded: $((Get-Module azure.synapse.tools).Version)"

# ---------------------------------------------------------------------------
# 2. Target
# ---------------------------------------------------------------------------

Write-Step "Reading target from Terraform state ($Environment)."

Push-Location $terraformDir
try {
    $tf = terraform output -json deployment_config | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'terraform output failed.' }
}
finally {
    Pop-Location
}

$workspaceName     = $tf.synapseWorkspaceName
$resourceGroupName = $tf.resourceGroupName
$location          = $tf.location

Write-Ok "Workspace      : $workspaceName"
Write-Ok "Resource group : $resourceGroupName"
Write-Ok "Dev endpoint   : $($tf.synapseDevEndpoint)"

# ---------------------------------------------------------------------------
# 3. Configuration
# ---------------------------------------------------------------------------

if (-not $SkipConfigGeneration) {
    Write-Step 'Generating deployment configuration from Terraform outputs.'
    & (Join-Path $PSScriptRoot 'New-DeploymentConfig.ps1') -Environment $Environment -RepositoryRoot $RepositoryRoot
}

$configPath = Join-Path $deploymentDir "config-$Environment.generated.csv"
if (-not (Test-Path $configPath)) {
    throw "Generated config not found at $configPath."
}

# ---------------------------------------------------------------------------
# 4. Publish options
# ---------------------------------------------------------------------------

Write-Step 'Building publish options.'

$optionsJson = Get-Content (Join-Path $deploymentDir 'publish-options.json') -Raw | ConvertFrom-Json

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

$opt = New-SynapsePublishOption

foreach ($pattern in $effective['excludes']) { $opt.Excludes.Add($pattern, '') }
foreach ($pattern in $effective['includes']) { $opt.Includes.Add($pattern, '') }

# Same translation guard as Deploy-DataFactory.ps1: the option object is a
# PowerShell class, so assigning a property the installed version does not
# define throws an error naming the module's property and nothing else.
$optionMap = [ordered]@{
    deleteNotInSource = 'DeleteNotInSource'
    stopStartTriggers = 'StopStartTriggers'
    createNewInstance = 'CreateNewInstance'
}

$supported = ($opt | Get-Member -MemberType Property).Name

foreach ($key in $optionMap.Keys) {
    if (-not $effective.ContainsKey($key)) { continue }
    $property = $optionMap[$key]
    if ($supported -notcontains $property) {
        throw ("azure.synapse.tools $ModuleVersion has no publish option " +
               "'$property' (from '$key' in publish-options.json). It accepts: " +
               ($supported -join ', ') + '.')
    }
    $opt.$property = [bool]$effective[$key]
}

$known    = @('excludes', 'includes') + [string[]]$optionMap.Keys
$unmapped = $effective.Keys | Where-Object { $_ -notin $known }
if ($unmapped) {
    throw ("publish-options.json sets option(s) this script does not translate: " +
           ($unmapped -join ', ') + '. Known keys: ' + ($known -join ', ') + '.')
}

if ($opt.PSObject.Properties.Name -contains 'FailsWhenConfigItemNotFound') {
    $opt.FailsWhenConfigItemNotFound = $true
}
if ($opt.PSObject.Properties.Name -contains 'FailsWhenPathNotFound') {
    $opt.FailsWhenPathNotFound = $true
}

Write-Ok "deleteNotInSource=$($opt.DeleteNotInSource)  stopStartTriggers=$($opt.StopStartTriggers)"

# ---------------------------------------------------------------------------
# 5. Publish
#
# The workspace-name parameter has been called both -WorkspaceName and
# -SynapseWorkspaceName across versions of the module. Rather than pinning this
# script to one spelling and breaking on upgrade, discover which the installed
# version accepts.
# ---------------------------------------------------------------------------

$command = Get-Command Publish-SynapseFromJson
$workspaceParameterName =
    if ($command.Parameters.ContainsKey('SynapseWorkspaceName')) { 'SynapseWorkspaceName' }
    elseif ($command.Parameters.ContainsKey('WorkspaceName'))    { 'WorkspaceName' }
    else { throw "Publish-SynapseFromJson (v$ModuleVersion) exposes neither -SynapseWorkspaceName nor -WorkspaceName. Inspect it with: Get-Command Publish-SynapseFromJson -Syntax" }

Write-Ok "Using -$workspaceParameterName"

$artifactCount = (Get-ChildItem -Path $workspaceRoot -Filter *.json -Recurse -ErrorAction SilentlyContinue).Count
Write-Step "Publishing $artifactCount workspace artifact(s) to $workspaceName."

# ---------------------------------------------------------------------------
# Method: 'AzSynapse', NOT the module's 'AzResource' default.
#
# The two methods write to different planes:
#
#   AzResource (default)  New-AzResource against
#                         Microsoft.Synapse/workspaces/linkedservices - the ARM
#                         control plane, which relays the artifact to the
#                         workspace's own endpoint.
#   AzSynapse             Set-AzSynapseLinkedService -DefinitionFile, straight
#                         at <workspace>.dev.azuresynapse.net.
#
# This platform's workspace has public network access disabled, and the whole
# runner-connectivity setup exists to reach that Dev endpoint privately - the
# privatelink.dev.azuresynapse.net zone in docs/04-networking.md is there for
# exactly this call. The ARM route is the one plane the private link does not
# cover, and it fails with a bare correlation id and no message:
#
#   New-AzResource: .../Deploy-SynapseObjectOnly.ps1:169
#        | CorrelationId: 069f9a98-763e-4763-ae16-92cac9283c48
#
# sqlscripts, notebooks and Spark job definitions always go over the Dev REST
# API whatever this is set to; the module says so in a warning.
# ---------------------------------------------------------------------------

$publishParams = @{
    RootFolder             = $workspaceRoot
    ResourceGroupName      = $resourceGroupName
    $workspaceParameterName = $workspaceName
    Location               = $location
    Stage                  = $configPath
    Option                 = $opt
    Method                 = 'AzSynapse'
}

if (-not $PSCmdlet.ShouldProcess($workspaceName, 'Publish Synapse artifacts')) {
    Write-Host 'WHATIF - not publishing.' -ForegroundColor Yellow
    exit 0
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
Publish-SynapseFromJson @publishParams
$stopwatch.Stop()

Write-Ok "Published in $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s."

if ($env:GITHUB_STEP_SUMMARY) {
    @"
## Synapse workspace artifacts - ``$Environment``

| | |
|---|---|
| Workspace | ``$workspaceName`` |
| artifacts | $artifactCount |
| Duration | $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s |

> This deployed workspace artifacts only. The serverless SQL objects
> (``edw_lake``, external data sources, views, procedures) are deployed
> separately by ``Deploy-ServerlessSql.ps1``.
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}

Write-Step 'Synapse artifact deployment complete. Serverless SQL objects are deployed separately.'
