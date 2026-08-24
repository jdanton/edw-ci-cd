#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the Synapse serverless SQL objects in src/synapse/serverless to the
    workspace's built-in serverless pool.

.DESCRIPTION
    Creates the edw_lake database and everything inside it: the master key and
    managed-identity credential, external data sources and file formats,
    schemas, raw and curated views, the CETAS build procedures, and the grants
    for the Data Factory managed identity.

    THIS IS THE OTHER HALF OF THE SYNAPSE DEPLOYMENT. Deploy-Synapse.ps1
    publishes workspace artifacts through the Dev REST API; none of the objects
    below are artifacts, so no artifact API can create them. They are ordinary
    T-SQL and need a TDS connection.

    Scripts run in filename order. Every one is idempotent - CREATE OR ALTER,
    or a guarded IF NOT EXISTS - so a re-run is a no-op and a partial failure is
    repaired by simply running it again.

    AUTHENTICATION
      An Entra access token for https://database.windows.net/, obtained from the
      ambient az context. The deployment service principal is a member of the
      Synapse admin Entra group (bootstrap/main.tf), which is the workspace's
      SQL Entra administrator - so the token grants sysadmin on the serverless
      endpoint with no password anywhere.

    NETWORK
      The serverless endpoint is private. Run
      scripts/Test-PlatformConnectivity.ps1 first if this hangs; a hang is
      almost always privatelink.sql.azuresynapse.net not being linked to the
      runner's VNet, which produces a public IP and a silent timeout.

.PARAMETER Environment
    dev, test or prod.

.PARAMETER WhatIf
    Print the resolved SQLCMD variables and the script order without connecting.
#>
[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ConnectionTimeoutSeconds',
    Justification = 'Used inside the scriptblock handed to Invoke-SqlWithRetry. The analyzer does not follow parameters into a scriptblock argument, so it reports them unused.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'QueryTimeoutSeconds',
    Justification = 'Used inside the scriptblock handed to Invoke-SqlWithRetry. The analyzer does not follow parameters into a scriptblock argument, so it reports them unused.')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'prod')]
    [string] $Environment,

    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,

    [int] $ConnectionTimeoutSeconds = 60,
    [int] $QueryTimeoutSeconds      = 1800,

    # Serverless SQL has no always-on compute. The first statement after the
    # built-in pool has been idle is answered with "The SQL pool is warming up.
    # Please try again." - an instruction, not a failure, and the pool is ready
    # within a minute or two. Five attempts backing off 15/30/45/60/60s covers
    # it with room to spare.
    [int] $WarmupRetryCount = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Tooling.ps1')   # PATH repair + Resolve-RequiredTool

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    !! $m" -ForegroundColor Yellow }

$serverlessDir = Join-Path $RepositoryRoot 'src' 'synapse' 'serverless'
$terraformDir  = Join-Path $RepositoryRoot 'infra' 'terraform'

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------

Write-Step 'Checking prerequisites.'

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Write-Host '    Installing the SqlServer module...'
    Install-Module -Name SqlServer -Scope CurrentUser -Force -AllowClobber -MinimumVersion 22.0.0
}
Import-Module SqlServer -Force
Write-Ok "SqlServer module $((Get-Module SqlServer).Version)"

# ---------------------------------------------------------------------------
# 2. Context from Terraform
# ---------------------------------------------------------------------------

Write-Step "Reading serverless deployment context ($Environment)."

Push-Location $terraformDir
try {
    $ctx = terraform output -json serverless_deployment_context | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'terraform output failed.' }
}
finally {
    Pop-Location
}

$serverInstance = $ctx.serverlessEndpoint
$databaseName   = $ctx.databaseName

Write-Ok "Endpoint  : $serverInstance"
Write-Ok "Database  : $databaseName"
Write-Ok "Raw       : $($ctx.rawLocation)"
Write-Ok "Curated   : $($ctx.curatedLocation)"
Write-Ok "ADF MI    : $($ctx.dataFactoryName)"

# ---------------------------------------------------------------------------
# 3. SQLCMD variables
#
# The master key password is generated fresh on every run and never stored.
# That is safe because it protects nothing: a DATABASE SCOPED CREDENTIAL with
# IDENTITY = 'Managed Identity' holds no secret material, SQL simply insists on
# an encrypted credential. 020_security.sql only creates the key if one does
# not already exist, so a regenerated password is never applied to an existing
# key. Storing this in Key Vault would create one more thing to rotate in
# exchange for nothing.
# ---------------------------------------------------------------------------

$masterKeyPassword = -join ((65..90) + (97..122) + (48..57) + (33, 35, 37, 42, 45, 95) |
                            Get-Random -Count 48 |
                            ForEach-Object { [char]$_ })

$sqlcmdVariables = @(
    "DatabaseName=$databaseName"
    "MasterKeyPassword=$masterKeyPassword"
    "RawLocation=$($ctx.rawLocation)"
    "CuratedLocation=$($ctx.curatedLocation)"
    "SandboxLocation=$($ctx.sandboxLocation)"
    "DataFactoryName=$($ctx.dataFactoryName)"
    "SynapseAdminGroup=$($ctx.synapseAdminGroup)"
    "EnvironmentName=$Environment"
)

# ---------------------------------------------------------------------------
# 4. Script order
#
# Numeric filename prefixes ARE the dependency graph. Do not reorder:
#   010 database        must exist before anything connects to it
#   020 security        the credential the data sources reference
#   030 data sources    the locations the views read
#   040 formats/schemas the namespaces the views live in
#   060 raw views       what the curate procedure reads
#   070 procedures      what ADF calls
#   080 curated views   read the CETAS output the procedure writes
#   090 permissions     granted on objects that must already exist
# ---------------------------------------------------------------------------

$scripts = Get-ChildItem -Path $serverlessDir -Filter '*.sql' -File |
           Sort-Object Name

if ($scripts.Count -eq 0) {
    throw "No .sql files found in $serverlessDir."
}

Write-Step "Found $($scripts.Count) script(s):"
$scripts | ForEach-Object { Write-Host "    $($_.Name)" }

if (-not $PSCmdlet.ShouldProcess($serverInstance, "Deploy $($scripts.Count) serverless SQL scripts")) {
    Write-Host ''
    Write-Host 'WHATIF - resolved SQLCMD variables (secrets redacted):' -ForegroundColor Yellow
    $sqlcmdVariables |
        ForEach-Object { if ($_ -like 'MasterKeyPassword=*') { 'MasterKeyPassword=<generated>' } else { $_ } } |
        ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    exit 0
}

# ---------------------------------------------------------------------------
# 5. Token
# ---------------------------------------------------------------------------

Write-Step 'Acquiring an Entra access token for the SQL data plane.'

$tokenJson = az account get-access-token --resource 'https://database.windows.net/' --output json 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tokenJson)) {
    throw 'Could not acquire an access token. Run azure/login@v2 (CI) or az login (local) first.'
}
$accessToken = ($tokenJson | ConvertFrom-Json).accessToken
Write-Ok 'Token acquired.'

# ---------------------------------------------------------------------------
# 6. Run
#
# 010_database.sql runs against master (it creates the database); everything
# else runs against edw_lake. The scripts also contain USE statements, which
# serverless honours - the explicit -Database here is belt and braces, and
# makes the intent obvious to a reader.
# ---------------------------------------------------------------------------

$failed = @()

foreach ($script in $scripts) {
    $targetDatabase = if ($script.Name -like '010_*') { 'master' } else { $databaseName }

    Write-Step "$($script.Name)  ->  [$targetDatabase]"

    try {
        # Retry classification lives in _Tooling.ps1 so that this script, the
        # login grant, the reference-data load and the workflows all agree on
        # what "transient" means.
        $output = Invoke-SqlWithRetry -Activity $script.Name -MaxAttempts $WarmupRetryCount -ScriptBlock {
            Invoke-Sqlcmd `
                -ServerInstance    $serverInstance `
                -Database          $targetDatabase `
                -AccessToken       $accessToken `
                -InputFile         $script.FullName `
                -Variable          $sqlcmdVariables `
                -QueryTimeout      $QueryTimeoutSeconds `
                -ConnectionTimeout $ConnectionTimeoutSeconds `
                -AbortOnError `
                -Verbose 4>&1
        }

            # PRINT output arrives on the verbose stream. Surfacing it is what makes
            # the deployment log actually useful - the scripts print row counts,
            # principal lists and collation warnings.
            $output | ForEach-Object {
                $line = "$_".Trim()
                if ($line) { Write-Host "    | $line" -ForegroundColor DarkGray }
            }

        Write-Ok "$($script.Name) OK"
    }
    catch {
            $message = $_.Exception.Message

            Write-Host "    XX $($script.Name) FAILED" -ForegroundColor Red
            Write-Host "       $message" -ForegroundColor Red

            # Translate the failures whose native message points at the wrong thing.
            if ($message -match 'not associated with a trusted SQL Server connection|Login failed') {
                Write-Warn 'The token was rejected. Check that the deployment service principal is a member of the Synapse admin Entra group (bootstrap output synapse_admin_group_names).'
            }
            elseif ($message -match 'timeout|network-related') {
                Write-Warn 'This is almost certainly DNS, not SQL. Run scripts/Test-PlatformConnectivity.ps1 - if the endpoint resolves to a public IP, privatelink.sql.azuresynapse.net is not linked to this host''s VNet.'
            }
            elseif ($message -match 'content of directory cannot be listed|External table is not accessible') {
                Write-Warn 'Storage RBAC, not SQL. The Synapse workspace managed identity needs Storage Blob Data Contributor on the lake - see infra/terraform/rbac.tf, synapse_lake_contributor.'
            }

            $failed += $script.Name
    }

    # Order is a dependency graph; continuing past a failure is noise.
    if ($failed.Count -gt 0) { break }
}

# ---------------------------------------------------------------------------
# 7. Verify
# ---------------------------------------------------------------------------

if ($failed.Count -eq 0) {
    Write-Step 'Verifying deployed objects.'

    $verifyQuery = @'
SELECT ObjectType = 'External data source', ObjectName = name FROM sys.external_data_sources
UNION ALL
SELECT 'External file format', name FROM sys.external_file_formats
UNION ALL
SELECT 'View', CONCAT(SCHEMA_NAME(schema_id), '.', name) FROM sys.views
UNION ALL
SELECT 'Procedure', CONCAT(SCHEMA_NAME(schema_id), '.', name) FROM sys.procedures
ORDER BY ObjectType, ObjectName;
'@

    $objects = Invoke-Sqlcmd `
        -ServerInstance $serverInstance `
        -Database       $databaseName `
        -AccessToken    $accessToken `
        -Query          $verifyQuery `
        -QueryTimeout   120

    $objects | Format-Table -AutoSize | Out-String | Write-Host

    if ($env:GITHUB_STEP_SUMMARY) {
        @"
## Synapse serverless SQL - ``$Environment``

| | |
|---|---|
| Endpoint | ``$serverInstance`` |
| Database | ``$databaseName`` |
| Scripts run | $($scripts.Count) |
| Objects | $($objects.Count) |

$(($objects | Group-Object ObjectType | ForEach-Object { "- **$($_.Name)**: $($_.Count)" }) -join "`n")
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }

    Write-Step 'Serverless SQL deployment complete.'
    exit 0
}

Write-Host ''
Write-Host "Deployment stopped at $($failed -join ', '). Fix the error and re-run - every script is idempotent, so re-running from the start is safe." -ForegroundColor Red
exit 1
