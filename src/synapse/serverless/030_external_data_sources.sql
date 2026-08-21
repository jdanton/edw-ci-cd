/* =============================================================================
   030_external_data_sources.sql
   CONTEXT: $(DatabaseName)
   =============================================================================

   One EXTERNAL DATA SOURCE per lake filesystem.

   An external data source is a named (location, credential) pair. Splitting the
   lake into three of them rather than one root data source buys two things:

     1. Blast radius. A view that reads `eds_raw` physically cannot read
        `eds_sandbox`, whatever the path expression says.
     2. Portability. Every environment has the same three names pointing at
        different accounts, so not a single view or procedure below contains a
        storage account name. Promoting from dev to prod changes these three
        objects and nothing else.

   -----------------------------------------------------------------------------
   CREATE OR ALTER is NOT supported for external data sources
   -----------------------------------------------------------------------------
   ...so the idempotency pattern is drop-and-recreate. That is safe because an
   external data source holds no data. It is NOT free, though: dropping one
   fails if any external table still references it, which is why this script
   runs before 070_procs_curate.sql creates any, and why the DROP is guarded.

   If a deployment fails here with "Cannot drop the external data source
   'eds_curated' because it is used by external table
   'curated.ext_YellowTaxiTrip_202401'", the location has genuinely changed and
   you must drop the dependent external tables first. See
   docs/12-troubleshooting.md#external-data-source-in-use.

   -----------------------------------------------------------------------------
   Variables (abfss:// URIs, from terraform output lake_abfss_uris)
   -----------------------------------------------------------------------------
     $(RawLocation)        abfss://raw@st....dfs.core.windows.net
     $(CuratedLocation)    abfss://curated@st....dfs.core.windows.net
     $(SandboxLocation)    abfss://sandbox@st....dfs.core.windows.net
   ============================================================================= */

USE [$(DatabaseName)];
GO

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------------
   eds_raw - immutable landing zone. Read-only by convention: nothing in this
   database writes here, and nothing should.
   --------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.external_data_sources WHERE name = 'eds_raw')
BEGIN
    PRINT 'Dropping existing eds_raw...';
    DROP EXTERNAL DATA SOURCE eds_raw;
END
GO

CREATE EXTERNAL DATA SOURCE eds_raw
WITH (
    LOCATION   = '$(RawLocation)',
    CREDENTIAL = cred_LakeManagedIdentity
);
GO

/* ---------------------------------------------------------------------------
   eds_curated - CETAS writes here. The workspace managed identity needs
   Storage Blob Data CONTRIBUTOR (not Reader) on the account for that to work.
   --------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.external_data_sources WHERE name = 'eds_curated')
BEGIN
    PRINT 'Dropping existing eds_curated...';
    DROP EXTERNAL DATA SOURCE eds_curated;
END
GO

CREATE EXTERNAL DATA SOURCE eds_curated
WITH (
    LOCATION   = '$(CuratedLocation)',
    CREDENTIAL = cred_LakeManagedIdentity
);
GO

/* ---------------------------------------------------------------------------
   eds_sandbox - analyst scratch. Lifecycle-deleted after 30 days by the
   storage management policy in infra/terraform/modules/storage.
   --------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.external_data_sources WHERE name = 'eds_sandbox')
BEGIN
    PRINT 'Dropping existing eds_sandbox...';
    DROP EXTERNAL DATA SOURCE eds_sandbox;
END
GO

CREATE EXTERNAL DATA SOURCE eds_sandbox
WITH (
    LOCATION   = '$(SandboxLocation)',
    CREDENTIAL = cred_LakeManagedIdentity
);
GO

PRINT 'External data sources:';
SELECT name, location, credential_id FROM sys.external_data_sources ORDER BY name;
GO
