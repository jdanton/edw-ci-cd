/* =============================================================================
   etl.usp_RunDataQualityChecks
   =============================================================================

   Executes every enabled rule in meta.DataQualityRule against the partition
   just loaded, records the outcome in meta.DataQualityResult, and RAISERRORs
   if any Blocking rule failed.

   Called by PL_Load_Sql_YellowTrip after the merge. Failing here fails the
   activity, which fails the pipeline, which means meta.LoadAudit records
   'Failed' and someone is alerted - which is exactly the point. Data that is
   present but wrong is worse than data that is absent, because absent data is
   noticed.

   -----------------------------------------------------------------------------
   Executing SQL from a table
   -----------------------------------------------------------------------------
   Rule SQL comes from meta.DataQualityRule and is executed with sp_executesql.
   That is dynamic SQL sourced from a table, which deserves a straight answer
   rather than a disclaimer:

     * Only a member of the etl role or an administrator can INSERT a rule.
       Anyone who can do that can already run arbitrary SQL directly; the rule
       table adds no privilege.
     * @PickupYear and @PickupMonth are passed as BOUND PARAMETERS, never
       concatenated, so the values ADF supplies cannot alter the statement.
     * The result contract (one row, one column named FailedCount) is validated
       at runtime, so a malformed rule produces a clear authoring error rather
       than a confusing failure.

   The alternative - twelve hard-coded IF blocks - means every new check is a
   schema change and a deployment, which in practice means the checks do not
   get written.
   ============================================================================= */

CREATE PROCEDURE [etl].[usp_RunDataQualityChecks]
    @LoadId      BIGINT,
    @PickupYear  INT,
    @PickupMonth INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ruleId          SMALLINT,
            @ruleName        VARCHAR(100),
            @severity        VARCHAR(10),
            @ruleSql         NVARCHAR(MAX),
            @threshold       BIGINT,
            @failedCount     BIGINT,
            @blockingFailures INT = 0,
            @failureSummary  NVARCHAR(2000) = N'',
            @ruleError       NVARCHAR(2048),
            @firstError      NVARCHAR(2048);

    DECLARE @results TABLE (FailedCount BIGINT);

    DECLARE rule_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT RuleId, RuleName, Severity, RuleSql, FailureThreshold
        FROM meta.DataQualityRule
        WHERE IsEnabled = 1
          AND TargetObject = 'fact.YellowTaxiTrip'
        ORDER BY RuleId;

    OPEN rule_cursor;
    FETCH NEXT FROM rule_cursor INTO @ruleId, @ruleName, @severity, @ruleSql, @threshold;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DELETE FROM @results;
        SET @failedCount = NULL;

        BEGIN TRY
            INSERT INTO @results (FailedCount)
            EXEC sp_executesql
                 @ruleSql,
                 N'@PickupYear INT, @PickupMonth INT',
                 @PickupYear  = @PickupYear,
                 @PickupMonth = @PickupMonth;

            SELECT TOP (1) @failedCount = FailedCount FROM @results;

            IF @failedCount IS NULL
            BEGIN
                /* A rule that returns nothing is a broken rule, and treating
                   that as "passed" would hide it forever. */
                INSERT INTO meta.DataQualityResult
                    (LoadId, RuleId, PickupYear, PickupMonth, FailedCount, Passed, Severity, Message)
                VALUES
                    (@LoadId, @ruleId, @PickupYear, @PickupMonth, -1, 0, @severity,
                     CONCAT('Rule ''', @ruleName, ''' returned no rows. Its SQL must SELECT exactly one row with one column aliased FailedCount.'));

                SET @blockingFailures = @blockingFailures + 1;
                SET @failureSummary = CONCAT(@failureSummary, @ruleName, ' (malformed); ');
            END
            ELSE
            BEGIN
                DECLARE @passed BIT = CASE WHEN @failedCount <= @threshold THEN 1 ELSE 0 END;

                INSERT INTO meta.DataQualityResult
                    (LoadId, RuleId, PickupYear, PickupMonth, FailedCount, Passed, Severity, Message)
                VALUES
                    (@LoadId, @ruleId, @PickupYear, @PickupMonth, @failedCount, @passed, @severity,
                     CASE WHEN @passed = 1 THEN NULL
                          ELSE CONCAT(@failedCount, ' rows failed (threshold ', @threshold, ').')
                     END);

                IF @passed = 0 AND @severity = 'Blocking'
                BEGIN
                    SET @blockingFailures = @blockingFailures + 1;
                    SET @failureSummary = CONCAT(@failureSummary, @ruleName, '=', @failedCount, '; ');
                END
            END
        END TRY
        BEGIN CATCH
            /* One broken rule must not abort the remaining checks - you want
               the full picture of what is wrong, not just the first thing. */
            SET @ruleError = ERROR_MESSAGE();

            INSERT INTO meta.DataQualityResult
                (LoadId, RuleId, PickupYear, PickupMonth, FailedCount, Passed, Severity, Message)
            VALUES
                (@LoadId, @ruleId, @PickupYear, @PickupMonth, -1, 0, @severity,
                 LEFT(CONCAT('Rule execution error: ', @ruleError), 2000));

            IF @severity = 'Blocking'
            BEGIN
                SET @blockingFailures = @blockingFailures + 1;

                /* Carry the first error text into the summary, not just the
                   word "error".

                   Broken rules nearly always break for the same reason at the
                   same time - one missing grant, one renamed column - so the
                   first message is almost always the whole story, and repeating
                   it nine times would only crowd out the rule names.

                   This is the message ADF surfaces and the one that lands in
                   meta.LoadAudit, so whatever is omitted here is what somebody
                   has to go digging for. The first time this fired it read
                   "NoNullTripKey (error)", which cost an afternoon to trace
                   back to a permission denial the database had already written
                   into meta.DataQualityResult.Message. */
                IF @firstError IS NULL SET @firstError = @ruleError;

                SET @failureSummary = CONCAT(@failureSummary, @ruleName, ' (error); ');
            END
        END CATCH

        FETCH NEXT FROM rule_cursor INTO @ruleId, @ruleName, @severity, @ruleSql, @threshold;
    END

    CLOSE rule_cursor;
    DEALLOCATE rule_cursor;

    IF @blockingFailures > 0
    BEGIN
        /* Trimmed hard: this has to fit beside the rule names in a 2000-char
           audit Message, and the point is to identify the fault, not to
           reproduce the full text - which is in meta.DataQualityResult intact. */
        DECLARE @errorNote NVARCHAR(600) =
            CASE WHEN @firstError IS NULL THEN N''
                 ELSE CONCAT(N'First error: ', LEFT(@firstError, 400), N' ')
            END;

        UPDATE meta.LoadAudit
        SET Message = LEFT(CONCAT('Data quality failures: ', @failureSummary, @errorNote), 2000)
        WHERE LoadId = @LoadId;

        /* @failureSummary and @errorNote go in as ARGUMENTS, never as part of
           the format string: a rule name or an error message containing a '%'
           would otherwise be read as a format specifier. */
        RAISERROR(
            '%d blocking data quality rule(s) failed for partition %d-%d: %s%sQuery meta.DataQualityResult WHERE LoadId = %I64d for detail.',
            16, 1, @blockingFailures, @PickupYear, @PickupMonth, @failureSummary, @errorNote, @LoadId);
        RETURN;
    END

    PRINT CONCAT('All data quality rules passed for partition ', @PickupYear, '-', @PickupMonth, '.');
END
GO
