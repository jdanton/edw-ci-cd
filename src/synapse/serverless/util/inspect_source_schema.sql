/* =============================================================================
   util/inspect_source_schema.sql
   NOT part of the deployment sequence - run it by hand.
   =============================================================================

   Microsoft has changed the Azure Open Datasets NYC TLC schema before, and the
   explicit WITH clause in 060_views_raw.sql will break loudly when they do
   again. This script tells you what is actually in the files right now.

   Run it from Synapse Studio, or:

     ./scripts/Invoke-ServerlessQuery.ps1 `
        -Environment dev `
        -File src/synapse/serverless/util/inspect_source_schema.sql

   ============================================================================= */

USE [edw_lake];   -- adjust if you renamed the database
GO

/* ---------------------------------------------------------------------------
   1. What columns and types does serverless infer from the RAW files?

   Omitting the WITH clause makes serverless infer the schema from the Parquet
   footer. sp_describe_first_result_set then reports what it inferred.

   Read the `system_type_name` column: that is what your WITH clause must
   declare (or a type that safely widens it).
   --------------------------------------------------------------------------- */
EXEC sp_describe_first_result_set N'
    SELECT TOP (1) *
    FROM OPENROWSET(
        BULK ''nyctlc/yellow/puYear=*/puMonth=*/*.parquet'',
        DATA_SOURCE = ''eds_raw'',
        FORMAT = ''PARQUET''
    ) AS src;
';
GO

/* ---------------------------------------------------------------------------
   2. Eyeball a few rows.

   TOP (10) on an unfiltered OPENROWSET still opens at least one file per
   folder, so add a partition filter if the lake is large:

       ... ) AS src WHERE src.filepath(1) = '2024' AND src.filepath(2) = '1'
   --------------------------------------------------------------------------- */
SELECT TOP (10) *
FROM OPENROWSET(
        BULK 'nyctlc/yellow/puYear=2024/puMonth=1/*.parquet',
        DATA_SOURCE = 'eds_raw',
        FORMAT = 'PARQUET'
     ) AS src;
GO

/* ---------------------------------------------------------------------------
   3. Which partitions have actually landed in raw?

   Cheap: reads only the folder names, not the file contents.
   --------------------------------------------------------------------------- */
SELECT
    PickupYear  = src.filepath(1),
    PickupMonth = src.filepath(2),
    RowCount    = COUNT_BIG(*)
FROM OPENROWSET(
        BULK 'nyctlc/yellow/puYear=*/puMonth=*/*.parquet',
        DATA_SOURCE = 'eds_raw',
        FORMAT = 'PARQUET'
     ) AS src
GROUP BY src.filepath(1), src.filepath(2)
ORDER BY 1, 2;
GO

/* ---------------------------------------------------------------------------
   4. And which have been curated? Compare with (3) to find gaps.
   --------------------------------------------------------------------------- */
SELECT
    PickupYear  = c.filepath(1),
    PickupMonth = c.filepath(2),
    RowCount    = COUNT_BIG(*)
FROM OPENROWSET(
        BULK 'nyctlc/yellow_trip/PickupYear=*/PickupMonth=*/*.parquet',
        DATA_SOURCE = 'eds_curated',
        FORMAT = 'PARQUET'
     ) AS c
GROUP BY c.filepath(1), c.filepath(2)
ORDER BY 1, 2;
GO

/* ---------------------------------------------------------------------------
   5. How much did the queries above cost?

   dataProcessedBytes is what you are billed on. This DMV covers the current
   session; SynapseBuiltinSqlPoolRequestsEnded in Log Analytics covers everyone.
   --------------------------------------------------------------------------- */
SELECT TOP (20)
    r.command,
    r.start_time,
    DurationMs      = r.total_elapsed_time,
    DataProcessedMB = r.data_processed_mb
FROM sys.dm_exec_requests_history AS r
ORDER BY r.start_time DESC;
GO
