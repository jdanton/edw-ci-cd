/* =============================================================================
   080_views_curated.sql
   CONTEXT: $(DatabaseName)
   =============================================================================

   The public face of the lake.

     curated.vw_YellowTaxiTrip           every built partition, one view
     curated.vw_YellowTaxiTrip_Rejected  what the build threw away, and why
     curated.vw_TaxiZone                 conformed reference data
     serving.vw_YellowTaxiTripDaily      pre-aggregated daily grain
     serving.vw_YellowTaxiTripByZone     denormalised zone-level shape

   -----------------------------------------------------------------------------
   Why these are OPENROWSET views and not a UNION over the external tables
   -----------------------------------------------------------------------------
   Same reason as the raw layer: only OPENROWSET exposes filepath(), and
   filepath() is what turns a folder name into a prunable predicate. A view
   defined as a UNION ALL over ext_YellowTaxiTrip_202401, _202402, ... would
   also need editing every single month, which is a maintenance trap nobody
   remembers until a month is missing from a report.

   With the OPENROWSET form, a new partition appears in this view the moment
   CETAS writes its folder. No DDL, no deployment.

   -----------------------------------------------------------------------------
   Cost note for whoever queries these
   -----------------------------------------------------------------------------
   ALWAYS filter on PickupYear and PickupMonth. They are folder-derived, so a
   filter on them skips folders without reading files. A filter on PickupDate
   alone does NOT prune - serverless must open every file to evaluate it.

       SELECT ... WHERE PickupYear = 2024 AND PickupMonth = 3   -- ~40 MB scanned
       SELECT ... WHERE PickupDate = '2024-03-15'               -- whole lake

   The second form is how a five-dollar query becomes a five-hundred-dollar
   query. modules/alerts watches for it.
   ============================================================================= */

USE [$(DatabaseName)];
GO

SET NOCOUNT ON;
GO

/* ===========================================================================
   curated.vw_YellowTaxiTrip
   =========================================================================== */
CREATE OR ALTER VIEW curated.vw_YellowTaxiTrip
AS
SELECT
    PickupYear  = CAST(c.filepath(1) AS INT),
    PickupMonth = CAST(c.filepath(2) AS INT),
    c.TripKey,
    c.VendorId,
    c.PickupDateTime,
    c.DropoffDateTime,
    c.PickupDate,
    c.TripDurationSeconds,
    c.PassengerCount,
    c.TripDistanceMiles,
    c.PickupLocationId,
    c.DropoffLocationId,
    c.RateCodeId,
    c.StoreAndForwardFlag,
    c.PaymentTypeId,
    c.FareAmount,
    c.ExtraAmount,
    c.MtaTaxAmount,
    c.ImprovementSurchargeAmount,
    c.TipAmount,
    c.TollsAmount,
    c.TotalAmount,
    c.SourceFileName,
    c.CuratedAtUtc
FROM OPENROWSET(
        BULK 'nyctlc/yellow_trip/PickupYear=*/PickupMonth=*/*.parquet',
        DATA_SOURCE = 'eds_curated',
        FORMAT = 'PARQUET'
     )
     WITH (
        TripKey                    BINARY(16)   ,
        VendorId                   SMALLINT     ,
        PickupDateTime             DATETIME2(7) ,
        DropoffDateTime            DATETIME2(7) ,
        PickupDate                 DATE         ,
        TripDurationSeconds        INT          ,
        PassengerCount             SMALLINT     ,
        TripDistanceMiles          DECIMAL(9,3) ,
        PickupLocationId           SMALLINT     ,
        DropoffLocationId          SMALLINT     ,
        RateCodeId                 SMALLINT     ,
        StoreAndForwardFlag        VARCHAR(1)   ,
        PaymentTypeId              SMALLINT     ,
        FareAmount                 DECIMAL(10,2),
        ExtraAmount                DECIMAL(10,2),
        MtaTaxAmount               DECIMAL(10,2),
        ImprovementSurchargeAmount DECIMAL(10,2),
        TipAmount                  DECIMAL(10,2),
        TollsAmount                DECIMAL(10,2),
        TotalAmount                DECIMAL(10,2),
        SourceFileName             VARCHAR(400) ,
        CuratedAtUtc               DATETIME2(7)
     ) AS c;
GO

/* ===========================================================================
   curated.vw_YellowTaxiTrip_Rejected

   The inverse of the predicates in curated.usp_Build_Yellow_Monthly, computed
   on demand against raw. Nothing is written for it, so it costs nothing until
   somebody asks "where did those 4,102 rows go?" - and then it answers
   precisely, per row, with a named reason.

   KEEP THIS IN STEP with the WHERE clause in 070_procs_curate.sql. If you add
   a quality rule there and not here, rows will vanish with reason unknown,
   which is worse than not having this view at all.
   =========================================================================== */
CREATE OR ALTER VIEW curated.vw_YellowTaxiTrip_Rejected
AS
WITH ranked AS (
    SELECT
        r.*,
        DuplicateRank = ROW_NUMBER() OVER (
            PARTITION BY r.vendorID, r.tpepPickupDateTime, r.tpepDropoffDateTime,
                         r.puLocationId, r.doLocationId, r.totalAmount
            ORDER BY r.SourceFileName)
    FROM raw.vw_YellowTaxiTrip AS r
)
SELECT
    ranked.PickupYear,
    ranked.PickupMonth,
    RejectReason =
        CASE
            WHEN ranked.tpepPickupDateTime IS NULL                                    THEN 'NullPickupTimestamp'
            WHEN ranked.tpepPickupDateTime <  DATEFROMPARTS(ranked.PickupYear, ranked.PickupMonth, 1)
              OR ranked.tpepPickupDateTime >= DATEADD(MONTH, 1, DATEFROMPARTS(ranked.PickupYear, ranked.PickupMonth, 1))
                                                                                       THEN 'PartitionMismatch'
            WHEN ranked.tpepDropoffDateTime < ranked.tpepPickupDateTime                THEN 'NegativeDuration'
            WHEN ranked.tripDistance   < 0                                             THEN 'NegativeDistance'
            WHEN ranked.totalAmount    < 0                                             THEN 'NegativeAmount'
            WHEN ranked.passengerCount < 0                                             THEN 'NegativePassengers'
            WHEN ranked.DuplicateRank  > 1                                             THEN 'Duplicate'
            ELSE NULL
        END,
    ranked.vendorID,
    ranked.tpepPickupDateTime,
    ranked.tpepDropoffDateTime,
    ranked.passengerCount,
    ranked.tripDistance,
    ranked.totalAmount,
    ranked.SourceFileName
FROM ranked
WHERE
       ranked.tpepPickupDateTime IS NULL
    OR ranked.tpepPickupDateTime <  DATEFROMPARTS(ranked.PickupYear, ranked.PickupMonth, 1)
    OR ranked.tpepPickupDateTime >= DATEADD(MONTH, 1, DATEFROMPARTS(ranked.PickupYear, ranked.PickupMonth, 1))
    OR ranked.tpepDropoffDateTime < ranked.tpepPickupDateTime
    OR ranked.tripDistance   < 0
    OR ranked.totalAmount    < 0
    OR ranked.passengerCount < 0
    OR ranked.DuplicateRank  > 1;
GO

/* ===========================================================================
   curated.vw_TaxiZone - conformed reference data.

   Trivial here (a rename and a cast), and included anyway, so that every
   consumer reads reference data from `curated` like everything else instead of
   reaching into `raw` for this one table. Consistency at the boundary is worth
   more than the four lines it costs.
   =========================================================================== */
CREATE OR ALTER VIEW curated.vw_TaxiZone
AS
SELECT
    TaxiZoneId  = z.LocationID,
    Borough     = z.Borough,
    ZoneName    = z.Zone,
    ServiceZone = z.ServiceZone
FROM raw.vw_TaxiZoneLookup AS z;
GO

/* ===========================================================================
   serving.vw_YellowTaxiTripDaily

   Daily grain. This is what a "how did revenue trend?" question should hit -
   it reads the same Parquet but projects only six columns, so serverless scans
   a fraction of the bytes a SELECT * would.
   =========================================================================== */
CREATE OR ALTER VIEW serving.vw_YellowTaxiTripDaily
AS
SELECT
    t.PickupYear,
    t.PickupMonth,
    t.PickupDate,
    t.PaymentTypeId,
    TripCount          = COUNT_BIG(*),
    TotalPassengers    = SUM(CAST(t.PassengerCount AS BIGINT)),
    TotalDistanceMiles = SUM(t.TripDistanceMiles),
    TotalFareAmount    = SUM(t.FareAmount),
    TotalTipAmount     = SUM(t.TipAmount),
    TotalAmount        = SUM(t.TotalAmount),
    AvgTripMinutes     = AVG(CAST(t.TripDurationSeconds AS DECIMAL(12,2))) / 60.0
FROM curated.vw_YellowTaxiTrip AS t
GROUP BY
    t.PickupYear,
    t.PickupMonth,
    t.PickupDate,
    t.PaymentTypeId;
GO

/* ===========================================================================
   serving.vw_YellowTaxiTripByZone

   Denormalised trip-and-zone shape for map visuals. Joining to a 265-row
   reference set is cheap; the reason this exists as a view is so that the
   LEFT JOIN semantics (keep trips whose zone code is unknown, rather than
   silently dropping them) are decided once, here, rather than by whoever
   writes the next Power BI query.
   =========================================================================== */
CREATE OR ALTER VIEW serving.vw_YellowTaxiTripByZone
AS
SELECT
    t.PickupYear,
    t.PickupMonth,
    t.PickupDate,
    PickupBorough  = pu.Borough,
    PickupZone     = pu.ZoneName,
    DropoffBorough = doz.Borough,
    DropoffZone    = doz.ZoneName,
    TripCount          = COUNT_BIG(*),
    TotalDistanceMiles = SUM(t.TripDistanceMiles),
    TotalAmount        = SUM(t.TotalAmount)
FROM curated.vw_YellowTaxiTrip AS t
LEFT JOIN curated.vw_TaxiZone AS pu  ON pu.TaxiZoneId  = t.PickupLocationId
LEFT JOIN curated.vw_TaxiZone AS doz ON doz.TaxiZoneId = t.DropoffLocationId
GROUP BY
    t.PickupYear,
    t.PickupMonth,
    t.PickupDate,
    pu.Borough,
    pu.ZoneName,
    doz.Borough,
    doz.ZoneName;
GO

PRINT 'Curated and serving views created.';
GO
