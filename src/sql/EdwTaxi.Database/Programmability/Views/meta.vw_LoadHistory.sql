/* =============================================================================
   meta.vw_LoadHistory
   =============================================================================

   The operations view. Open this first during an incident - it is the query
   docs/11-operations-runbook.md tells you to run.

   One row per load, with the data quality outcome folded in, so you can see
   "it succeeded but three warnings fired" without a second query.
   ============================================================================= */

CREATE VIEW [meta].[vw_LoadHistory]
AS
SELECT
    la.LoadId,
    la.PipelineName,
    la.PipelineRunId,
    la.TargetObject,
    la.PartitionKey,
    la.Status,
    la.StartedAtUtc,
    la.CompletedAtUtc,
    la.DurationSeconds,
    DurationMinutes = CONVERT(DECIMAL(10,1), la.DurationSeconds / 60.0),
    la.RowsStaged,
    la.RowsDeleted,
    la.RowsInserted,

    /* Staged minus inserted. Non-zero means rows were dropped between staging
       and fact - almost always the NULL-pickup guard in the merge. */
    RowsDropped = la.RowsStaged - la.RowsInserted,

    DqRulesRun      = ISNULL(dq.RulesRun, 0),
    DqRulesFailed   = ISNULL(dq.RulesFailed, 0),
    DqBlockingFailed = ISNULL(dq.BlockingFailed, 0),

    la.Message
FROM meta.LoadAudit AS la
OUTER APPLY (
    SELECT
        RulesRun       = COUNT_BIG(*),
        RulesFailed    = SUM(CASE WHEN r.Passed = 0 THEN 1 ELSE 0 END),
        BlockingFailed = SUM(CASE WHEN r.Passed = 0 AND r.Severity = 'Blocking' THEN 1 ELSE 0 END)
    FROM meta.DataQualityResult AS r
    WHERE r.LoadId = la.LoadId
) AS dq;
GO
