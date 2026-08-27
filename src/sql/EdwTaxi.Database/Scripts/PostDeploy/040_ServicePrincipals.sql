/* =============================================================================
   040_ServicePrincipals.sql   (post-deploy, idempotent)
   =============================================================================

   Creates the contained database user for the Data Factory managed identity
   and grants it exactly what PL_Load_Sql_YellowTrip needs.

   THIS IS LAYER 3 OF THE THREE-LAYER PERMISSION MODEL (see
   infra/terraform/rbac.tf). Terraform grants Azure RBAC; Terraform CANNOT
   create a SQL principal, because SQL keeps its own principal store that Azure
   RBAC has no visibility into. Until this script runs, ADF authenticates
   successfully to the *server* and then fails at the database with:

       Login failed for user '<token-identified principal>'

   which names neither the identity nor the database, and sends most people off
   investigating the network.

   -----------------------------------------------------------------------------
   Why the principal name is the RESOURCE name
   -----------------------------------------------------------------------------
   For a system-assigned managed identity, the Entra display name IS the Azure
   resource name - `adf-edwtaxi-dev-a7k2`. Not the object ID, not the
   application ID. CREATE USER ... FROM EXTERNAL PROVIDER resolves that display
   name through Microsoft Graph.

   The value arrives as the $(DataFactoryName) SQLCMD variable, supplied by
   .github/workflows/sql-cd.yml from `terraform output data_factory_name`.

   -----------------------------------------------------------------------------
   Requirement on the deploying identity
   -----------------------------------------------------------------------------
   CREATE USER ... FROM EXTERNAL PROVIDER requires the CALLER to be an Entra
   principal - a SQL-authenticated login cannot create an Entra user, even as
   sysadmin. The deployment service principal is a member of the Entra admin
   group (bootstrap/main.tf) and authenticates with an access token, so it
   qualifies. If you switch sqlpackage to SQL authentication, this script fails
   with "Principal 'x' could not be found or this principal type is not
   supported".
   ============================================================================= */

PRINT 'Post-deploy 040: service principals';
GO

/* Dynamic SQL because CREATE USER does not accept a variable for the principal
   name, and because $(DataFactoryName) must be quoted as an identifier. */
DECLARE @principal SYSNAME       = N'$(DataFactoryName)';
/* The CLIENT id, not the object id. For an Entra service principal - which a
   managed identity is - Azure SQL derives the user's SID from the APPLICATION
   (client) id. The object id is a different GUID entirely, and a user created
   from it is a user no token will ever match: it exists, it has the right name,
   and every login fails. */
DECLARE @clientId  NVARCHAR(64)   = N'$(DataFactoryClientId)';
DECLARE @sql       NVARCHAR(MAX);
DECLARE @sid       VARBINARY(16);

IF @principal IS NULL OR LTRIM(RTRIM(@principal)) = ''
BEGIN
    RAISERROR('SQLCMD variable DataFactoryName is empty. Pass it with sqlpackage /v:DataFactoryName=<name>.', 16, 1);
END
ELSE
BEGIN
    IF @clientId IS NOT NULL AND LTRIM(RTRIM(@clientId)) <> ''
       AND TRY_CAST(@clientId AS UNIQUEIDENTIFIER) IS NOT NULL
        SET @sid = CAST(CAST(@clientId AS UNIQUEIDENTIFIER) AS VARBINARY(16));

    /* A user whose SID does not match the identity is worse than no user: the
       name looks right, the verification below passes, and every ADF activity
       fails with "Login failed for user '<token-identified principal>'" -
       which reads as a permissions problem rather than a wrong SID. Drop it and
       let it be recreated correctly. */
    IF EXISTS (SELECT 1 FROM sys.database_principals
               WHERE name = @principal AND type IN ('E','X'))
       AND (
            /* known-wrong: the SID does not belong to this identity */
            (@sid IS NOT NULL AND EXISTS (SELECT 1 FROM sys.database_principals
                                          WHERE name = @principal AND sid <> @sid))
            /* or unverifiable: no client id to compare against. Recreating is
               the safe direction. A user with the right name and the wrong SID
               passes every check that looks for the name - including the
               verification at the end of this deployment - while ADF fails on
               every activity. Recreating costs a dropped-and-regranted user on
               deployments that cannot verify; keeping one costs a silent
               outage. */
         OR @sid IS NULL
       )
    BEGIN
        PRINT CONCAT('  [', @principal, '] exists but its SID cannot be confirmed - recreating.');
        SET @sql = N'DROP USER ' + QUOTENAME(@principal) + N';';
        EXEC sp_executesql @sql;
    END
END

IF @principal IS NOT NULL AND LTRIM(RTRIM(@principal)) <> ''
   AND NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @principal)
BEGIN
    BEGIN TRY
        /* -------------------------------------------------------------------
           BY SID, NOT FROM EXTERNAL PROVIDER, WHEN WE KNOW THE OBJECT ID.

           FROM EXTERNAL PROVIDER resolves the display name through Microsoft
           Graph, and the SERVER's managed identity is what does the resolving -
           so it needs the Entra "Directory Readers" role. That is a
           tenant-level grant needing Privileged Role Administrator, which is
           more than the subscription Owner rights the rest of this template
           asks for, and it has to be repeated for every environment's server.
           Without it the create fails and ADF pipelines then fail with "Login
           failed for user '<token-identified principal>'" - an error three
           layers away from the cause.

           An Entra principal's SID in SQL is just its object ID in
           little-endian byte order, which is exactly what casting a
           uniqueidentifier to varbinary(16) produces. Supplying it directly
           needs no directory read at all.

           _sql-publish.yml resolves it with `az ad sp show --id <principal id>
           --query appId`, because Terraform publishes the ADF identity's OBJECT
           id and this needs its CLIENT id. When it cannot be resolved - no
           directory read, a hand-run sqlpackage - this falls back to the Graph
           path, so nothing that worked before stops working.
           ------------------------------------------------------------------- */
        IF @sid IS NOT NULL
        BEGIN
            PRINT CONCAT('  Creating database user [', @principal, '] by SID (no Graph lookup)...');

            SET @sql = N'CREATE USER ' + QUOTENAME(@principal) +
                       N' WITH SID = 0x' + CONVERT(NVARCHAR(64), @sid, 2) + N', TYPE = E;';
        END
        ELSE
        BEGIN
            PRINT CONCAT('  Creating database user [', @principal, '] from external provider...');
            SET @sql = N'CREATE USER ' + QUOTENAME(@principal) + N' FROM EXTERNAL PROVIDER;';
        END

        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        /* Do not fail the whole deployment over this. A schema deployment that
           rolls back because of a permissions problem is far more disruptive
           than one that succeeds and logs a clear, actionable warning - and
           the ADF pipeline will fail loudly at its next run anyway. */
        PRINT '';
        PRINT '  **********************************************************';
        PRINT '  * WARNING: could not create the Data Factory user.';
        PRINT '  * ' + ERROR_MESSAGE();
        PRINT '  *';
        PRINT '  * Common causes:';
        PRINT '  *  - sqlpackage authenticated with SQL auth rather than an';
        PRINT '  *    Entra token. FROM EXTERNAL PROVIDER requires Entra.';
        PRINT '  *  - The name in $(DataFactoryName) does not match the';
        PRINT '  *    factory resource name.';
        PRINT '  *  - $(DataFactoryClientId) was not supplied, so this fell';
        PRINT '  *    back to Graph resolution, and the SERVER identity lacks';
        PRINT '  *    the Entra Directory Readers role.';
        PRINT '  *';
        PRINT '  * ADF pipelines will fail with "Login failed for user';
        PRINT '  * <token-identified principal>" until this is resolved.';
        PRINT '  * See docs/12-troubleshooting.md#adf-cannot-log-in-to-azure-sql';
        PRINT '  **********************************************************';
        PRINT '';
    END CATCH
END
ELSE
BEGIN
    PRINT CONCAT('  Database user [', @principal, '] already exists.');
END
GO

/* ---------------------------------------------------------------------------
   Grants.

   Enumerated rather than `ALTER ROLE db_datawriter`, for the same reason as in
   src/synapse/serverless/090_permissions.sql: db_datawriter would let the
   pipeline write to dim.* and fact.* directly, bypassing every guard in
   etl.usp_Merge_YellowTaxiTrip - including the empty-staging check that stops
   a bad run from deleting a production partition.

   What ADF is allowed to do:
     stg   INSERT and DELETE       (the Copy activity, and its TRUNCATE)
     etl   EXECUTE                 (the load procedures)
     meta  SELECT                  (Lookup reads LoadId back)
     dim   SELECT                  (the merge joins to resolve keys)
     fact  SELECT                  (data quality rules only - see below)

   Writing to fact is still impossible: SELECT is read-only, and every write
   goes through etl.usp_Merge_YellowTaxiTrip, so the empty-staging guard cannot
   be bypassed.
   --------------------------------------------------------------------------- */
DECLARE @principal2 SYSNAME = N'$(DataFactoryName)';
DECLARE @grant NVARCHAR(MAX);

IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @principal2)
BEGIN
    SET @grant = N'
        GRANT SELECT, INSERT, DELETE ON SCHEMA::stg  TO ' + QUOTENAME(@principal2) + N';
        GRANT EXECUTE                ON SCHEMA::etl  TO ' + QUOTENAME(@principal2) + N';
        GRANT SELECT                 ON SCHEMA::meta TO ' + QUOTENAME(@principal2) + N';
        GRANT SELECT                 ON SCHEMA::dim  TO ' + QUOTENAME(@principal2) + N';';

    EXEC sp_executesql @grant;

    /* The Copy activity issues TRUNCATE TABLE as its preCopyScript. TRUNCATE
       requires ALTER on the table - it is a DDL operation, not a DML one, and
       DELETE permission does not cover it. Missing this grant produces
       "Cannot find the object because it does not exist or you do not have
       permissions", which names the wrong problem. */
    SET @grant = N'GRANT ALTER ON OBJECT::stg.YellowTaxiTrip TO ' + QUOTENAME(@principal2) + N';';
    EXEC sp_executesql @grant;

    /* Read on fact, for the data quality gate and nothing else.

       This grant looks removable: no code path visible anywhere in the repo
       SELECTs fact.* as this identity. etl.usp_Merge_YellowTaxiTrip reads and
       writes it, but that is static SQL inside a dbo-owned procedure, so
       ownership chaining covers it and EXECUTE on etl is enough - which is
       exactly why fact was left out of the list above.

       etl.usp_RunDataQualityChecks is the exception. Data quality rules are
       rows in meta.DataQualityRule, so it runs each rule's text through
       sp_executesql - and ownership chaining does not extend to dynamic SQL.
       The rule executes as the caller, so ADF needs its own SELECT.

       Without this, every rule fails identically and the load dies after the
       merge has already committed:

         Rule execution error: The SELECT permission was denied on the object
         'YellowTaxiTrip', database 'edw', schema 'fact'.

       Do not remove it because nothing appears to use it. */
    SET @grant = N'GRANT SELECT ON SCHEMA::fact TO ' + QUOTENAME(@principal2) + N';';
    EXEC sp_executesql @grant;

    PRINT CONCAT('  Granted stg/etl/meta/dim/fact permissions to [', @principal2, '].');
END
GO

/* ---------------------------------------------------------------------------
   Read-only role for reporting tools and analysts.

   Members are added OUTSIDE this script - by your identity governance process,
   or by hand for a proof of concept:

       CREATE USER [sg-edwtaxi-readers] FROM EXTERNAL PROVIDER;
       ALTER ROLE edw_reader ADD MEMBER [sg-edwtaxi-readers];

   Deliberately not automated: who can read the warehouse is an access decision,
   not a deployment artifact, and a deployment pipeline that can grant data
   access is a deployment pipeline that can exfiltrate data.
   --------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'edw_reader' AND type = 'R')
BEGIN
    PRINT '  Creating role edw_reader...';
    EXEC (N'CREATE ROLE edw_reader AUTHORIZATION dbo;');
END
GO

GRANT SELECT ON SCHEMA::rpt  TO edw_reader;
GRANT SELECT ON SCHEMA::dim  TO edw_reader;
GRANT SELECT ON SCHEMA::fact TO edw_reader;
GRANT SELECT ON SCHEMA::meta TO edw_reader;
GO

/* stg is explicitly NOT granted: it holds a half-loaded month for part of
   every night, and a report pointed at it would be wrong in a way nobody
   could reproduce during the day. */

PRINT '  Role edw_reader granted SELECT on rpt, dim, fact, meta.';
GO
