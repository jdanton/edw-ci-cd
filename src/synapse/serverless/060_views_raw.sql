/* =============================================================================
   060_views_raw.sql
   CONTEXT: $(DatabaseName)
   =============================================================================

   Views over the RAW landing zone. Source vocabulary, source types, no
   cleaning, no filtering. If a row is garbage, it appears here as garbage -
   that is the point. When someone asks "did we receive that trip?", this is
   the layer that answers.

   -----------------------------------------------------------------------------
   OPENROWSET vs external tables for the raw layer
   -----------------------------------------------------------------------------
   Raw is exposed through OPENROWSET views rather than CREATE EXTERNAL TABLE,
   for one decisive reason: filepath().

   filepath(n) returns the text matched by the n-th wildcard in the BULK path,
   which is how partition folder values become columns. External tables cannot
   do this - they have no notion of Hive-style partitioning - so an external
   table over raw would force every query to scan all 70+ month folders even
   when the caller filters to one month. On this dataset that is the difference
   between scanning 40 MB and 40 GB, and serverless bills per byte scanned.

   The WITH clause is explicit rather than inferred. Schema inference costs an
   extra metadata round trip per query, and - worse - it makes the view's shape
   depend on whichever file the engine happens to sample. An explicit contract
   means a source schema change fails loudly here instead of silently changing
   downstream column types.

   -----------------------------------------------------------------------------
   Verifying the source schema yourself
   -----------------------------------------------------------------------------
   Microsoft has changed the Open Datasets NYC TLC schema before. Before
   trusting the WITH clause below, run util/inspect_source_schema.sql - it uses
   sp_describe_first_result_set over an inference query to print the actual
   column names and types found in the files.

   -----------------------------------------------------------------------------
   Path layout produced by PL_Ingest_NycTaxi_Yellow
   -----------------------------------------------------------------------------
     raw/nyctlc/yellow/puYear=<YYYY>/puMonth=<M>/<part-files>.parquet
                              ^wildcard 1     ^wildcard 2
   Note puMonth is NOT zero-padded: the source publishes puMonth=1, not
   puMonth=01, and the ingest pipeline preserves that. Hence CAST(... AS INT)
   below rather than string comparison.
   ============================================================================= */

USE [$(DatabaseName)];
GO

SET NOCOUNT ON;
GO

CREATE OR ALTER VIEW raw.vw_YellowTaxiTrip
AS
SELECT
    /* Partition columns, recovered from the folder names. Filtering on these
       lets serverless skip whole folders without opening a single file. */
    PickupYear  = CAST(src.filepath(1) AS INT),
    PickupMonth = CAST(src.filepath(2) AS INT),

    /* Source columns, source names, source types. Renaming belongs in the
       curated layer, not here. */
    src.vendorID,
    src.tpepPickupDateTime,
    src.tpepDropoffDateTime,
    src.passengerCount,
    src.tripDistance,
    src.puLocationId,
    src.doLocationId,
    src.rateCodeId,
    src.storeAndFwdFlag,
    src.paymentType,
    src.fareAmount,
    src.extra,
    src.mtaTax,
    src.improvementSurcharge,
    src.tipAmount,
    src.tollsAmount,
    src.totalAmount,

    /* Lineage. filename() is the Parquet part file the row came from - the
       single most useful column when someone disputes a number. */
    SourceFileName = src.filename()
FROM OPENROWSET(
        BULK 'nyctlc/yellow/puYear=*/puMonth=*/*.parquet',
        DATA_SOURCE = 'eds_raw',
        FORMAT = 'PARQUET'
     )
     WITH (
        vendorID             VARCHAR(10)   ,
        tpepPickupDateTime   DATETIME2(7)  ,
        tpepDropoffDateTime  DATETIME2(7)  ,
        passengerCount       INT           ,
        tripDistance         FLOAT         ,
        puLocationId         VARCHAR(10)   ,
        doLocationId         VARCHAR(10)   ,
        rateCodeId           INT           ,
        storeAndFwdFlag      VARCHAR(1)    ,
        paymentType          VARCHAR(10)   ,
        fareAmount           FLOAT         ,
        extra                FLOAT         ,
        mtaTax               FLOAT         ,
        improvementSurcharge VARCHAR(20)   ,
        tipAmount            FLOAT         ,
        tollsAmount          FLOAT         ,
        totalAmount          FLOAT
     ) AS src;
GO

/* -----------------------------------------------------------------------------
   Reference data: the TLC taxi zone lookup.

   Uploaded to raw/nyctlc/reference/taxi_zone_lookup.csv by
   scripts/Initialize-ReferenceData.ps1. It is a CSV rather than Parquet
   because that is how the TLC publishes it, and converting it during upload
   would violate the "raw holds what we received" rule.

   HEADER_ROW = TRUE requires PARSER_VERSION 2.0, which is also the faster
   parser. FIELDTERMINATOR is explicit because the file has quoted fields
   containing commas ("Newark Airport, EWR").
   ----------------------------------------------------------------------------- */
CREATE OR ALTER VIEW raw.vw_TaxiZoneLookup
AS
SELECT
    LocationID   = CAST(src.LocationID AS INT),
    Borough      = src.Borough,
    Zone         = src.Zone,
    ServiceZone  = src.service_zone
FROM OPENROWSET(
        BULK 'nyctlc/reference/taxi_zone_lookup.csv',
        DATA_SOURCE = 'eds_raw',
        FORMAT = 'CSV',
        PARSER_VERSION = '2.0',
        HEADER_ROW = TRUE,
        FIELDTERMINATOR = ',',
        FIELDQUOTE = '"'
     )
     WITH (
        LocationID   VARCHAR(10)  ,
        Borough      VARCHAR(50)  ,
        Zone         VARCHAR(100) ,
        service_zone VARCHAR(50)
     ) AS src;
GO

PRINT 'Raw views created: raw.vw_YellowTaxiTrip, raw.vw_TaxiZoneLookup';
GO
