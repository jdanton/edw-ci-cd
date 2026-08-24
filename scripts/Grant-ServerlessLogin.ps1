#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Gives an Entra principal its OWN login on the Synapse serverless endpoint,
    instead of relying on membership of the workspace's Entra admin group.

.DESCRIPTION
    WHY THIS EXISTS

    The template's design is that the deployment service principal reaches
    serverless SQL by being a member of sg-<project>-synapseadmin-<env>, which
    Terraform sets as the workspace's SQL Entra administrator. That is what
    src/synapse/serverless/090_permissions.sql assumes when it says the admin
    group is "already sysadmin-equivalent".

    It holds for HUMAN members. It did not hold for a service principal member:
    with the SP verifiably in the group, the group verifiably the admin, and the
    workspace managed identity granted Directory Readers, every connection was
    still refused with

        Login failed for user '<token-identified principal>'.

    A login created here does not depend on group resolution at all, so it
    survives whatever that mechanism is doing.

    THE CHICKEN AND EGG

    Only an administrator can create a login, and the principal that needs one
    cannot log in. Break it by making the principal the workspace's SQL Entra
    admin JUST long enough to run this, then handing the admin back to the
    group:

        az synapse sql ad-admin update -g <rg> --workspace-name <ws> `
            --display-name <sp-name> --object-id <sp-object-id>

        ./scripts/Grant-ServerlessLogin.ps1 -Environment dev -PrincipalName <sp-name>

        az synapse sql ad-admin update -g <rg> --workspace-name <ws> `
            --display-name sg-<project>-synapseadmin-<env> --object-id <group-object-id>

    The login outlives the swap. Hand the admin back promptly - while the
    service principal holds it, humans in the admin group do not.

    Restoring the group also matters because Terraform owns that setting
    (azurerm_synapse_workspace_sql_aad_admin); leaving the SP there is drift the
    next infra-cd apply would revert, at a time of its choosing.

    NETWORK: the serverless endpoint is private. Run this from the self-hosted
    runner, or any host on a VNet linked to privatelink.sql.azuresynapse.net.

.PARAMETER Environment
    dev, test or prod.

.PARAMETER PrincipalName
    Entra display name of the principal to grant - for a deployment identity,
    sp-<project>-github-deploy-<env>. Must match the directory exactly:
    CREATE LOGIN ... FROM EXTERNAL PROVIDER resolves it by name through Graph.

.PARAMETER WhatIf
    Print the statements without connecting.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'prod')]
    [string] $Environment,

    [Parameter(Mandatory)]
    [string] $PrincipalName,

    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,

    [int] $ConnectionTimeoutSeconds = 60,
    [int] $QueryTimeoutSeconds      = 300,

    # Same warm-up handling as Deploy-ServerlessSql.ps1: the built-in pool
    # resumes on demand and refuses the first statement while it does.
    [int] $WarmupRetryCount = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Tooling.ps1')

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    !! $m" -ForegroundColor Yellow }

$terraformDir = Join-Path $RepositoryRoot 'infra' 'terraform'

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
# 2. Target
# ---------------------------------------------------------------------------

Write-Step "Reading serverless context ($Environment)."

Push-Location $terraformDir
try {
    $ctx = terraform output -json serverless_deployment_context | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'terraform output failed.' }
}
finally {
    Pop-Location
}

$serverInstance = $ctx.serverlessEndpoint
Write-Ok "Endpoint  : $serverInstance"
Write-Ok "Principal : $PrincipalName"

# ---------------------------------------------------------------------------
# 3. The statements
#
# QUOTENAME rather than string concatenation: a display name is directory data,
# not a literal we control. Everything is guarded, so re-running is a no-op -
# which matters because the safe response to "did that work?" is to run it
# again.
# ---------------------------------------------------------------------------

$grantSql = @"
DECLARE @name  sysname       = N'$($PrincipalName.Replace("'", "''"))';
DECLARE @stmt  nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @name)
BEGIN
    SET @stmt = N'CREATE LOGIN ' + QUOTENAME(@name) + N' FROM EXTERNAL PROVIDER;';
    PRINT 'Creating login: ' + @name;
    EXEC sp_executesql @stmt;
END
ELSE
    PRINT 'Login already exists: ' + @name;

IF IS_SRVROLEMEMBER('sysadmin', @name) = 1
    PRINT 'Already a member of sysadmin: ' + @name;
ELSE
BEGIN
    SET @stmt = N'ALTER SERVER ROLE sysadmin ADD MEMBER ' + QUOTENAME(@name) + N';';
    PRINT 'Adding to sysadmin: ' + @name;
    EXEC sp_executesql @stmt;
END
"@

$verifySql = @"
SELECT
    LoginName  = sp.name,
    LoginType  = sp.type_desc,
    IsSysadmin = IS_SRVROLEMEMBER('sysadmin', sp.name)
FROM sys.server_principals AS sp
WHERE sp.name = N'$($PrincipalName.Replace("'", "''"))';
"@

if (-not $PSCmdlet.ShouldProcess($serverInstance, "Grant a serverless login to $PrincipalName")) {
    Write-Host ''
    Write-Host 'WHATIF - would run against [master]:' -ForegroundColor Yellow
    $grantSql -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    exit 0
}

# ---------------------------------------------------------------------------
# 4. Run it
# ---------------------------------------------------------------------------

Write-Step 'Acquiring an Entra access token for the SQL data plane.'

$tokenJson = az account get-access-token --resource 'https://database.windows.net/' --output json 2>$null
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tokenJson)) {
    throw 'Could not acquire an access token. Run azure/login@v2 (CI) or az login (local) first.'
}
$accessToken = ($tokenJson | ConvertFrom-Json).accessToken
Write-Ok 'Token acquired.'

$transientSqlErrors = 'is warming up|is not currently available|Please retry the connection|transport-level error'

Write-Step "Granting on [master] at $serverInstance."

$attempt = 0
while ($true) {
    $attempt++
    try {
        $output = Invoke-Sqlcmd `
            -ServerInstance    $serverInstance `
            -Database          'master' `
            -AccessToken       $accessToken `
            -Query             $grantSql `
            -QueryTimeout      $QueryTimeoutSeconds `
            -ConnectionTimeout $ConnectionTimeoutSeconds `
            -AbortOnError `
            -Verbose 4>&1

        $output | ForEach-Object {
            $line = "$_".Trim()
            if ($line) { Write-Host "    | $line" -ForegroundColor DarkGray }
        }
        break
    }
    catch {
        $message = $_.Exception.Message

        if ($message -match $transientSqlErrors -and $attempt -le $WarmupRetryCount) {
            $delay = [math]::Min(60, 15 * $attempt)
            Write-Warn "Transient: $message"
            Write-Warn "Waiting ${delay}s for the pool, then retrying (attempt $attempt of $WarmupRetryCount)."
            Start-Sleep -Seconds $delay
            continue
        }

        if ($message -match 'Login failed') {
            Write-Warn 'The connecting principal is not an administrator of this endpoint.'
            Write-Warn 'This script has to run AS an admin - see the chicken-and-egg note in its header.'
        }
        throw
    }
}

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------

Write-Step 'Verifying.'

$result = Invoke-Sqlcmd `
    -ServerInstance    $serverInstance `
    -Database          'master' `
    -AccessToken       $accessToken `
    -Query             $verifySql `
    -QueryTimeout      120 `
    -ConnectionTimeout $ConnectionTimeoutSeconds

if (-not $result) {
    throw "No login named '$PrincipalName' exists after the grant. Nothing was changed."
}

$result | Format-Table -AutoSize | Out-String | Write-Host

if ($result.IsSysadmin -ne 1) {
    throw "'$PrincipalName' has a login but is not in sysadmin."
}

Write-Ok "$PrincipalName can now sign in independently of the admin group."
Write-Warn 'If you swapped the workspace SQL admin to run this, hand it back to the group NOW.'
