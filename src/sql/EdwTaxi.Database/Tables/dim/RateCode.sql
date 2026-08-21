/* =============================================================================
   dim.RateCode
   =============================================================================
   TLC rate codes: standard, JFK flat fare, Newark, and so on. Seeded by
   Scripts/PostDeploy/020_ReferenceDimensions.sql.

   Note RateCodeId 99 ("Unknown", the TLC's own catch-all) is distinct from
   RateCodeKey -1 ("Unknown", ours, for values not in the code list at all).
   Conflating them would hide the difference between "the meter reported it as
   unclassified" and "we could not interpret what the meter reported".
   ============================================================================= */

CREATE TABLE [dim].[RateCode]
(
    [RateCodeKey]   SMALLINT     NOT NULL,
    [RateCodeId]    SMALLINT     NULL,
    [RateCodeName]  VARCHAR(100) NOT NULL,
    [IsFlatFare]    BIT          NOT NULL
        CONSTRAINT [DF_dim_RateCode_IsFlatFare] DEFAULT (0),
    [IsUnknown]     BIT          NOT NULL
        CONSTRAINT [DF_dim_RateCode_IsUnknown] DEFAULT (0),

    CONSTRAINT [PK_dim_RateCode] PRIMARY KEY CLUSTERED ([RateCodeKey] ASC),
    CONSTRAINT [UQ_dim_RateCode_RateCodeId] UNIQUE NONCLUSTERED ([RateCodeId] ASC)
);
GO
