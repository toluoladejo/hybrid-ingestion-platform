/* =====================================================================
   01_control_schema.sql
   Control (watermark) schema used by the replica pipeline.
   Run against the Azure SQL DB referenced by ls_sql_rto.
   ===================================================================== */
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');
GO

-- One row per source table. Populated automatically by Stage 1
-- (Copy New Tables Metadata -> Insert New Tables).
IF OBJECT_ID('etl.WatermarkControl') IS NULL
CREATE TABLE etl.WatermarkControl (
    ControlId        INT IDENTITY(1,1) PRIMARY KEY,
    SchemaName       SYSNAME       NOT NULL,
    TableName        SYSNAME       NOT NULL,
    WatermarkColumn  SYSNAME       NULL,                         -- NULL => static/full load
    WatermarkValue   VARCHAR(50)   NOT NULL DEFAULT '1900-01-01 00:00:00.000',
    LoadType         VARCHAR(20)   NOT NULL DEFAULT 'Incremental', -- Incremental | Static
    IsLarge          BIT           NOT NULL DEFAULT 0,             -- 1 => Stage 3 (ForEach1_copy2)
    IsActive         BIT           NOT NULL DEFAULT 1,
    LastLoadDate     DATETIME2     NULL,
    LastRowCount     BIGINT        NULL,
    CreatedAt        DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_WatermarkControl UNIQUE (SchemaName, TableName)
);
GO

-- Stage 1 sink: truncated and reloaded on every run.
IF OBJECT_ID('etl.NewTablesStaging') IS NULL
CREATE TABLE etl.NewTablesStaging (
    SchemaName       SYSNAME   NOT NULL,
    TableName        SYSNAME   NOT NULL,
    WatermarkColumn  SYSNAME   NULL,
    ApproxRowCount   BIGINT    NULL
);
GO

-- One row per table load (incremental, large or static), keyed by parent run.
-- Read by Notebook1 and by 'Lookup Row Counts'.
IF OBJECT_ID('etl.LoadAudit') IS NULL
CREATE TABLE etl.LoadAudit (
    AuditId          BIGINT IDENTITY(1,1) PRIMARY KEY,
    ParentRunId      VARCHAR(100)  NOT NULL,
    ChildRunId       VARCHAR(100)  NULL,
    ControlId        INT           NOT NULL,
    SchemaName       SYSNAME       NOT NULL,
    TableName        SYSNAME       NOT NULL,
    LoadKind         VARCHAR(20)   NOT NULL,   -- Incremental | Large | Static
    OldWatermark     VARCHAR(50)   NULL,
    NewWatermark     VARCHAR(50)   NULL,
    RowsCopied       BIGINT        NULL,
    LakeRowCount     BIGINT        NULL,       -- filled by Notebook1
    Validated        BIT           NULL,       -- filled by Notebook1
    LoadedAt         DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

IF OBJECT_ID('etl.ArchiveLog') IS NULL
CREATE TABLE etl.ArchiveLog (
    ArchiveId        INT IDENTITY(1,1) PRIMARY KEY,
    ParentRunId      VARCHAR(100)  NOT NULL,
    FilesCopied      BIGINT        NULL,
    ArchivedAt       DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

/* Catalogue of source tables (everything in schema src).
   Watermark column = first datetime/datetime2 column named ModifiedDate / LastModified / UpdatedAt. */
CREATE OR ALTER VIEW etl.vw_SourceTableCatalog AS
SELECT  t.TABLE_SCHEMA AS SchemaName,
        t.TABLE_NAME   AS TableName,
        (SELECT TOP 1 c.COLUMN_NAME
           FROM INFORMATION_SCHEMA.COLUMNS c
          WHERE c.TABLE_SCHEMA = t.TABLE_SCHEMA AND c.TABLE_NAME = t.TABLE_NAME
            AND c.COLUMN_NAME IN ('ModifiedDate', 'LastModified', 'UpdatedAt')
            AND c.DATA_TYPE IN ('datetime', 'datetime2')
          ORDER BY c.ORDINAL_POSITION)                           AS WatermarkColumn,
        (SELECT SUM(p.rows) FROM sys.partitions p
          WHERE p.object_id = OBJECT_ID(QUOTENAME(t.TABLE_SCHEMA) + '.' + QUOTENAME(t.TABLE_NAME))
            AND p.index_id IN (0, 1))                             AS ApproxRowCount
FROM INFORMATION_SCHEMA.TABLES t
WHERE t.TABLE_TYPE = 'BASE TABLE' AND t.TABLE_SCHEMA = 'src';
GO
