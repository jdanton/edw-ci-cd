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
   Why this script compares before it drops
   -----------------------------------------------------------------------------
   CREATE OR ALTER is not supported for external data sources, so the obvious
   idempotency pattern is drop-and-recreate, and that is what this script used
   to do: IF EXISTS ... DROP, then CREATE.

   That pattern is not idempotent here, because dropping an external data source
   fails while any external table still references it - and 070_procs_curate.sql
   creates one external table per curated partition, on eds_curated, that lives
   as long as the data does. So the first backfill made this script fail forever
   after:

     Msg 33165 ... 030_external_data_sources.sql FAILED

   The script was dropping an object it was about to recreate identically, and
   the drop was refused for referencing tables that were entirely expected. A
   deployment that works exactly once, and only until real data exists, is worse
   than one that never works: it passes every test you run before you have data.

   So the guard now tests the definition, not merely existence:

     absent            -> create it
     present, same     -> leave it alone (the overwhelmingly common case)
     present, changed  -> drop and recreate, which is the only case where the
                          dependent external tables are a genuine problem

   In that last case the referencing tables are named in the error, because a
   location change means the curated files are in a different account and those
   tables are pointing at the old one. Dropping them is safe (they are metadata
   over files, not data) but it is a deliberate act, so this script will not do
   it silently. See docs/12-troubleshooting.md#external-data-source-in-use.

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

/* The three names are fixed; only their locations vary by environment. Keeping
   the compare-and-create logic in one loop rather than copying it three times
   means the next fix here cannot land on two of the three.

   The obvious way to drive that loop is a table variable of (name, location).
   Serverless SQL does not have them:

     TYPE 'table' is not supported.   Msg 15871, Level 16, State 5

   so the pair is selected by index instead. Ugly, but it is three constants. */
DECLARE @name     sysname
      , @want     nvarchar(4000)
      , @have     nvarchar(4000)
      , @deps     nvarchar(max)
      , @sql      nvarchar(max)
      , @msg      nvarchar(2048)
      , @i        int = 1;

WHILE @i <= 3
BEGIN
    SELECT @name = CASE @i WHEN 1 THEN 'eds_raw'
                           WHEN 2 THEN 'eds_curated'
                           ELSE        'eds_sandbox' END
         , @want = CASE @i WHEN 1 THEN N'$(RawLocation)'
                           WHEN 2 THEN N'$(CuratedLocation)'
                           ELSE        N'$(SandboxLocation)' END;

    /* Advanced before any CONTINUE below, or the unchanged case loops forever. */
    SET @i += 1;

    SET @have = (SELECT location FROM sys.external_data_sources WHERE name = @name);

    /* Already correct. sys.external_data_sources stores the location exactly as
       it was supplied - no normalisation, no trailing slash - so this is a
       straight comparison rather than a fuzzy one. */
    IF @have IS NOT NULL AND @have = @want
    BEGIN
        PRINT '  ' + @name + ' -> ' + @have + '  (unchanged, left alone)';
        CONTINUE;
    END

    IF @have IS NOT NULL
    BEGIN
        /* Genuinely moving. Name the dependants rather than letting the DROP
           fail with a message that mentions only the first one it happens to
           find. Seeded with a MAX-typed empty string: an nvarchar(n) seed would
           silently truncate the list at 4000 characters. */
        SET @deps = NULL;

        SELECT @deps = COALESCE(@deps + N', ', CAST(N'' AS nvarchar(max)))
                     + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
        FROM sys.external_tables t
        JOIN sys.schemas s
          ON s.schema_id = t.schema_id
        JOIN sys.external_data_sources ds
          ON ds.data_source_id = t.data_source_id
        WHERE ds.name = @name;

        IF @deps IS NOT NULL
        BEGIN
            SET @msg = @name + N' must move from ' + @have + N' to ' + @want
                     + N', but these external tables still reference it: ' + @deps
                     + N'. They describe files in the old account, so drop them first: '
                     + N'see docs/12-troubleshooting.md#external-data-source-in-use.';
            RAISERROR (@msg, 16, 1);
            RETURN;
        END

        PRINT '  ' + @name + ' moving from ' + @have + ' to ' + @want + ' - dropping...';
        SET @sql = N'DROP EXTERNAL DATA SOURCE ' + QUOTENAME(@name) + N';';
        EXEC sp_executesql @sql;
    END

    /* LOCATION will not accept a variable, so the statement is assembled and
       executed dynamically. The name comes from the fixed list above, and the
       location is escaped, so there is nothing here an environment value can
       break out of. */
    SET @sql = N'CREATE EXTERNAL DATA SOURCE ' + QUOTENAME(@name) + N'
                 WITH (
                     LOCATION   = ''' + REPLACE(@want, '''', '''''') + N''',
                     CREDENTIAL = cred_LakeManagedIdentity
                 );';
    EXEC sp_executesql @sql;

    PRINT '  ' + @name + ' -> ' + @want + '  (created)';
END
GO

PRINT 'External data sources:';
SELECT name, location, credential_id FROM sys.external_data_sources ORDER BY name;
GO
