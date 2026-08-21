/* =============================================================================
   030_DataQualityRules.sql   (post-deploy, idempotent)
   =============================================================================

   Seeds meta.DataQualityRule.

   Every rule's SQL must return EXACTLY ONE ROW with ONE COLUMN named
   FailedCount, and may reference the bound parameters @PickupYear and
   @PickupMonth. etl.usp_RunDataQualityChecks enforces that contract and reports
   a violation as a rule authoring error rather than as a data failure.

   Choosing severity is the part worth thinking about:

     Blocking - would produce a WRONG NUMBER in a report. Fail the load; an
                absent partition is noticed, a wrong one is not.
     Warning  - worth watching, does not invalidate anything. Recorded and
                trended, does not stop the pipeline.

   FailureThreshold exists because some badness is expected and stable. The TLC
   publishes a few hundred zero-passenger trips every month. Alerting on that
   every month trains people to ignore the alert, which costs you the alert you
   actually needed.
   ============================================================================= */

PRINT 'Post-deploy 030: data quality rules';
GO

MERGE meta.DataQualityRule AS target
USING (VALUES
    (
        1,
        'NoNullTripKey',
        'fact.YellowTaxiTrip',
        'Blocking',
        1,
        0,
        N'SELECT FailedCount = COUNT_BIG(*) FROM fact.YellowTaxiTrip WHERE PickupYear = @PickupYear AND PickupMonth = @PickupMonth AND TripKey IS NULL;',
        N'TripKey is the deduplication and lineage key. A NULL means the curated hash failed, which breaks idempotency: a re-run would insert duplicates rather than replacing rows.'
    ),
    (
        2,
        'NoUnresolvedPickupDate',
        'fact.YellowTaxiTrip',
        'Blocking',
        1,
        0,
        N'SELECT FailedCount = COUNT_BIG(*) FROM fact.YellowTaxiTrip WHERE PickupYear = @PickupYear AND PickupMonth = @PickupMonth AND PickupDateKey = -1;',
        N'A pickup date that resolved to the Unknown member. rpt.vw_YellowTaxiTripDaily INNER JOINs dim.Date, so these rows would appear against "Unknown" in every date-sliced report.'
    ),
    (
        3,
        'PartitionContainsOnlyItsOwnMonth',
        'fact.YellowTaxiTrip',
        'Blocking',
        1,
        0,
        N'SELECT FailedCount = COUNT_BIG(*) FROM fact.YellowTaxiTrip WHERE PickupYear = @PickupYear AND PickupMonth = @PickupMonth AND (YEAR(PickupDateTime) <> @PickupYear OR MONTH(PickupDateTime) <> @PickupMonth);',
        N'Guards against partition leakage. The merge deletes and re-inserts by (PickupYear, PickupMonth), so a stray row from another month would be inserted by this month''s load and deleted by that month''s - silently vanishing. See the header of src/synapse/serverless/070_procs_curate.sql.'
    ),
    (
        4,
        'NoNegativeTotalAmount',
        'fact.YellowTaxiTrip',
        'Blocking',
        1,
        0,
        N'SELECT FailedCount = COUNT_BIG(*) FROM fact.YellowTaxiTrip WHERE PickupYear = @PickupYear AND PickupMonth = @PickupMonth AND TotalAmount < 0;',
        N'The curated layer already excludes negative totals. A non-zero count here means data reached the fact table without passing through curated.usp_Build_Yellow_Monthly - i.e. someone loaded staging by hand.'
    ),
    (
        5,
        'UnknownVendorRateWithinTolerance',
        'fact.YellowTaxiTrip',
        'Warning',
        1,
        5000,
        N'SELECT FailedCount = COUNT_BIG(*) FROM fact.YellowTaxiTrip WHERE PickupYear = @PickupYear AND PickupMonth = @PickupMonth AND VendorKey = -1;',
        N'A surge in Unknown vendors usually means the TLC added a vendor code that dim.Vendor does not know about. Warning, not blocking: the revenue is still counted correctly, it is just attributed to "Unknown" until someone adds the code to Scripts/PostDeploy/020_ReferenceDimensions.sql.'
    ),
    (
        6,
        'UnknownPickupZoneRateWithinTolerance',
        'fact.YellowTaxiTrip',
        'Warning',
        1,
        20000,
        N'SELECT FailedCount = COUNT_BIG(*) FROM fact.YellowTaxiTrip WHERE PickupYear = @PickupYear AND PickupMonth = @PickupMonth AND PickupZoneKey = -1;',
        N'Zone 264/265 ("Unknown"/"Outside of NYC") are legitimately common, so the tolerance is generous. A count far above it usually means dim.TaxiZone was never loaded from the lake - check scripts/Initialize-ReferenceData.ps1 ran.'
    ),
    (
        7,
        'RowCountWithinExpectedRange',
        'fact.YellowTaxiTrip',
        'Warning',
        1,
        0,
        N'SELECT FailedCount = CASE WHEN COUNT_BIG(*) BETWEEN 500000 AND 20000000 THEN 0 ELSE 1 END FROM fact.YellowTaxiTrip WHERE PickupYear = @PickupYear AND PickupMonth = @PickupMonth;',
        N'A month outside 0.5M-20M trips is implausible for NYC yellow taxi. Catches a partially transferred Copy activity that "succeeded" with a fraction of the data. Returns 1 or 0 rather than a count - the rule contract only requires a single number, not literally a row count.'
    ),
    (
        8,
        'TipsOnlyOnCardPayments',
        'fact.YellowTaxiTrip',
        'Warning',
        1,
        100,
        N'SELECT FailedCount = COUNT_BIG(*) FROM fact.YellowTaxiTrip AS f JOIN dim.PaymentType AS pt ON pt.PaymentTypeKey = f.PaymentTypeKey WHERE f.PickupYear = @PickupYear AND f.PickupMonth = @PickupMonth AND pt.IsTipRecorded = 0 AND f.TipAmount > 0;',
        N'The meter cannot record a cash tip, so a non-zero tip on a non-card payment means either a source change or a mis-mapped payment type. Small counts occur naturally in restated months.'
    ),
    (
        9,
        'CongestionSurchargePresentFrom2019',
        'fact.YellowTaxiTrip',
        'Warning',
        1,
        0,
        N'SELECT FailedCount = CASE WHEN @PickupYear >= 2019 AND NOT EXISTS (SELECT 1 FROM fact.YellowTaxiTrip WHERE PickupYear = @PickupYear AND PickupMonth = @PickupMonth AND CongestionSurchargeAmount IS NOT NULL) THEN 1 ELSE 0 END;',
        N'From 2019 the TLC records a congestion surcharge on Manhattan trips. A month with no non-NULL value at all means the column was dropped upstream or the curated build did not pick it up. Warning rather than Blocking: the rest of the row is still correct. Deliberately silent before 2019, when the charge did not exist.'
    )
) AS source (RuleId, RuleName, TargetObject, Severity, IsEnabled, FailureThreshold, RuleSql, [Description])
    ON target.RuleId = source.RuleId
WHEN MATCHED THEN
    UPDATE SET
        target.RuleName         = source.RuleName,
        target.TargetObject     = source.TargetObject,
        target.Severity         = source.Severity,
        target.RuleSql          = source.RuleSql,
        target.FailureThreshold = source.FailureThreshold,
        target.[Description]    = source.[Description]
        /* IsEnabled is deliberately NOT updated. An operator who disables a
           noisy rule at 02:00 during an incident should not find it silently
           re-enabled by the next deployment. Re-enable it on purpose. */
WHEN NOT MATCHED BY TARGET THEN
    INSERT (RuleId, RuleName, TargetObject, Severity, IsEnabled, FailureThreshold, RuleSql, [Description])
    VALUES (source.RuleId, source.RuleName, source.TargetObject, source.Severity,
            source.IsEnabled, source.FailureThreshold, source.RuleSql, source.[Description])
WHEN NOT MATCHED BY SOURCE THEN
    /* A rule removed from this script is removed from the database, so the
       script stays the single source of truth. Historical RESULTS are kept -
       meta.DataQualityResult has a foreign key, so this DELETE fails if any
       result rows reference the rule, which is the correct outcome: you must
       decide what to do with the history rather than losing it silently. */
    DELETE;

PRINT CONCAT('  meta.DataQualityRule: ', (SELECT COUNT(*) FROM meta.DataQualityRule), ' rules (',
             (SELECT COUNT(*) FROM meta.DataQualityRule WHERE IsEnabled = 1), ' enabled).');
GO
