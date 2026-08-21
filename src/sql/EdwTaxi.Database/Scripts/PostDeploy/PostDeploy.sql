/* =============================================================================
   PostDeploy.sql
   =============================================================================

   Runs AFTER the schema is in place. DacFx allows exactly one post-deploy
   script, so this file is nothing but an ordered list of :r includes.

   EVERY INCLUDED SCRIPT MUST BE IDEMPOTENT. Post-deploy runs on every single
   deployment, not just the first. A plain INSERT that works beautifully on a
   fresh database will duplicate reference data on the second deploy and
   violate a unique constraint on the third - and it will do that in production,
   at the end of a change window.

   The pattern used throughout is MERGE against a VALUES-derived table, which
   is safe here (small, rowstore, dimension tables) for the same reasons it is
   the wrong tool on the columnstore fact table.

   Order matters: dimensions before the rules that reference them, principals
   last so that a permissions failure does not block the data.
   ============================================================================= */

:r ./010_DimDate.sql
:r ./020_ReferenceDimensions.sql
:r ./030_DataQualityRules.sql
:r ./040_ServicePrincipals.sql

PRINT '=========================================================================';
PRINT 'EdwTaxi.Database post-deployment complete';
PRINT '  Finished : ' + CONVERT(VARCHAR(30), SYSUTCDATETIME(), 126) + ' UTC';
PRINT '=========================================================================';
GO
