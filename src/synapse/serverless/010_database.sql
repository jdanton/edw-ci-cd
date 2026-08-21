/* =============================================================================
   010_database.sql
   CONTEXT: master        (this is the ONE script that runs against master)
   =============================================================================

   Creates the serverless SQL database that hosts the logical data warehouse.

   "Database" here is a metadata container only. Serverless has no storage of
   its own: every table you will see is an EXTERNAL table pointing at Parquet
   in ADLS, and every view is a query over those files. Dropping this database
   deletes no data - it deletes the *definitions*, which is still a bad day,
   but a recoverable one, because everything in src/synapse/serverless/ is
   idempotent and re-runnable.

   -----------------------------------------------------------------------------
   COLLATION - the one decision here you cannot change later
   -----------------------------------------------------------------------------
   Latin1_General_100_BIN2_UTF8 is not a stylistic preference. Parquet stores
   strings as UTF-8. If the database collation is a non-UTF8 collation (the
   server default is Latin1_General_100_CI_AS_SC_UTF8 on newer workspaces, but
   older ones default to a non-UTF8 collation), serverless must TRANSCODE every
   string column on every read. On a wide table that is a measurable, permanent
   tax on every query - frequently 2-3x on string-heavy scans.

   BIN2 additionally gives binary (byte-order) comparison, which is the fastest
   possible string comparison and lets predicate pushdown work on string
   columns. The cost is case-SENSITIVE comparison, which surprises people:
   'Manhattan' <> 'MANHATTAN'. For a warehouse where string comparisons are
   mostly joins on codes, that is the right trade. If you need case-insensitive
   comparison in a specific view, use COLLATE explicitly on that expression.

   Changing collation requires dropping and re-creating the database.

   -----------------------------------------------------------------------------
   Variables supplied by scripts/Deploy-ServerlessSql.ps1
   -----------------------------------------------------------------------------
     $(DatabaseName)  e.g. edw_lake
   ============================================================================= */

SET NOCOUNT ON;
GO

IF DB_ID(N'$(DatabaseName)') IS NULL
BEGIN
    PRINT 'Creating serverless database [$(DatabaseName)]...';
    EXEC (N'CREATE DATABASE [$(DatabaseName)] COLLATE Latin1_General_100_BIN2_UTF8;');
END
ELSE
BEGIN
    PRINT 'Database [$(DatabaseName)] already exists - no action taken.';
END
GO

/* Warn loudly rather than fail if an existing database has the wrong
   collation. Failing would block every subsequent deployment; warning lets the
   pipeline proceed while making the problem impossible to miss in the log. */
DECLARE @collation SYSNAME =
    CONVERT(SYSNAME, DATABASEPROPERTYEX(N'$(DatabaseName)', 'Collation'));

IF @collation <> N'Latin1_General_100_BIN2_UTF8'
BEGIN
    PRINT '';
    PRINT '**************************************************************';
    PRINT '* WARNING: [$(DatabaseName)] collation is ' + @collation;
    PRINT '* Expected Latin1_General_100_BIN2_UTF8.';
    PRINT '* Every string column will be transcoded on every read.';
    PRINT '* Fixing this requires dropping and re-creating the database.';
    PRINT '* See docs/07-synapse.md#collation';
    PRINT '**************************************************************';
    PRINT '';
END
GO
