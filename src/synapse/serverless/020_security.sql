/* =============================================================================
   020_security.sql
   CONTEXT: $(DatabaseName)
   =============================================================================

   Master key + the database scoped credential that lets serverless read and
   write the lake as the WORKSPACE MANAGED IDENTITY.

   -----------------------------------------------------------------------------
   Why a credential at all, when the workspace identity already has RBAC?
   -----------------------------------------------------------------------------
   Serverless supports three ways of authenticating to storage:

     1. No credential on the external data source
        -> serverless passes THE CALLER'S Entra identity through.
           Great for ad-hoc analyst queries (their own RBAC applies), useless
           for a pipeline, because ADF's identity would then need direct blob
           RBAC AND the query would behave differently depending on who ran it.

     2. IDENTITY = 'Managed Identity'          <-- what we use
        -> serverless uses the WORKSPACE identity regardless of caller.
           Deterministic, auditable, and grantable in exactly one place
           (infra/terraform/rbac.tf: synapse_lake_contributor).

     3. SHARED ACCESS SIGNATURE
        -> a secret with an expiry that will lapse at 02:00 on a Sunday.
           Not used here. The lake has shared_access_key_enabled = false, so
           this is not even available.

   -----------------------------------------------------------------------------
   The master key
   -----------------------------------------------------------------------------
   A DATABASE SCOPED CREDENTIAL must be encrypted, and encryption needs a
   master key. Even for 'Managed Identity', where there is no secret material
   to protect, SQL requires it. The password below therefore protects nothing
   of value - but it is still generated randomly per environment and passed in
   from the deployment script rather than hard-coded, because a fixed literal
   in a template repository has a way of ending up in a production system.

   You never need this password again: serverless opens the key automatically.
   It is NOT stored in Key Vault, deliberately - storing a secret that grants
   nothing simply creates another thing to rotate.

   -----------------------------------------------------------------------------
   Variables
   -----------------------------------------------------------------------------
     $(DatabaseName)
     $(MasterKeyPassword)   random per deployment, from Deploy-ServerlessSql.ps1
   ============================================================================= */

USE [$(DatabaseName)];
GO

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
BEGIN
    PRINT 'Creating database master key...';
    EXEC (N'CREATE MASTER KEY ENCRYPTION BY PASSWORD = ''$(MasterKeyPassword)'';');
END
ELSE
BEGIN
    PRINT 'Database master key already exists - leaving it alone.';
    /* Re-creating it would invalidate every existing credential. */
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = 'cred_LakeManagedIdentity')
BEGIN
    PRINT 'Creating database scoped credential cred_LakeManagedIdentity...';
    CREATE DATABASE SCOPED CREDENTIAL cred_LakeManagedIdentity
        WITH IDENTITY = 'Managed Identity';
END
ELSE
BEGIN
    PRINT 'Credential cred_LakeManagedIdentity already exists.';
END
GO
