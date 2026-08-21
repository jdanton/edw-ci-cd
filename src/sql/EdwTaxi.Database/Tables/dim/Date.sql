/* =============================================================================
   dim.Date
   =============================================================================

   Standard calendar dimension, populated by
   Scripts/PostDeploy/010_DimDate.sql for the year range given by the
   $(DimDateStartYear) / $(DimDateEndYear) SQLCMD variables.

   DateKey is an INT in YYYYMMDD form rather than an IDENTITY surrogate. That
   is a deliberate, and slightly unfashionable, choice:

     * It is human-readable. `WHERE DateKey = 20240115` in a support ticket
       needs no lookup, and a wrong join shows up immediately as a nonsense
       number rather than as a plausible-looking integer.
     * It sorts chronologically, so a clustered index on it is also a
       chronological index.
     * It is stable across environments and rebuilds. An IDENTITY surrogate is
       not, which makes comparing dev and prod row-for-word impossible.

   The cost is four bytes versus a smaller key and a small loss of purity. Both
   are worth it.
   ============================================================================= */

CREATE TABLE [dim].[Date]
(
    [DateKey]            INT           NOT NULL,   -- YYYYMMDD
    [FullDate]           DATE          NOT NULL,

    [DayOfMonth]         TINYINT       NOT NULL,
    [DayOfYear]          SMALLINT      NOT NULL,
    [DayOfWeek]          TINYINT       NOT NULL,   -- 1 = Monday .. 7 = Sunday (ISO)
    [DayName]            VARCHAR(10)   NOT NULL,
    [DayNameShort]       CHAR(3)       NOT NULL,

    [WeekOfYear]         TINYINT       NOT NULL,   -- ISO 8601 week
    [IsoYear]            SMALLINT      NOT NULL,   -- ISO week-numbering year

    [MonthNumber]        TINYINT       NOT NULL,
    [MonthName]          VARCHAR(10)   NOT NULL,
    [MonthNameShort]     CHAR(3)       NOT NULL,
    [MonthYearLabel]     CHAR(8)       NOT NULL,   -- 'Jan 2024'
    [FirstDayOfMonth]    DATE          NOT NULL,
    [LastDayOfMonth]     DATE          NOT NULL,

    [QuarterNumber]      TINYINT       NOT NULL,
    [QuarterLabel]       CHAR(7)       NOT NULL,   -- '2024 Q1'

    [CalendarYear]       SMALLINT      NOT NULL,
    [YearMonthNumber]    INT           NOT NULL,   -- 202401, matches the lake partition

    [IsWeekend]          BIT           NOT NULL,
    [IsUsFederalHoliday] BIT           NOT NULL
        CONSTRAINT [DF_dim_Date_IsUsFederalHoliday] DEFAULT (0),
    [HolidayName]        VARCHAR(50)   NULL,

    CONSTRAINT [PK_dim_Date] PRIMARY KEY CLUSTERED ([DateKey] ASC),
    CONSTRAINT [UQ_dim_Date_FullDate] UNIQUE NONCLUSTERED ([FullDate] ASC),
    /* -1 is the Unknown member (see dim.Vendor's header for why every
       dimension has one). Admitting it in the constraint is better than
       disabling and re-enabling the constraint around the insert: a constraint
       re-enabled WITH NOCHECK becomes "not trusted", which silently removes it
       from the optimiser's consideration for every future query. */
    CONSTRAINT [CK_dim_Date_DateKey]
        CHECK ([DateKey] = -1 OR [DateKey] BETWEEN 19000101 AND 29991231)
);
GO

/* YearMonthNumber is how every fact query slices to a lake partition, so it
   earns its own index. */
CREATE NONCLUSTERED INDEX [IX_dim_Date_YearMonthNumber]
    ON [dim].[Date] ([YearMonthNumber] ASC)
    INCLUDE ([FullDate], [MonthYearLabel]);
GO
