/* =============================================================================
   etl.usp_Complete_Load
   =============================================================================

   Closes a load audit row. Called twice from PL_Load_Sql_YellowTrip - once on
   the success path with Status 'Succeeded', and once from the 'Fail Load'
   activity with Status 'Failed'.

   Row counts are read from the fact table rather than passed in, so they are
   the truth rather than what the pipeline believed.
   ============================================================================= */

CREATE PROCEDURE [etl].[usp_Complete_Load]
    @LoadId  BIGINT,
    @Status  VARCHAR(20),
    @Message NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Status NOT IN ('Succeeded', 'Failed', 'Cancelled')
    BEGIN
        RAISERROR('@Status must be Succeeded, Failed or Cancelled. Got ''%s''.', 16, 1, @Status);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM meta.LoadAudit WHERE LoadId = @LoadId)
    BEGIN
        /* Do not fail here. This procedure runs on the pipeline's failure path,
           and an error inside the error handler produces a run whose actual
           cause is buried under a second, unrelated exception. */
        PRINT CONCAT('etl.usp_Complete_Load: LoadId ', @LoadId, ' not found. Nothing to close.');
        RETURN;
    END

    DECLARE @rowsInserted BIGINT =
        (SELECT COUNT_BIG(*) FROM fact.YellowTaxiTrip WHERE LoadId = @LoadId);

    UPDATE meta.LoadAudit
    SET Status         = @Status,
        CompletedAtUtc = SYSUTCDATETIME(),
        RowsInserted   = @rowsInserted,
        Message        = LEFT(ISNULL(@Message, Message), 2000)
    WHERE LoadId = @LoadId;
END
GO
