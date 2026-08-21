/* =============================================================================
   meta.LoadAudit
   =============================================================================

   One row per load attempt. Opened by etl.usp_Start_Load, closed by
   etl.usp_Complete_Load, and stamped onto every fact row via LoadId.

   This table is the difference between "the numbers look wrong" being a
   half-day investigation and a two-minute query. It answers:

     * Which run inserted this row?           fact.* JOIN meta.LoadAudit
     * Has this partition ever loaded?        WHERE PartitionKey = '2024-01'
     * How long does the load normally take?  AVG(DurationSeconds)
     * Which ADF run failed, and where?       PipelineRunId -> ADF monitor

   PipelineRunId is the ADF run GUID, so it links straight into the ADF Studio
   monitor and into ADFPipelineRun in Log Analytics.
   ============================================================================= */

CREATE TABLE [meta].[LoadAudit]
(
    [LoadId]          BIGINT        IDENTITY(1,1) NOT NULL,

    [PipelineName]    VARCHAR(200)  NOT NULL,
    [PipelineRunId]   VARCHAR(50)   NULL,          -- ADF run GUID
    [TargetObject]    VARCHAR(200)  NOT NULL,      -- e.g. fact.YellowTaxiTrip
    [PartitionKey]    VARCHAR(50)   NULL,          -- e.g. 2024-01

    [Status]          VARCHAR(20)   NOT NULL
        CONSTRAINT [DF_meta_LoadAudit_Status] DEFAULT ('Running'),

    [StartedAtUtc]    DATETIME2(3)  NOT NULL
        CONSTRAINT [DF_meta_LoadAudit_StartedAtUtc] DEFAULT (SYSUTCDATETIME()),
    [CompletedAtUtc]  DATETIME2(3)  NULL,

    /* Persisted rather than computed on read: a computed column referencing
       SYSUTCDATETIME() cannot be persisted, and reporting on load durations
       should not depend on when you happen to run the report. */
    [DurationSeconds] AS (DATEDIFF(SECOND, [StartedAtUtc], [CompletedAtUtc])),

    [RowsStaged]      BIGINT        NULL,
    [RowsDeleted]     BIGINT        NULL,
    [RowsInserted]    BIGINT        NULL,

    [Message]         NVARCHAR(2000) NULL,

    CONSTRAINT [PK_meta_LoadAudit] PRIMARY KEY CLUSTERED ([LoadId] ASC),
    CONSTRAINT [CK_meta_LoadAudit_Status]
        CHECK ([Status] IN ('Running', 'Succeeded', 'Failed', 'Cancelled'))
);
GO

/* Supports the "is this partition already loading?" guard in
   etl.usp_Start_Load, which is a hot path at the start of every run. */
CREATE NONCLUSTERED INDEX [IX_meta_LoadAudit_Target_Partition_Status]
    ON [meta].[LoadAudit] ([TargetObject] ASC, [PartitionKey] ASC, [Status] ASC)
    INCLUDE ([StartedAtUtc], [CompletedAtUtc]);
GO

CREATE NONCLUSTERED INDEX [IX_meta_LoadAudit_StartedAtUtc]
    ON [meta].[LoadAudit] ([StartedAtUtc] DESC)
    INCLUDE ([PipelineName], [Status], [PartitionKey]);
GO
