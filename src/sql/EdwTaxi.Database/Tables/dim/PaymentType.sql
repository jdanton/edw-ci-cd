/* =============================================================================
   dim.PaymentType
   =============================================================================
   How the passenger paid. Matters more than it looks: tip amount is only
   recorded for card payments, so any tip analysis that does not filter on
   IsTipRecorded understates tipping by roughly the cash share of trips.

   That is why IsTipRecorded exists as a column rather than living in a comment
   somewhere - it makes the caveat joinable.
   ============================================================================= */

CREATE TABLE [dim].[PaymentType]
(
    [PaymentTypeKey]  SMALLINT     NOT NULL,
    [PaymentTypeId]   SMALLINT     NULL,
    [PaymentTypeName] VARCHAR(50)  NOT NULL,

    /* The meter only captures tips paid by card. Cash tips are invisible. */
    [IsTipRecorded]   BIT          NOT NULL
        CONSTRAINT [DF_dim_PaymentType_IsTipRecorded] DEFAULT (0),

    [IsUnknown]       BIT          NOT NULL
        CONSTRAINT [DF_dim_PaymentType_IsUnknown] DEFAULT (0),

    CONSTRAINT [PK_dim_PaymentType] PRIMARY KEY CLUSTERED ([PaymentTypeKey] ASC),
    CONSTRAINT [UQ_dim_PaymentType_PaymentTypeId] UNIQUE NONCLUSTERED ([PaymentTypeId] ASC)
);
GO
