/* =============================================================================
   fact.YellowTaxiTrip
   =============================================================================

   Transaction-grain fact: one row per taxi trip. Roughly 3 million rows per
   month, so a few years of history is comfortably into nine figures.

   -----------------------------------------------------------------------------
   CLUSTERED COLUMNSTORE, and no rowstore index at all
   -----------------------------------------------------------------------------
   Everything about this table's access pattern says columnstore:

     * Written once per month in a single large batch, never updated in place.
     * Read by aggregate queries that touch 3-6 of the 20 columns.
     * Large enough that 10x compression is worth real money.

   Batch-mode execution and segment elimination do the rest. On the reference
   dataset, `SELECT SUM(TotalAmount) ... WHERE PickupYear = 2024` reads roughly
   40 MB of a 4 GB table.

   NO NONCLUSTERED INDEX ON (PickupYear, PickupMonth), deliberately, even
   though etl.usp_Merge_YellowTaxiTrip deletes by exactly that predicate.
   Because rows are inserted one month at a time, each rowgroup contains a
   single month, so the segment min/max metadata already eliminates every
   rowgroup but the target one - an index would add write cost during the bulk
   insert and buy nothing. If you ever start loading months out of order or
   interleaved, revisit this; run
       SELECT * FROM sys.dm_db_column_store_row_group_physical_stats
   to confirm segments are still month-aligned before assuming it still holds.

   -----------------------------------------------------------------------------
   NO FOREIGN KEYS
   -----------------------------------------------------------------------------
   Azure SQL supports foreign keys on columnstore tables, and they are still
   the wrong choice here:

     * They are checked row by row during the bulk insert, which is the single
       slowest part of the load.
     * They cannot prevent the failure mode that actually occurs - a dimension
       member missing at load time - because the ETL resolves unknowns to the
       -1 member before insert.

   Referential integrity is enforced by the key-resolution logic in
   etl.usp_Merge_YellowTaxiTrip and ASSERTED by etl.usp_RunDataQualityChecks
   after every load. A violation is a loud, named data quality failure rather
   than an opaque constraint error mid-transaction.

   -----------------------------------------------------------------------------
   TripKey
   -----------------------------------------------------------------------------
   BINARY(16): the MD5 of the natural key, computed in Synapse serverless
   (src/synapse/serverless/070_procs_curate.sql). Deterministic, so a rebuilt
   curated partition produces identical keys and the load stays idempotent.
   MD5 is used as a fingerprint, not a security primitive - collisions at this
   cardinality are a rounding error, and nothing about correctness depends on
   an adversary being unable to construct one.
   ============================================================================= */

CREATE TABLE [fact].[YellowTaxiTrip]
(
    [TripKey]                    BINARY(16)    NOT NULL,

    /* Partition columns. Every query and the entire merge predicate use these. */
    [PickupYear]                 SMALLINT      NOT NULL,
    [PickupMonth]                TINYINT       NOT NULL,

    /* Dimension keys. -1 means Unknown; never NULL. See dim.Vendor's header. */
    [PickupDateKey]              INT           NOT NULL,
    [DropoffDateKey]             INT           NOT NULL,
    [VendorKey]                  SMALLINT      NOT NULL,
    [RateCodeKey]                SMALLINT      NOT NULL,
    [PaymentTypeKey]             SMALLINT      NOT NULL,
    [PickupZoneKey]              SMALLINT      NOT NULL,
    [DropoffZoneKey]             SMALLINT      NOT NULL,

    /* Degenerate dimensions - attributes with no dimension table of their own. */
    [PickupDateTime]             DATETIME2(0)  NOT NULL,
    [DropoffDateTime]            DATETIME2(0)  NOT NULL,
    [StoreAndForwardFlag]        CHAR(1)       NULL,

    /* Measures. DECIMAL, not FLOAT - see the note in 070_procs_curate.sql
       about summing millions of doubles. */
    [PassengerCount]             SMALLINT      NULL,
    [TripDistanceMiles]          DECIMAL(9,3)  NULL,
    [TripDurationSeconds]        INT           NULL,
    [FareAmount]                 DECIMAL(10,2) NULL,
    [ExtraAmount]                DECIMAL(10,2) NULL,
    [MtaTaxAmount]               DECIMAL(10,2) NULL,
    [ImprovementSurchargeAmount] DECIMAL(10,2) NULL,
    [TipAmount]                  DECIMAL(10,2) NULL,
    [TollsAmount]                DECIMAL(10,2) NULL,
    [TotalAmount]                DECIMAL(10,2) NULL,

    /* Lineage. LoadId joins to meta.LoadAudit and answers "which run put this
       row here" - the first question of every data investigation. */
    [LoadId]                     BIGINT        NOT NULL,
    [LoadedAtUtc]                DATETIME2(3)  NOT NULL
);
GO

CREATE CLUSTERED COLUMNSTORE INDEX [CCI_fact_YellowTaxiTrip]
    ON [fact].[YellowTaxiTrip];
GO
