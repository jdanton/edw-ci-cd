/* =============================================================================
   dim.TaxiZone
   =============================================================================

   The 265 TLC taxi zones. Loaded from the lake rather than seeded inline: the
   TLC republishes the zone lookup occasionally, so it belongs in the pipeline
   like any other source. Scripts/PostDeploy/020_ReferenceDimensions.sql
   creates only the Unknown member; the real rows arrive via the lake.

   Both PickupZoneKey and DropoffZoneKey on the fact table point here - a
   role-playing dimension. Two foreign keys to one table, disambiguated in
   reporting views (rpt.vw_YellowTaxiTripDaily) rather than by physically
   duplicating the dimension.
   ============================================================================= */

CREATE TABLE [dim].[TaxiZone]
(
    [TaxiZoneKey]  SMALLINT     NOT NULL,
    [TaxiZoneId]   SMALLINT     NULL,        -- TLC LocationID, 1-265
    [Borough]      VARCHAR(50)  NOT NULL,
    [ZoneName]     VARCHAR(100) NOT NULL,
    [ServiceZone]  VARCHAR(50)  NULL,        -- Yellow Zone / Boro Zone / EWR / Airports

    [IsAirport]    AS (CASE WHEN [ServiceZone] = 'Airports' OR [ZoneName] LIKE '%Airport%'
                            THEN CONVERT(BIT, 1) ELSE CONVERT(BIT, 0) END) PERSISTED,

    [IsUnknown]    BIT          NOT NULL
        CONSTRAINT [DF_dim_TaxiZone_IsUnknown] DEFAULT (0),

    [LoadedAtUtc]  DATETIME2(3) NOT NULL
        CONSTRAINT [DF_dim_TaxiZone_LoadedAtUtc] DEFAULT (SYSUTCDATETIME()),

    CONSTRAINT [PK_dim_TaxiZone] PRIMARY KEY CLUSTERED ([TaxiZoneKey] ASC),
    CONSTRAINT [UQ_dim_TaxiZone_TaxiZoneId] UNIQUE NONCLUSTERED ([TaxiZoneId] ASC)
);
GO

CREATE NONCLUSTERED INDEX [IX_dim_TaxiZone_Borough]
    ON [dim].[TaxiZone] ([Borough] ASC)
    INCLUDE ([ZoneName], [IsAirport]);
GO
