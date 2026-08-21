/* =============================================================================
   meta.DataQualityRule
   =============================================================================

   Data quality rules as DATA, not as code.

   etl.usp_RunDataQualityChecks reads this table and executes each rule's SQL.
   The alternative - a procedure with twelve hard-coded IF blocks - means every
   new check is a schema change, a pull request and a deployment. Rules as rows
   mean a new check is an INSERT, which is exactly the right friction for
   something a data steward should be able to propose.

   Each rule's SQL must return ONE ROW with ONE column named FailedCount.
   Anything else is a rule authoring error and is reported as such.

   Severity:
     Blocking - RAISERROR, the ADF activity fails, the load is not marked
                Succeeded. Use for anything that would produce a wrong number.
     Warning  - recorded in meta.DataQualityResult and visible in the runbook
                query, but the load continues. Use for things worth watching
                that do not invalidate the data.
   ============================================================================= */

CREATE TABLE [meta].[DataQualityRule]
(
    [RuleId]        SMALLINT      NOT NULL,
    [RuleName]      VARCHAR(100)  NOT NULL,
    [TargetObject]  VARCHAR(200)  NOT NULL,
    [Severity]      VARCHAR(10)   NOT NULL,
    [IsEnabled]     BIT           NOT NULL
        CONSTRAINT [DF_meta_DataQualityRule_IsEnabled] DEFAULT (1),

    /* Must SELECT exactly one row, one column, aliased FailedCount.
       @PickupYear and @PickupMonth are available as parameters. */
    [RuleSql]       NVARCHAR(MAX) NOT NULL,

    /* Tolerance: a rule fails only when FailedCount exceeds this. Some
       badness is expected and known - the TLC publishes a small number of
       trips with a zero passenger count every month, and alerting on it every
       month trains people to ignore the alert. */
    [FailureThreshold] BIGINT     NOT NULL
        CONSTRAINT [DF_meta_DataQualityRule_FailureThreshold] DEFAULT (0),

    [Description]   NVARCHAR(1000) NULL,

    CONSTRAINT [PK_meta_DataQualityRule] PRIMARY KEY CLUSTERED ([RuleId] ASC),
    CONSTRAINT [UQ_meta_DataQualityRule_RuleName] UNIQUE NONCLUSTERED ([RuleName] ASC),
    CONSTRAINT [CK_meta_DataQualityRule_Severity]
        CHECK ([Severity] IN ('Blocking', 'Warning'))
);
GO
