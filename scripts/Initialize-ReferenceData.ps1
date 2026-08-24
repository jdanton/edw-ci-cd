#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Seeds the TLC taxi zone lookup into the lake and into dim.TaxiZone.

.DESCRIPTION
    The 265 taxi zones are the only reference data in this platform that comes
    from outside. Everything else (vendors, rate codes, payment types) is a
    short, stable code list seeded by the DACPAC post-deploy script.

    Zones are different: the TLC republishes them, so they belong in the
    pipeline like any other source. This script:

      1. Downloads taxi_zone_lookup.csv from the TLC's CloudFront distribution.
      2. Uploads it to raw/nyctlc/reference/ so raw.vw_TaxiZoneLookup can read
         it and so the lake holds a copy of exactly what was received.
      3. MERGEs it into dim.TaxiZone in Azure SQL.

    Step 3 loads from the LOCAL file rather than reading back through Synapse.
    For 265 rows, pushing a VALUES list over the existing connection is simpler,
    faster and has fewer moving parts than standing up a serverless read - and
    this script already has the file in hand.

    Run it ONCE per environment after the first successful infrastructure and
    SQL deployment, and again whenever the TLC publishes a zone change.

.PARAMETER Environment
    dev, test or prod.

.PARAMETER SourceUrl
    Override the download location - for an air-gapped environment with an
    internal mirror, or to pin a historical version.

.PARAMETER SkipDownload
    Use an already-downloaded file. Implies -LocalCsvPath.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('dev', 'test', 'prod')]
    [string] $Environment,

    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,

    [string] $SourceUrl = 'https://d37ci6vzurychx.cloudfront.net/misc/taxi_zone_lookup.csv',

    [switch] $SkipDownload,
    [string] $LocalCsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_Tooling.ps1')   # PATH repair + Resolve-RequiredTool

function Write-Step { param([string]$m) Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "    $m" -ForegroundColor Green }

$terraformDir = Join-Path $RepositoryRoot 'infra' 'terraform'

Write-Step "Reading environment configuration ($Environment)."

Push-Location $terraformDir
try {
    $tf = terraform output -json deployment_config | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'terraform output failed.' }
}
finally {
    Pop-Location
}

# ---------------------------------------------------------------------------
# 1. Obtain the file
# ---------------------------------------------------------------------------

if (-not $SkipDownload) {
    $LocalCsvPath = Join-Path ([IO.Path]::GetTempPath()) 'taxi_zone_lookup.csv'
    Write-Step "Downloading $SourceUrl"
    Invoke-WebRequest -Uri $SourceUrl -OutFile $LocalCsvPath -UseBasicParsing
}

if (-not (Test-Path $LocalCsvPath)) {
    throw "Taxi zone CSV not found at $LocalCsvPath."
}

$zones = @(Import-Csv -Path $LocalCsvPath)
Write-Ok "$($zones.Count) zones read from $LocalCsvPath"

# The TLC publishes exactly 265 zones and has for years. A materially different
# count means the file format changed, and blindly MERGEing it would silently
# reshape a dimension that a hundred million fact rows point at.
if ($zones.Count -lt 200 -or $zones.Count -gt 400) {
    throw "Expected roughly 265 zones, got $($zones.Count). The source file format may have changed - inspect $LocalCsvPath before proceeding."
}

$expectedColumns = @('LocationID', 'Borough', 'Zone', 'service_zone')
$actualColumns   = $zones[0].PSObject.Properties.Name
foreach ($column in $expectedColumns) {
    if ($actualColumns -notcontains $column) {
        throw "Column '$column' missing from the source CSV. Found: $($actualColumns -join ', '). Update raw.vw_TaxiZoneLookup in src/synapse/serverless/060_views_raw.sql to match."
    }
}
Write-Ok 'Column contract verified.'

# ---------------------------------------------------------------------------
# 2. Upload to the lake
#
# Byte for byte, into raw/, because "raw holds what we received" is the rule
# that makes the lake trustworthy. raw.vw_TaxiZoneLookup reads it from here.
# ---------------------------------------------------------------------------

$lakePath = 'nyctlc/reference/taxi_zone_lookup.csv'

if ($PSCmdlet.ShouldProcess("$($tf.storageAccountName)/raw/$lakePath", 'Upload taxi zone lookup')) {
    Write-Step "Uploading to raw/$lakePath"

    # --auth-mode login uses the ambient Entra identity. The lake has
    # shared_access_key_enabled = false, so there is no key path available and
    # this is the only way in.
    az storage fs file upload `
        --account-name $tf.storageAccountName `
        --file-system  'raw' `
        --path         $lakePath `
        --source       $LocalCsvPath `
        --auth-mode    login `
        --overwrite    true `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw @"
Upload failed. Two likely causes:

  1. RBAC - the signed-in identity needs Storage Blob Data Contributor on the
     account. ARM 'Contributor' does NOT grant blob data access.
     infra/terraform/rbac.tf grants this to the deployment identity.

  2. Network - the account has no public endpoint. This must run from a host
     that resolves privatelink.dfs.core.windows.net privately.
     Run scripts/Test-PlatformConnectivity.ps1 to tell the two apart.
"@
    }

    Write-Ok 'Uploaded.'
}

# ---------------------------------------------------------------------------
# 3. MERGE into dim.TaxiZone
#
# TaxiZoneKey = LocationID. The source IDs are a dense 1..265 sequence that the
# TLC has never renumbered, so a separate surrogate would add a join for no
# benefit. The -1 Unknown member is seeded by the DACPAC post-deploy script and
# is protected from this MERGE by the WHEN NOT MATCHED BY SOURCE predicate.
# ---------------------------------------------------------------------------

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Install-Module -Name SqlServer -Scope CurrentUser -Force -AllowClobber -MinimumVersion 22.0.0
}
Import-Module SqlServer -Force

Write-Step 'Acquiring an Entra access token for Azure SQL.'
$accessToken = (az account get-access-token --resource 'https://database.windows.net/' --output json |
                ConvertFrom-Json).accessToken
if (-not $accessToken) { throw 'Could not acquire an access token.' }

function ConvertTo-SqlLiteral {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return 'NULL' }
    return "N'" + $Value.Replace("'", "''") + "'"
}

$valueRows = $zones | ForEach-Object {
    $id = [int]$_.LocationID
    "({0}, {0}, {1}, {2}, {3})" -f `
        $id,
        (ConvertTo-SqlLiteral $_.Borough),
        (ConvertTo-SqlLiteral $_.Zone),
        (ConvertTo-SqlLiteral $_.service_zone)
}

$mergeSql = @"
SET NOCOUNT ON;

MERGE dim.TaxiZone AS target
USING (VALUES
$($valueRows -join ",`n")
) AS source (TaxiZoneKey, TaxiZoneId, Borough, ZoneName, ServiceZone)
    ON target.TaxiZoneKey = source.TaxiZoneKey
WHEN MATCHED AND (
        target.Borough     <> source.Borough
     OR target.ZoneName    <> source.ZoneName
     OR ISNULL(target.ServiceZone, '') <> ISNULL(source.ServiceZone, '')
    )
    THEN UPDATE SET
        target.Borough     = source.Borough,
        target.ZoneName    = source.ZoneName,
        target.ServiceZone = source.ServiceZone,
        target.LoadedAtUtc = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (TaxiZoneKey, TaxiZoneId, Borough, ZoneName, ServiceZone, IsUnknown)
         VALUES (source.TaxiZoneKey, source.TaxiZoneId, source.Borough, source.ZoneName, source.ServiceZone, 0)
WHEN NOT MATCHED BY SOURCE AND target.IsUnknown = 0
    /* A zone the TLC retired. Deleting it would orphan every historical fact
       row that points at it, so the row stays and is simply not updated. If you
       need to know which zones are current, add an IsCurrent flag rather than
       deleting history. */
    THEN UPDATE SET target.LoadedAtUtc = target.LoadedAtUtc;

SELECT
    TotalZones   = COUNT(*),
    RealZones    = SUM(CASE WHEN IsUnknown = 0 THEN 1 ELSE 0 END),
    AirportZones = SUM(CASE WHEN IsAirport = 1 THEN 1 ELSE 0 END)
FROM dim.TaxiZone;
"@

if ($PSCmdlet.ShouldProcess("$($tf.sqlServerFqdn)/$($tf.sqlDatabaseName)", 'Merge dim.TaxiZone')) {
    Write-Step "Merging $($zones.Count) zones into dim.TaxiZone."

    # dev and test are auto-pausing serverless databases, and this is often the
    # first thing to touch one all day - the resume outlasts the client timeout.
    # Classification and backoff live in _Tooling.ps1.
    $result = Invoke-SqlWithRetry -Activity 'dim.TaxiZone merge' -ScriptBlock {
        Invoke-Sqlcmd `
            -ServerInstance    $tf.sqlServerFqdn `
            -Database          $tf.sqlDatabaseName `
            -AccessToken       $accessToken `
            -Query             $mergeSql `
            -QueryTimeout      300 `
            -ConnectionTimeout 60 `
            -AbortOnError
    }

    Write-Ok "dim.TaxiZone: $($result.TotalZones) rows ($($result.RealZones) real, $($result.AirportZones) airport)."

    if ($env:GITHUB_STEP_SUMMARY) {
        @"
## Reference data - ``$Environment``

| | |
|---|---|
| Source | ``$SourceUrl`` |
| Lake path | ``raw/$lakePath`` |
| dim.TaxiZone rows | $($result.TotalZones) |
| Airport zones | $($result.AirportZones) |
"@ | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
}

Write-Step 'Reference data initialisation complete.'
