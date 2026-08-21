/* =============================================================================
   etl.usp_Merge_YellowTaxiTrip
   =============================================================================

   Publishes one month from stg.YellowTaxiTrip into fact.YellowTaxiTrip.

   -----------------------------------------------------------------------------
   WHY THIS IS NOT A `MERGE` STATEMENT
   -----------------------------------------------------------------------------
   The name is conventional; the implementation is DELETE-then-INSERT of a whole
   partition, inside one transaction. That is deliberate:

     1. T-SQL MERGE has a long, well-documented history of correctness bugs
        (see Aaron Bertrand's catalogue of them). Several are unfixed. For a
        statement that decides what is in a warehouse, "usually correct" is not
        a category that exists.

     2. MERGE on a clustered columnstore performs badly. It resolves to
        row-by-row updates, which on a columnstore means marking rows deleted
        in the delta store and appending new versions. Repeated over months the
        table fragments and query performance degrades in a way that is
        invisible until it is severe.

     3. Partition replacement matches the SOURCE's semantics. The TLC restates
        months. When they do, the correct action is "this month is now that
        set of rows", not "reconcile row by row" - and a whole-partition swap
        expresses that directly, is trivially idempotent, and needs no
        assumption that the natural key is stable across a restatement.

   The cost is that a re-run rewrites the whole month even if one row changed.
   At ~3M rows a month into a columnstore, that is seconds. Worth it.

   -----------------------------------------------------------------------------
   DIMENSION KEY RESOLUTION
   -----------------------------------------------------------------------------
   Every LEFT JOIN is followed by ISNULL(..., -1). That pairing is the whole
   Unknown-member contract:

     LEFT JOIN  - a missing dimension member must never drop a fact row.
     ISNULL -1  - but the key must never be NULL either, or every downstream
                  INNER JOIN silently drops the row instead.

   Rows that land on -1 are counted by etl.usp_RunDataQualityChecks, so an
   unexpected surge in Unknowns surfaces as a data quality failure rather than
   as a quietly shrinking report.
   ============================================================================= */

CREATE PROCEDURE [etl].[usp_Merge_YellowTaxiTrip]
    @LoadId      BIGINT,
    @PickupYear  INT,
    @PickupMonth INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @PickupYear IS NULL OR @PickupYear < 2009 OR @PickupYear > YEAR(SYSUTCDATETIME()) + 1
    BEGIN
        RAISERROR('@PickupYear must be between 2009 and next year. Got %d.', 16, 1, @PickupYear);
        RETURN;
    END

    IF @PickupMonth IS NULL OR @PickupMonth < 1 OR @PickupMonth > 12
    BEGIN
        RAISERROR('@PickupMonth must be 1-12. Got %d.', 16, 1, @PickupMonth);
        RETURN;
    END

    DECLARE @rowsStaged   BIGINT = (SELECT COUNT_BIG(*) FROM stg.YellowTaxiTrip);
    DECLARE @rowsDeleted  BIGINT = 0;
    DECLARE @rowsInserted BIGINT = 0;

    /* -----------------------------------------------------------------------
       Refuse to publish an empty staging table.

       Without this guard, a Copy activity that silently transferred zero rows
       would DELETE the existing partition and INSERT nothing - turning a
       transient upstream problem into deleted production data. The most
       destructive bug in this entire template is the one this IF prevents.
       ----------------------------------------------------------------------- */
    IF @rowsStaged = 0
    BEGIN
        RAISERROR(
            'stg.YellowTaxiTrip is empty. Refusing to replace fact partition %d-%d with nothing. Check the Copy activity in PL_Load_Sql_YellowTrip and the curated partition it read from.',
            16, 1, @PickupYear, @PickupMonth);
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

            /* ---------------------------------------------------------------
               Remove the existing partition.

               No index is needed for this to be fast: rows are inserted one
               month at a time, so each columnstore rowgroup holds a single
               month and segment elimination skips the rest. See the header of
               fact.YellowTaxiTrip.
               --------------------------------------------------------------- */
            DELETE FROM fact.YellowTaxiTrip
            WHERE PickupYear  = @PickupYear
              AND PickupMonth = @PickupMonth;

            SET @rowsDeleted = @@ROWCOUNT;

            /* ---------------------------------------------------------------
               Insert the new one.
               --------------------------------------------------------------- */
            INSERT INTO fact.YellowTaxiTrip
            (
                TripKey,
                PickupYear, PickupMonth,
                PickupDateKey, DropoffDateKey,
                VendorKey, RateCodeKey, PaymentTypeKey,
                PickupZoneKey, DropoffZoneKey,
                PickupDateTime, DropoffDateTime, StoreAndForwardFlag,
                PassengerCount, TripDistanceMiles, TripDurationSeconds,
                FareAmount, ExtraAmount, MtaTaxAmount, ImprovementSurchargeAmount,
                TipAmount, TollsAmount, TotalAmount,
                LoadId, LoadedAtUtc
            )
            SELECT
                s.TripKey,
                @PickupYear,
                @PickupMonth,

                /* Date keys are computed, not joined. dim.Date is guaranteed to
                   cover the range by Scripts/PostDeploy/010_DimDate.sql, and
                   arithmetic beats two joins over three million rows. */
                PickupDateKey  = ISNULL(
                                    CONVERT(INT, CONVERT(CHAR(8), s.PickupDateTime, 112)),
                                    -1),
                DropoffDateKey = ISNULL(
                                    CONVERT(INT, CONVERT(CHAR(8), s.DropoffDateTime, 112)),
                                    -1),

                VendorKey      = ISNULL(v.VendorKey,      -1),
                RateCodeKey    = ISNULL(rc.RateCodeKey,   -1),
                PaymentTypeKey = ISNULL(pt.PaymentTypeKey, -1),
                PickupZoneKey  = ISNULL(puz.TaxiZoneKey,  -1),
                DropoffZoneKey = ISNULL(doz.TaxiZoneKey,  -1),

                /* DATETIME2(0) in the fact table: the meter records whole
                   seconds, so the extra precision carried through the lake is
                   noise that costs storage on every one of a hundred million
                   rows. */
                PickupDateTime      = CONVERT(DATETIME2(0), s.PickupDateTime),
                DropoffDateTime     = CONVERT(DATETIME2(0), s.DropoffDateTime),
                StoreAndForwardFlag = CONVERT(CHAR(1), NULLIF(s.StoreAndForwardFlag, '')),

                s.PassengerCount,
                s.TripDistanceMiles,
                s.TripDurationSeconds,
                s.FareAmount,
                s.ExtraAmount,
                s.MtaTaxAmount,
                s.ImprovementSurchargeAmount,
                s.TipAmount,
                s.TollsAmount,
                s.TotalAmount,

                @LoadId,
                SYSUTCDATETIME()
            FROM stg.YellowTaxiTrip AS s
            LEFT JOIN dim.Vendor      AS v   ON v.VendorId        = s.VendorId
            LEFT JOIN dim.RateCode    AS rc  ON rc.RateCodeId     = s.RateCodeId
            LEFT JOIN dim.PaymentType AS pt  ON pt.PaymentTypeId  = s.PaymentTypeId
            LEFT JOIN dim.TaxiZone    AS puz ON puz.TaxiZoneId    = s.PickupLocationId
            LEFT JOIN dim.TaxiZone    AS doz ON doz.TaxiZoneId    = s.DropoffLocationId
            /* Defence in depth: the curated layer already enforces this, but a
               hand-loaded staging table would not. */
            WHERE s.PickupDateTime IS NOT NULL;

            SET @rowsInserted = @@ROWCOUNT;

            UPDATE meta.LoadAudit
            SET RowsStaged   = @rowsStaged,
                RowsDeleted  = @rowsDeleted,
                RowsInserted = @rowsInserted
            WHERE LoadId = @LoadId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        DECLARE @errMsg NVARCHAR(2000) = ERROR_MESSAGE();

        UPDATE meta.LoadAudit
        SET Message = LEFT(CONCAT('usp_Merge_YellowTaxiTrip failed: ', @errMsg), 2000)
        WHERE LoadId = @LoadId;

        THROW;
    END CATCH

    PRINT CONCAT(
        'Partition ', @PickupYear, '-', @PickupMonth,
        ': staged ', @rowsStaged,
        ', deleted ', @rowsDeleted,
        ', inserted ', @rowsInserted, '.');
END
GO
