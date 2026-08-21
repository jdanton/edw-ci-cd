/* =============================================================================
   040_file_formats_and_schemas.sql
   CONTEXT: $(DatabaseName)
   =============================================================================

   External file formats (used by CETAS) and the schema namespaces.

   -----------------------------------------------------------------------------
   Why only Parquet, and why Snappy
   -----------------------------------------------------------------------------
   The curated layer is written once and read many times, by Synapse serverless
   and by ADF's Copy activity. Snappy-compressed Parquet is the right default
   for that shape:

     * Columnar, so serverless reads only the columns a query projects. On a
       23-column trip table where the typical query touches four columns, that
       is roughly a 5x reduction in bytes scanned - and serverless bills on
       bytes scanned.
     * Snappy is splittable and cheap to decompress. GZIP compresses ~20-30%
       better but is meaningfully slower to decompress and, historically, has
       been the cause of more serverless timeout complaints than any other
       single setting.
     * Both ADF and Spark read it natively with no configuration.

   No CSV format is defined. If you need one, define it next to this comment
   rather than inline in a view, so that the "we accept CSV here" decision is
   visible in code review.

   -----------------------------------------------------------------------------
   Schemas
   -----------------------------------------------------------------------------
     raw       Views over the landing zone. Source vocabulary, source types,
               no cleaning. Reading these tells you what actually arrived.
     curated   Conformed layer. Our vocabulary, our types, quality rules
               applied. The CETAS output and the views over it live here.
     serving   Business-facing views: aggregates and denormalised shapes that
               analysts and Power BI query directly against the lake without
               going through Azure SQL.
     util     Helper procedures and diagnostics.
   ============================================================================= */

USE [$(DatabaseName)];
GO

SET NOCOUNT ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.external_file_formats WHERE name = 'ff_parquet_snappy')
BEGIN
    PRINT 'Creating external file format ff_parquet_snappy...';
    CREATE EXTERNAL FILE FORMAT ff_parquet_snappy
    WITH (
        FORMAT_TYPE = PARQUET,
        DATA_COMPRESSION = 'org.apache.hadoop.io.compress.SnappyCodec'
    );
END
ELSE
BEGIN
    PRINT 'External file format ff_parquet_snappy already exists.';
END
GO

/* Schemas. CREATE SCHEMA must be the only statement in its batch, hence the
   EXEC wrapper rather than a plain CREATE inside the IF. */

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'raw')
    EXEC (N'CREATE SCHEMA raw AUTHORIZATION dbo;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'curated')
    EXEC (N'CREATE SCHEMA curated AUTHORIZATION dbo;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'serving')
    EXEC (N'CREATE SCHEMA serving AUTHORIZATION dbo;');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'util')
    EXEC (N'CREATE SCHEMA util AUTHORIZATION dbo;');
GO

PRINT 'Schemas present:';
SELECT name FROM sys.schemas WHERE name IN ('raw', 'curated', 'serving', 'util') ORDER BY name;
GO
