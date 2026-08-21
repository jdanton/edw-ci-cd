/* =============================================================================
   090_permissions.sql
   CONTEXT: $(DatabaseName)
   =============================================================================

   Database principals and grants. This is LAYER 3 of the three-layer permission
   model described in infra/terraform/rbac.tf.

   Azure RBAC cannot do any of this. Granting the Data Factory managed identity
   "Contributor" on the Synapse workspace, or even "Synapse Administrator", does
   NOT create a principal inside the serverless database. SQL keeps its own
   principal store, and until a user exists here, ADF's Script activity fails
   with:

       Login failed for user '<token-identified principal>'

   which names neither the identity nor the database, and sends most people off
   investigating networking.

   -----------------------------------------------------------------------------
   Variables
   -----------------------------------------------------------------------------
     $(DatabaseName)
     $(DataFactoryName)   e.g. adf-edwtaxi-dev-a7k2
                          For a system-assigned managed identity, the SQL
                          principal name is the RESOURCE NAME, not the object
                          ID and not the application ID.
     $(SynapseAdminGroup) Entra group display name, e.g. sg-edwtaxi-synapseadmin-dev
   ============================================================================= */

USE [$(DatabaseName)];
GO

SET NOCOUNT ON;
GO

/* ===========================================================================
   1. The Data Factory managed identity
   =========================================================================== */

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(DataFactoryName)')
BEGIN
    PRINT 'Creating database user for the Data Factory managed identity...';
    CREATE USER [$(DataFactoryName)] FROM EXTERNAL PROVIDER;
END
ELSE
BEGIN
    PRINT 'Database user [$(DataFactoryName)] already exists.';
END
GO

/* ---------------------------------------------------------------------------
   Grants required to RUN curated.usp_Build_Yellow_Monthly.

   These are deliberately enumerated rather than solved with
   `ALTER ROLE db_owner ADD MEMBER`. db_owner would work, take one line, and
   hand a pipeline identity the ability to drop every object in the database.
   The enumeration below is the least privilege that actually executes CETAS -
   each line is here because removing it produces a specific failure, noted
   alongside.
   --------------------------------------------------------------------------- */

-- Read the source. Without this: "The SELECT permission was denied".
GRANT SELECT ON SCHEMA::raw     TO [$(DataFactoryName)];
GRANT SELECT ON SCHEMA::curated TO [$(DataFactoryName)];
GRANT SELECT ON SCHEMA::serving TO [$(DataFactoryName)];
GO

-- Call the build procedure.
GRANT EXECUTE ON SCHEMA::curated TO [$(DataFactoryName)];
GO

-- Read Parquet through OPENROWSET at all. Serverless-specific; without it
-- every view above fails even though SELECT was granted.
GRANT ADMINISTER DATABASE BULK OPERATIONS TO [$(DataFactoryName)];
GO

-- CETAS creates an external table, so the caller must be able to create tables
-- and to alter the schema it creates them in.
GRANT CREATE TABLE     TO [$(DataFactoryName)];
GRANT ALTER ON SCHEMA::curated TO [$(DataFactoryName)];
GO

-- CETAS resolves DATA_SOURCE and FILE_FORMAT by name; resolving them requires
-- ALTER ANY, which is SQL's (badly named) permission for "may reference".
GRANT ALTER ANY EXTERNAL DATA SOURCE TO [$(DataFactoryName)];
GRANT ALTER ANY EXTERNAL FILE FORMAT TO [$(DataFactoryName)];
GO

-- The external data sources use cred_LakeManagedIdentity. Without REFERENCES
-- the query fails with a credential-not-found error that implies the credential
-- is missing rather than inaccessible.
GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::cred_LakeManagedIdentity TO [$(DataFactoryName)];
GO

/* ===========================================================================
   2. Analyst read access

   A database role rather than direct grants, so that adding a team next
   quarter is one ALTER ROLE rather than an archaeology exercise.

   NOTE ON THE STORAGE SIDE: these principals also need Storage Blob Data
   Reader on the lake, granted by infra/terraform/rbac.tf
   (synapse_admins_lake_reader). Serverless passes the CALLER'S identity
   through for any external data source without a credential, so a user with
   SQL rights and no storage rights gets "content of directory cannot be
   listed" - a storage error surfaced as if it were a path problem.
   =========================================================================== */

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'edw_analyst' AND type = 'R')
BEGIN
    PRINT 'Creating role edw_analyst...';
    CREATE ROLE edw_analyst AUTHORIZATION dbo;
END
GO

GRANT SELECT  ON SCHEMA::curated TO edw_analyst;
GRANT SELECT  ON SCHEMA::serving TO edw_analyst;
GRANT SELECT  ON SCHEMA::raw     TO edw_analyst;
GRANT ADMINISTER DATABASE BULK OPERATIONS TO edw_analyst;
GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::cred_LakeManagedIdentity TO edw_analyst;
GO

-- Explicitly withheld from edw_analyst, so the omission reads as a decision:
--   CREATE TABLE                    (no CETAS - analysts cannot write curated)
--   ALTER ANY EXTERNAL DATA SOURCE  (cannot repoint a data source at another account)
--   EXECUTE ON SCHEMA::curated      (cannot run the build procedures)
-- Analysts who need scratch write space use the `sandbox` filesystem and
-- eds_sandbox, which is lifecycle-deleted after 30 days.

/* ===========================================================================
   3. The Synapse administrator group

   Already sysadmin-equivalent on the serverless endpoint by virtue of being
   the workspace's SQL Entra administrator (set by
   azurerm_synapse_workspace_sql_aad_admin in Terraform). No grant is needed
   here, and attempting CREATE USER for it raises
   "User, group, or role already exists" on some workspaces.

   The block below is therefore a report, not a grant.
   =========================================================================== */

PRINT '';
PRINT 'Database principals in [$(DatabaseName)]:';
SELECT
    PrincipalName = dp.name,
    PrincipalType = dp.type_desc,
    CreatedUtc    = dp.create_date
FROM sys.database_principals AS dp
WHERE dp.type IN ('E', 'X', 'S', 'R')       -- external user, external group, SQL user, role
  AND dp.name NOT LIKE 'db_%'
  AND dp.name NOT IN ('public', 'guest', 'INFORMATION_SCHEMA', 'sys', 'dbo')
ORDER BY dp.type_desc, dp.name;
GO

PRINT '';
PRINT 'Explicit permissions granted:';
SELECT
    Grantee    = dp.name,
    Permission = perm.permission_name,
    OnObject   = COALESCE(SCHEMA_NAME(perm.major_id), '(database)'),
    State      = perm.state_desc
FROM sys.database_permissions AS perm
JOIN sys.database_principals AS dp ON dp.principal_id = perm.grantee_principal_id
WHERE dp.name IN (N'$(DataFactoryName)', N'edw_analyst')
ORDER BY dp.name, perm.permission_name;
GO
