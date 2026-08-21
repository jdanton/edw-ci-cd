/* =============================================================================
   meta.DataQualityResult
   =============================================================================
   One row per (load, rule). The history is the point: a rule that fails once
   is an incident, and a rule that has been quietly returning 400 failures
   every month for a year is a different, worse problem that only a trend
   reveals.
   ============================================================================= */

CREATE TABLE [meta].[DataQualityResult]
(
    [ResultId]      BIGINT        IDENTITY(1,1) NOT NULL,
    [LoadId]        BIGINT        NOT NULL,
    [RuleId]        SMALLINT      NOT NULL,

    [PickupYear]    SMALLINT      NULL,
    [PickupMonth]   TINYINT       NULL,

    [FailedCount]   BIGINT        NOT NULL,
    [Passed]        BIT           NOT NULL,
    [Severity]      VARCHAR(10)   NOT NULL,
    [CheckedAtUtc]  DATETIME2(3)  NOT NULL
        CONSTRAINT [DF_meta_DataQualityResult_CheckedAtUtc] DEFAULT (SYSUTCDATETIME()),
    [Message]       NVARCHAR(2000) NULL,

    CONSTRAINT [PK_meta_DataQualityResult] PRIMARY KEY CLUSTERED ([ResultId] ASC),

    /* Foreign keys ARE used here, unlike on the fact table. These are small,
       low-volume, single-row inserts where the integrity guarantee is worth
       far more than the per-row cost. */
    CONSTRAINT [FK_meta_DataQualityResult_LoadAudit]
        FOREIGN KEY ([LoadId]) REFERENCES [meta].[LoadAudit] ([LoadId]),
    CONSTRAINT [FK_meta_DataQualityResult_Rule]
        FOREIGN KEY ([RuleId]) REFERENCES [meta].[DataQualityRule] ([RuleId])
);
GO

CREATE NONCLUSTERED INDEX [IX_meta_DataQualityResult_LoadId]
    ON [meta].[DataQualityResult] ([LoadId] ASC)
    INCLUDE ([RuleId], [Passed], [FailedCount]);
GO

CREATE NONCLUSTERED INDEX [IX_meta_DataQualityResult_Rule_Checked]
    ON [meta].[DataQualityResult] ([RuleId] ASC, [CheckedAtUtc] DESC)
    INCLUDE ([FailedCount], [Passed]);
GO
