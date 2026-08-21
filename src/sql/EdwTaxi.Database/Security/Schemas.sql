/* =============================================================================
   Schemas
   =============================================================================

   Five namespaces, each with one job. The discipline matters more than the
   names: when every object's schema tells you what it is for, permissions and
   code review both get easier.

     stg   Staging. Volatile. Truncated at the start of every load. Heaps, no
           indexes, no constraints - it exists to receive a bulk insert as fast
           as possible and nothing else. NEVER read by a report.

     dim   Dimensions. Slowly-changing reference data. Small, wide, heavily
           joined. Rowstore with clustered PKs.

     fact  Facts. Large, narrow, append-mostly. Clustered columnstore.

     etl   The load procedures. Separated from the data so that
           `GRANT EXECUTE ON SCHEMA::etl` is a meaningful, auditable grant.

     meta  Operational metadata: load audit, data quality rules and results.
           This is the schema you query during an incident.

   All five in one file. DacFx does not care, and five two-line files is worse
   than one twelve-line file.
   ============================================================================= */

CREATE SCHEMA [stg] AUTHORIZATION [dbo];
GO

CREATE SCHEMA [dim] AUTHORIZATION [dbo];
GO

CREATE SCHEMA [fact] AUTHORIZATION [dbo];
GO

CREATE SCHEMA [etl] AUTHORIZATION [dbo];
GO

CREATE SCHEMA [meta] AUTHORIZATION [dbo];
GO

CREATE SCHEMA [rpt] AUTHORIZATION [dbo];
GO
