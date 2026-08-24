/* =============================================================================
   020_ReferenceDimensions.sql   (post-deploy, idempotent)
   =============================================================================

   Seeds the small, stable dimensions from the TLC data dictionary, plus the
   Unknown (-1) member of every dimension.

   MERGE is used here, and NOT in etl.usp_Merge_YellowTaxiTrip. The distinction
   is not inconsistency:

     here                        the fact table
     ----------------------      -------------------------------------
     5-265 rows                  ~100,000,000 rows
     rowstore, clustered PK      clustered columnstore
     runs at deploy time         runs every night
     source is a literal list    source is a bulk-loaded staging table

   At this size MERGE is the clearest way to express "make the table look like
   this list", and none of the performance or correctness concerns that rule it
   out on the fact table apply.

   dim.TaxiZone gets ONLY its Unknown member here. The 265 real zones come from
   the lake (raw/nyctlc/reference/taxi_zone_lookup.csv, uploaded by
   scripts/Initialize-ReferenceData.ps1) because the TLC republishes them, and
   source data belongs in the pipeline rather than in a deployment script.
   ============================================================================= */

PRINT 'Post-deploy 020: reference dimensions';
GO

/* ---------------------------------------------------------------------------
   dim.Vendor
   Codes from the TLC "Yellow Trips Data Dictionary".
   --------------------------------------------------------------------------- */
MERGE dim.Vendor AS target
USING (VALUES
    (-1, NULL, 'Unknown',                              1),
    ( 1,    1, 'Creative Mobile Technologies, LLC',    0),
    ( 2,    2, 'VeriFone Inc.',                        0),
    ( 6,    6, 'Myle Technologies Inc',                0),
    ( 7,    7, 'Helix',                                0)
) AS source (VendorKey, VendorId, VendorName, IsUnknown)
    ON target.VendorKey = source.VendorKey
WHEN MATCHED AND (target.VendorName <> source.VendorName OR target.IsUnknown <> source.IsUnknown)
    THEN UPDATE SET
        target.VendorName = source.VendorName,
        target.IsUnknown  = source.IsUnknown
WHEN NOT MATCHED BY TARGET
    THEN INSERT (VendorKey, VendorId, VendorName, IsUnknown)
         VALUES (source.VendorKey, source.VendorId, source.VendorName, source.IsUnknown);

DECLARE @VendorRows int = (SELECT COUNT(*) FROM dim.Vendor);
PRINT CONCAT('  dim.Vendor: ', @VendorRows, ' rows.');
GO

/* ---------------------------------------------------------------------------
   dim.RateCode

   Note RateCodeId 99 is the TLC's OWN "unknown" code - the meter reported the
   fare as unclassified. That is a different fact from RateCodeKey -1, which
   means we could not interpret what the meter reported at all. Keeping them
   apart is the difference between "the driver did not set a rate code" and
   "our pipeline saw something it did not recognise".
   --------------------------------------------------------------------------- */
MERGE dim.RateCode AS target
USING (VALUES
    (-1, NULL, 'Unknown (not in code list)', 0, 1),
    ( 1,    1, 'Standard rate',              0, 0),
    ( 2,    2, 'JFK',                        1, 0),
    ( 3,    3, 'Newark',                     1, 0),
    ( 4,    4, 'Nassau or Westchester',      0, 0),
    ( 5,    5, 'Negotiated fare',            0, 0),
    ( 6,    6, 'Group ride',                 0, 0),
    (99,   99, 'Unknown (reported by meter)', 0, 0)
) AS source (RateCodeKey, RateCodeId, RateCodeName, IsFlatFare, IsUnknown)
    ON target.RateCodeKey = source.RateCodeKey
WHEN MATCHED AND (target.RateCodeName <> source.RateCodeName OR target.IsFlatFare <> source.IsFlatFare)
    THEN UPDATE SET
        target.RateCodeName = source.RateCodeName,
        target.IsFlatFare   = source.IsFlatFare,
        target.IsUnknown    = source.IsUnknown
WHEN NOT MATCHED BY TARGET
    THEN INSERT (RateCodeKey, RateCodeId, RateCodeName, IsFlatFare, IsUnknown)
         VALUES (source.RateCodeKey, source.RateCodeId, source.RateCodeName, source.IsFlatFare, source.IsUnknown);

DECLARE @RateCodeRows int = (SELECT COUNT(*) FROM dim.RateCode);
PRINT CONCAT('  dim.RateCode: ', @RateCodeRows, ' rows.');
GO

/* ---------------------------------------------------------------------------
   dim.PaymentType

   IsTipRecorded is 1 only for Credit card. The meter cannot see a cash tip,
   so TipAmount is structurally zero for every other payment type - not
   missing, not null, just absent from the world. rpt.vw_YellowTaxiTripDaily
   uses this flag so that no report averages tips across cash trips.
   --------------------------------------------------------------------------- */
MERGE dim.PaymentType AS target
USING (VALUES
    (-1, NULL, 'Unknown',      0, 1),
    ( 1,    1, 'Credit card',  1, 0),
    ( 2,    2, 'Cash',         0, 0),
    ( 3,    3, 'No charge',    0, 0),
    ( 4,    4, 'Dispute',      0, 0),
    ( 5,    5, 'Unknown',      0, 0),
    ( 6,    6, 'Voided trip',  0, 0)
) AS source (PaymentTypeKey, PaymentTypeId, PaymentTypeName, IsTipRecorded, IsUnknown)
    ON target.PaymentTypeKey = source.PaymentTypeKey
WHEN MATCHED AND (target.PaymentTypeName <> source.PaymentTypeName OR target.IsTipRecorded <> source.IsTipRecorded)
    THEN UPDATE SET
        target.PaymentTypeName = source.PaymentTypeName,
        target.IsTipRecorded   = source.IsTipRecorded,
        target.IsUnknown       = source.IsUnknown
WHEN NOT MATCHED BY TARGET
    THEN INSERT (PaymentTypeKey, PaymentTypeId, PaymentTypeName, IsTipRecorded, IsUnknown)
         VALUES (source.PaymentTypeKey, source.PaymentTypeId, source.PaymentTypeName, source.IsTipRecorded, source.IsUnknown);

DECLARE @PaymentTypeRows int = (SELECT COUNT(*) FROM dim.PaymentType);
PRINT CONCAT('  dim.PaymentType: ', @PaymentTypeRows, ' rows.');
GO

/* ---------------------------------------------------------------------------
   dim.TaxiZone - Unknown member only. Real zones arrive from the lake.
   --------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM dim.TaxiZone WHERE TaxiZoneKey = -1)
BEGIN
    INSERT INTO dim.TaxiZone (TaxiZoneKey, TaxiZoneId, Borough, ZoneName, ServiceZone, IsUnknown)
    VALUES (-1, NULL, 'Unknown', 'Unknown', NULL, 1);
END

DECLARE @TaxiZoneRows int = (SELECT COUNT(*) FROM dim.TaxiZone);
PRINT CONCAT('  dim.TaxiZone: ', @TaxiZoneRows,
             ' rows (265 real zones are loaded from the lake, not from here).');
GO
