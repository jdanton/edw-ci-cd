/* =============================================================================
   dim.Vendor
   =============================================================================

   TLC technology providers. Two real values, plus the -1 Unknown member.

   THE UNKNOWN MEMBER (-1) IS NOT OPTIONAL. Roughly 0.1% of TLC rows carry a
   vendor code that is null or not in the published code list. There are three
   ways to handle that:

     1. Drop the fact rows          -> silently loses revenue. Unacceptable.
     2. Leave the FK NULL           -> every report must remember to use a LEFT
                                       JOIN, and one day someone will not, and
                                       the number will quietly shrink.
     3. Point at an Unknown member  -> INNER JOINs stay correct, the rows stay
                                       counted, and 'Unknown' appears in the
                                       report where a human will notice it.

   Option 3, here and in every other dimension in this schema. Seeded by
   Scripts/PostDeploy/020_ReferenceDimensions.sql.
   ============================================================================= */

CREATE TABLE [dim].[Vendor]
(
    [VendorKey]   SMALLINT     NOT NULL,
    [VendorId]    SMALLINT     NULL,        -- source code; NULL for the Unknown member
    [VendorName]  VARCHAR(100) NOT NULL,
    [IsUnknown]   BIT          NOT NULL
        CONSTRAINT [DF_dim_Vendor_IsUnknown] DEFAULT (0),

    [ValidFromUtc] DATETIME2(3) NOT NULL
        CONSTRAINT [DF_dim_Vendor_ValidFromUtc] DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT [PK_dim_Vendor] PRIMARY KEY CLUSTERED ([VendorKey] ASC),
    CONSTRAINT [UQ_dim_Vendor_VendorId] UNIQUE NONCLUSTERED ([VendorId] ASC)
);
GO
