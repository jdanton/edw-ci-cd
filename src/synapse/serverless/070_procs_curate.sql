/* =============================================================================
   070_procs_curate.sql
   CONTEXT: $(DatabaseName)
   =============================================================================

   curated.usp_Build_Yellow_Monthly - the transformation that turns one month of
   raw trip records into conformed curated Parquet, using CETAS.

   Called by ADF pipeline PL_Curate_NycTaxi_Yellow, one month per call.

   -----------------------------------------------------------------------------
   WHY DYNAMIC SQL
   -----------------------------------------------------------------------------
   CETAS requires the external table NAME and the output LOCATION to be
   literals. Both embed the partition, so both must be built as strings. Every
   value interpolated below is an INT that has already been range-checked - no
   caller-supplied text ever reaches the statement.

   -----------------------------------------------------------------------------
   WHY THE EXTERNAL TABLE IS PER-PARTITION AND THROWAWAY
   -----------------------------------------------------------------------------
   CETAS creates an external table as a side effect of writing files. We want
   the files; the table is a by-product. Consumers read curated.vw_YellowTaxiTrip
   (an OPENROWSET view over ALL partitions) rather than these tables, because
   only OPENROWSET supports filepath() partition pruning.

   So each call drops and re-creates ext_YellowTaxiTrip_<YYYYMM>. Keeping them
   around costs nothing and makes it obvious in sys.external_tables which
   partitions have been built.

   -----------------------------------------------------------------------------
   THE THING THAT WILL BITE YOU: CETAS CANNOT OVERWRITE
   -----------------------------------------------------------------------------
   DROP EXTERNAL TABLE removes metadata only. The Parquet files stay on disk,
   and the next CETAS to the same LOCATION fails with

       "Cannot create external table. External table location already exists."

   Serverless has no DELETE and cannot remove files. Something outside Synapse
   must clear the folder first. In this template that is the Delete activity in
   PL_Curate_NycTaxi_Yellow, which runs immediately before this procedure.

   If you call this procedure by hand, clear the folder by hand first:
       az storage fs directory delete -f curated --account-name <acct> \
         -n "nyctlc/yellow_trip/PickupYear=2024/PickupMonth=1" --auth-mode login -y

   -----------------------------------------------------------------------------
   THE OTHER THING: PARTITION LEAKAGE
   -----------------------------------------------------------------------------
   The raw folders are partitioned on the publisher's puYear/puMonth, but the
   TLC files genuinely contain rows whose tpepPickupDateTime falls in a
   different month - meter clock errors, trips crossing midnight on the 1st,
   and a small number of records with dates decades out.

   If those rows were carried through, curated PickupYear=2024/PickupMonth=1
   would contain January AND stray February rows. The Azure SQL load deletes and
   re-inserts by (PickupYear, PickupMonth), so those strays would be inserted by
   January's run, then deleted by February's run, and silently disappear.

   Hence the WHERE clause re-derives the partition from the TIMESTAMP, not the
   folder. Rows that do not belong are excluded, and are visible in
   curated.vw_YellowTaxiTrip_Rejected with reason 'PartitionMismatch'.
   ============================================================================= */

USE [$(DatabaseName)];
GO

SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE curated.usp_Build_Yellow_Monthly
    @puYear  INT,
    @puMonth INT,
    @Debug   BIT = 0        -- 1 prints the generated statement without running it
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ---------------------------------------------------------------------
       Guard the inputs. These values are concatenated into DDL below, so
       "it is an INT parameter" is necessary but not sufficient - a caller
       passing 0 or 99999 would produce a nonsense path that succeeds and
       writes data somewhere nobody looks.
       --------------------------------------------------------------------- */
    IF @puYear IS NULL OR @puYear < 2009 OR @puYear > YEAR(SYSUTCDATETIME()) + 1
    BEGIN
        RAISERROR('@puYear must be between 2009 and next year. Got %d. The TLC trip record series begins in 2009.', 16, 1, @puYear);
        RETURN;
    END

    IF @puMonth IS NULL OR @puMonth < 1 OR @puMonth > 12
    BEGIN
        RAISERROR('@puMonth must be 1-12. Got %d.', 16, 1, @puMonth);
        RETURN;
    END

    DECLARE @tableName SYSNAME =
        CONCAT('ext_YellowTaxiTrip_', @puYear, RIGHT('0' + CAST(@puMonth AS VARCHAR(2)), 2));

    DECLARE @location NVARCHAR(400) =
        CONCAT('nyctlc/yellow_trip/PickupYear=', @puYear, '/PickupMonth=', @puMonth);

    DECLARE @sql NVARCHAR(MAX);

    /* ---------------------------------------------------------------------
       Drop the previous external table definition, if any.
       --------------------------------------------------------------------- */
    IF EXISTS (
        SELECT 1
        FROM sys.external_tables et
        JOIN sys.schemas s ON s.schema_id = et.schema_id
        WHERE s.name = 'curated' AND et.name = @tableName
    )
    BEGIN
        SET @sql = CONCAT(N'DROP EXTERNAL TABLE curated.', QUOTENAME(@tableName), N';');
        IF @Debug = 1 PRINT @sql; ELSE EXEC sp_executesql @sql;
    END

    /* ---------------------------------------------------------------------
       CETAS.

       Notes on the SELECT that follows:

       * Money columns become DECIMAL(10,2). The source stores them as
         doubles, and a double cannot represent 0.10 exactly. Summing tens of
         millions of doubles produces a total that differs run to run in the
         last decimal place - which is exactly the kind of thing a finance
         user notices and nobody can explain. Fix the type at the boundary.

       * improvementSurcharge is read as VARCHAR because the published files
         are inconsistent about it (some vintages store it as a string).
         TRY_CAST turns an unparseable value into NULL rather than failing the
         whole month.

       * DeDupe: the TLC files contain genuine exact-duplicate rows. The
         natural key is (vendor, pickup ts, dropoff ts, PU zone, DO zone,
         total). ROW_NUMBER + filter to 1 keeps the first and records the rest
         as rejected with reason 'Duplicate'.

       * TripDurationSeconds is derived once here rather than in every
         downstream query. DATEDIFF_BIG avoids the 68-year overflow that
         DATEDIFF(SECOND, ...) hits on the handful of rows with a 1970 pickup
         and a 2024 dropoff.
       --------------------------------------------------------------------- */
    /* -------------------------------------------------------------------
       CAST(N'' AS NVARCHAR(MAX)) is load-bearing, not decoration.

       Concatenating nvarchar(n) operands yields nvarchar(n1+n2...) CAPPED AT
       4000, and the surplus is dropped silently. Declaring @sql as
       NVARCHAR(MAX) does not save it: the truncation happens while the
       expression is evaluated, before the assignment. Seeding the chain with a
       MAX-typed empty string makes every subsequent concatenation MAX.

       This statement is ~4470 characters. It fit under the limit until
       CongestionSurchargeAmount added a column and its comment, and then the
       CETAS arrived at the server cut off mid-way, failing with a parse error
       ("Incorrect syntax near ...") that named a token in the middle of a
       perfectly good procedure and gave no hint that anything had been
       truncated. Any further column or comment would have done the same.
       ------------------------------------------------------------------- */
    SET @sql = CAST(N'' AS NVARCHAR(MAX)) + N'
CREATE EXTERNAL TABLE curated.' + QUOTENAME(@tableName) + N'
WITH (
    LOCATION    = ''' + @location + N''',
    DATA_SOURCE = eds_curated,
    FILE_FORMAT = ff_parquet_snappy
)
AS
SELECT
      PickupYear
    , PickupMonth
    , TripKey
    , VendorId
    , PickupDateTime
    , DropoffDateTime
    , PickupDate
    , TripDurationSeconds
    , PassengerCount
    , TripDistanceMiles
    , PickupLocationId
    , DropoffLocationId
    , RateCodeId
    , StoreAndForwardFlag
    , PaymentTypeId
    , FareAmount
    , ExtraAmount
    , MtaTaxAmount
    , ImprovementSurchargeAmount
    , TipAmount
    , TollsAmount
    , TotalAmount
    , CongestionSurchargeAmount
    , SourceFileName
    , CuratedAtUtc
FROM (
    SELECT
          PickupYear  = ' + CAST(@puYear AS NVARCHAR(4)) + N'
        , PickupMonth = ' + CAST(@puMonth AS NVARCHAR(2)) + N'

        /* Deterministic surrogate. A hash of the natural key means the same
           trip gets the same key on every rebuild, in every environment,
           which is what makes the Azure SQL merge idempotent. */
        , TripKey = CONVERT(BINARY(16), HASHBYTES(''MD5'',
              CONCAT_WS(''|'',
                  ISNULL(r.vendorID, ''''),
                  CONVERT(VARCHAR(27), r.tpepPickupDateTime, 121),
                  CONVERT(VARCHAR(27), r.tpepDropoffDateTime, 121),
                  ISNULL(r.puLocationId, ''''),
                  ISNULL(r.doLocationId, ''''),
                  CONVERT(VARCHAR(20), r.totalAmount))))

        , VendorId            = TRY_CAST(r.vendorID AS SMALLINT)
        , PickupDateTime      = r.tpepPickupDateTime
        , DropoffDateTime     = r.tpepDropoffDateTime
        , PickupDate          = CAST(r.tpepPickupDateTime AS DATE)
        , TripDurationSeconds = CAST(DATEDIFF_BIG(SECOND, r.tpepPickupDateTime, r.tpepDropoffDateTime) AS INT)
        , PassengerCount      = TRY_CAST(r.passengerCount AS SMALLINT)
        , TripDistanceMiles   = TRY_CAST(r.tripDistance AS DECIMAL(9,3))
        , PickupLocationId    = TRY_CAST(r.puLocationId AS SMALLINT)
        , DropoffLocationId   = TRY_CAST(r.doLocationId AS SMALLINT)
        , RateCodeId          = TRY_CAST(r.rateCodeId AS SMALLINT)
        , StoreAndForwardFlag = NULLIF(UPPER(LTRIM(RTRIM(r.storeAndFwdFlag))), '''')
        , PaymentTypeId       = TRY_CAST(r.paymentType AS SMALLINT)

        , FareAmount                 = TRY_CAST(r.fareAmount AS DECIMAL(10,2))
        , ExtraAmount                = TRY_CAST(r.extra AS DECIMAL(10,2))
        , MtaTaxAmount               = TRY_CAST(r.mtaTax AS DECIMAL(10,2))
        , ImprovementSurchargeAmount = TRY_CAST(r.improvementSurcharge AS DECIMAL(10,2))
        , TipAmount                  = TRY_CAST(r.tipAmount AS DECIMAL(10,2))
        , TollsAmount                = TRY_CAST(r.tollsAmount AS DECIMAL(10,2))
        , TotalAmount                = TRY_CAST(r.totalAmount AS DECIMAL(10,2))

        /* ADDED. DECIMAL(10,2), not FLOAT, for the reason in the file header:
           a double cannot represent 0.10 exactly, so summing millions of them
           gives a total that differs run to run in the last decimal place.
           NULL for pre-2019 partitions, which is honest - the charge did not
           exist yet. */
        , CongestionSurchargeAmount  = TRY_CAST(r.congestionSurcharge AS DECIMAL(10,2))

        , SourceFileName = r.SourceFileName
        , CuratedAtUtc   = SYSUTCDATETIME()

        , DuplicateRank = ROW_NUMBER() OVER (
              PARTITION BY r.vendorID, r.tpepPickupDateTime, r.tpepDropoffDateTime,
                           r.puLocationId, r.doLocationId, r.totalAmount
              ORDER BY r.SourceFileName)
    FROM raw.vw_YellowTaxiTrip AS r
    WHERE
        /* Folder-level pruning. Cheap: serverless skips other folders without
           opening a file. */
            r.PickupYear  = ' + CAST(@puYear AS NVARCHAR(4)) + N'
        AND r.PickupMonth = ' + CAST(@puMonth AS NVARCHAR(2)) + N'

        /* Row-level partition truth. See "PARTITION LEAKAGE" in the header. */
        AND r.tpepPickupDateTime >= DATEFROMPARTS(' + CAST(@puYear AS NVARCHAR(4)) + N', ' + CAST(@puMonth AS NVARCHAR(2)) + N', 1)
        AND r.tpepPickupDateTime <  DATEADD(MONTH, 1, DATEFROMPARTS(' + CAST(@puYear AS NVARCHAR(4)) + N', ' + CAST(@puMonth AS NVARCHAR(2)) + N', 1))

        /* Quality predicates. Each one maps to a named reason in
           curated.vw_YellowTaxiTrip_Rejected - keep the two in step. */
        AND r.tpepDropoffDateTime >= r.tpepPickupDateTime          -- NegativeDuration
        AND ISNULL(r.tripDistance, 0)  >= 0                        -- NegativeDistance
        AND ISNULL(r.totalAmount, 0)   >= 0                        -- NegativeAmount
        AND ISNULL(r.passengerCount, 0) >= 0                       -- NegativePassengers
) AS q
WHERE q.DuplicateRank = 1;';

    IF @Debug = 1
    BEGIN
        PRINT @sql;
        RETURN;
    END

    BEGIN TRY
        EXEC sp_executesql @sql;
    END TRY
    BEGIN CATCH
        DECLARE @msg NVARCHAR(2048) = ERROR_MESSAGE();

        /* Translate the single most common failure into an actionable message.
           The native error names neither the folder nor the fix. */
        IF @msg LIKE N'%already exists%'
        BEGIN
            RAISERROR(
                N'CETAS could not write to curated/%s because files are already there. DROP EXTERNAL TABLE does not delete files - the folder must be cleared first. PL_Curate_NycTaxi_Yellow does this with a Delete activity; if you are running by hand, delete the folder and retry. Original error: %s',
                16, 1, @location, @msg);
            RETURN;
        END

        /* Serverless SQL has no THROW - the parser rejects it outright with
           "Incorrect syntax near 'THROW'", which then cascades into a second
           error on the END that closes this block, so the reported line is not
           the offending one. Re-raise with RAISERROR instead.

           The original text goes in as an ARGUMENT, not as the format string:
           a message containing a '%' - a LIKE pattern, or a percentage in a
           column name - would otherwise be read as a format specifier and
           either mangle the message or fail the RAISERROR itself.

           RETURN is not optional. THROW aborted the batch; RAISERROR does not,
           so without it execution falls through to the success PRINT below and
           a failed build reports that it built. */
        RAISERROR(N'%s', 16, 1, @msg);
        RETURN;
    END CATCH

    PRINT CONCAT('Built curated.', @tableName, ' at curated/', @location);
END
GO

PRINT 'Created curated.usp_Build_Yellow_Monthly';
GO
