/* =============================================================================
   rpt.vw_YellowTaxiTripDaily
   =============================================================================

   The shape Power BI imports. Daily grain, dimensions resolved to names, one
   row per (date, vendor, payment type, pickup borough).

   Why a view rather than letting Power BI join the star itself:

     * The role-playing TaxiZone dimension is disambiguated ONCE here. Left to
       each report author, half of them will join PickupZoneKey and call it
       "the zone" and nobody will notice the other half did the opposite.
     * `TipAmountWhereRecorded` encodes the cash-tip caveat from
       dim.PaymentType in a column, so a report cannot accidentally average
       tips over cash trips and understate tipping by the cash share.
     * The partition columns stay in the projection, so an incremental-refresh
       policy in Power BI can fold a filter down to them.
   ============================================================================= */

CREATE VIEW [rpt].[vw_YellowTaxiTripDaily]
AS
SELECT
    d.FullDate,
    d.CalendarYear,
    d.MonthNumber,
    d.MonthYearLabel,
    d.QuarterLabel,
    d.DayName,
    d.IsWeekend,

    /* Retained so downstream incremental refresh can prune on them. */
    f.PickupYear,
    f.PickupMonth,

    v.VendorName,
    pt.PaymentTypeName,
    pt.IsTipRecorded,
    puz.Borough  AS PickupBorough,
    puz.ZoneName AS PickupZone,
    puz.IsAirport AS IsAirportPickup,
    rc.RateCodeName,

    TripCount          = COUNT_BIG(*),
    TotalPassengers    = SUM(CONVERT(BIGINT, f.PassengerCount)),
    TotalDistanceMiles = SUM(f.TripDistanceMiles),
    TotalFareAmount    = SUM(f.FareAmount),
    TotalTollsAmount   = SUM(f.TollsAmount),
    TotalAmount        = SUM(f.TotalAmount),

    /* ADDED. No GROUP BY change - it is an aggregate.

       SUM ignores NULLs, so a day before 2019 reports 0.00 rather than NULL.
       That is the conventional reading for a charge that did not exist, and
       it keeps the column addable without changing any existing number. */
    TotalCongestionSurcharge = SUM(f.CongestionSurchargeAmount),

    /* Tips are only metered on card payments. Summing TipAmount across all
       payment types produces a number that is correct and meaningless. */
    TipAmountWhereRecorded = SUM(CASE WHEN pt.IsTipRecorded = 1 THEN f.TipAmount ELSE 0 END),
    TripsWithRecordedTip   = SUM(CASE WHEN pt.IsTipRecorded = 1 THEN 1 ELSE 0 END),

    AvgTripMinutes     = AVG(CONVERT(DECIMAL(12,2), f.TripDurationSeconds)) / 60.0,
    AvgTripDistance    = AVG(f.TripDistanceMiles)

FROM fact.YellowTaxiTrip AS f
INNER JOIN dim.Date        AS d   ON d.DateKey        = f.PickupDateKey
INNER JOIN dim.Vendor      AS v   ON v.VendorKey      = f.VendorKey
INNER JOIN dim.PaymentType AS pt  ON pt.PaymentTypeKey = f.PaymentTypeKey
INNER JOIN dim.RateCode    AS rc  ON rc.RateCodeKey   = f.RateCodeKey
INNER JOIN dim.TaxiZone    AS puz ON puz.TaxiZoneKey  = f.PickupZoneKey
GROUP BY
    d.FullDate, d.CalendarYear, d.MonthNumber, d.MonthYearLabel,
    d.QuarterLabel, d.DayName, d.IsWeekend,
    f.PickupYear, f.PickupMonth,
    v.VendorName,
    pt.PaymentTypeName, pt.IsTipRecorded,
    puz.Borough, puz.ZoneName, puz.IsAirport,
    rc.RateCodeName;
GO
