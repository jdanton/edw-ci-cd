/* =============================================================================
   010_DimDate.sql   (post-deploy, idempotent)
   =============================================================================

   Populates dim.Date for $(DimDateStartYear) .. $(DimDateEndYear).

   Only MISSING dates are inserted, so re-running is cheap and extending the
   range later is a one-line tfvars change plus a deploy.

   The generator is a recursive CTE rather than a WHILE loop: one set-based
   statement instead of ~10,000 round trips. OPTION (MAXRECURSION 0) is
   required because the default cap is 100.

   ISO 8601 week numbering (ISO_WEEK) is used deliberately. The US convention
   (DATEPART(WEEK)) puts 1 January in week 1 regardless of weekday, which makes
   week 1 and week 53 partial and breaks any year-over-year weekly comparison.
   ============================================================================= */

PRINT 'Post-deploy 010: dim.Date';
GO

DECLARE @startDate DATE = DATEFROMPARTS($(DimDateStartYear), 1, 1);
DECLARE @endDate   DATE = DATEFROMPARTS($(DimDateEndYear), 12, 31);

;WITH dates AS (
    SELECT d = @startDate
    UNION ALL
    SELECT DATEADD(DAY, 1, d) FROM dates WHERE d < @endDate
)
INSERT INTO dim.Date
(
    DateKey, FullDate,
    DayOfMonth, DayOfYear, [DayOfWeek], DayName, DayNameShort,
    WeekOfYear, IsoYear,
    MonthNumber, MonthName, MonthNameShort, MonthYearLabel,
    FirstDayOfMonth, LastDayOfMonth,
    QuarterNumber, QuarterLabel,
    CalendarYear, YearMonthNumber,
    IsWeekend, IsUsFederalHoliday
)
SELECT
    DateKey        = CONVERT(INT, CONVERT(CHAR(8), dates.d, 112)),
    FullDate       = dates.d,

    DayOfMonth     = CONVERT(TINYINT,  DAY(dates.d)),
    DayOfYear      = CONVERT(SMALLINT, DATEPART(DAYOFYEAR, dates.d)),

    /* ISO day numbering: Monday = 1 .. Sunday = 7, independent of DATEFIRST.
       DATEPART(WEEKDAY) is session-dependent and will differ between your
       laptop and the ADF connection, which is the sort of bug that produces
       "the weekend flag is wrong but only in production". */
    [DayOfWeek]    = CONVERT(TINYINT, (DATEDIFF(DAY, '19000101', dates.d) % 7) + 1),

    DayName        = DATENAME(WEEKDAY, dates.d),
    DayNameShort   = CONVERT(CHAR(3), LEFT(DATENAME(WEEKDAY, dates.d), 3)),

    WeekOfYear     = CONVERT(TINYINT,  DATEPART(ISO_WEEK, dates.d)),
    IsoYear        = CONVERT(SMALLINT,
                        CASE
                            WHEN MONTH(dates.d) = 1  AND DATEPART(ISO_WEEK, dates.d) > 50 THEN YEAR(dates.d) - 1
                            WHEN MONTH(dates.d) = 12 AND DATEPART(ISO_WEEK, dates.d) = 1  THEN YEAR(dates.d) + 1
                            ELSE YEAR(dates.d)
                        END),

    MonthNumber    = CONVERT(TINYINT, MONTH(dates.d)),
    MonthName      = DATENAME(MONTH, dates.d),
    MonthNameShort = CONVERT(CHAR(3), LEFT(DATENAME(MONTH, dates.d), 3)),
    MonthYearLabel = CONVERT(CHAR(8), LEFT(DATENAME(MONTH, dates.d), 3) + ' ' + CONVERT(CHAR(4), YEAR(dates.d))),

    FirstDayOfMonth = DATEFROMPARTS(YEAR(dates.d), MONTH(dates.d), 1),
    LastDayOfMonth  = EOMONTH(dates.d),

    QuarterNumber  = CONVERT(TINYINT, DATEPART(QUARTER, dates.d)),
    QuarterLabel   = CONVERT(CHAR(7), CONVERT(CHAR(4), YEAR(dates.d)) + ' Q' + CONVERT(CHAR(1), DATEPART(QUARTER, dates.d))),

    CalendarYear   = CONVERT(SMALLINT, YEAR(dates.d)),
    YearMonthNumber = (YEAR(dates.d) * 100) + MONTH(dates.d),

    IsWeekend      = CONVERT(BIT, CASE WHEN ((DATEDIFF(DAY, '19000101', dates.d) % 7) + 1) IN (6, 7) THEN 1 ELSE 0 END),
    IsUsFederalHoliday = CONVERT(BIT, 0)
FROM dates
WHERE NOT EXISTS (
    SELECT 1 FROM dim.Date AS existing
    WHERE existing.DateKey = CONVERT(INT, CONVERT(CHAR(8), dates.d, 112))
)
OPTION (MAXRECURSION 0);

PRINT CONCAT('  dim.Date now holds ', (SELECT COUNT(*) FROM dim.Date), ' rows.');
GO

/* -----------------------------------------------------------------------------
   The -1 Unknown member.

   Fact rows whose pickup timestamp cannot be resolved to a real date land
   here. There should be none - etl.usp_Merge_YellowTaxiTrip filters NULL
   pickup timestamps - but a warehouse that has nowhere to put an unresolvable
   key fails the load instead of reporting the problem, and a failed load at
   03:00 is a worse outcome than one row against 'Unknown'.

   CK_dim_Date_DateKey explicitly permits -1, so no constraint gymnastics are
   needed here. See the comment on that constraint.

   FullDate is 1900-01-01 rather than NULL because the column is NOT NULL and
   because a sentinel that sorts before all real data keeps the Unknown row at
   the top of any date-ordered report, where somebody will see it.
   ----------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM dim.Date WHERE DateKey = -1)
BEGIN
    PRINT '  Adding the Unknown date member (DateKey = -1).';

    INSERT INTO dim.Date
    (
        DateKey, FullDate, DayOfMonth, DayOfYear, [DayOfWeek], DayName, DayNameShort,
        WeekOfYear, IsoYear, MonthNumber, MonthName, MonthNameShort, MonthYearLabel,
        FirstDayOfMonth, LastDayOfMonth, QuarterNumber, QuarterLabel,
        CalendarYear, YearMonthNumber, IsWeekend, IsUsFederalHoliday
    )
    VALUES
    (
        -1, '1900-01-01', 1, 1, 1, 'Unknown', 'UNK',
        1, 1900, 1, 'Unknown', 'UNK', 'Unknown ',
        '1900-01-01', '1900-01-31', 1, 'Unknown',
        1900, 190001, 0, 0
    );
END
GO
