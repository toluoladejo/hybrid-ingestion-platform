/* =====================================================================
   02_procedures.sql
   Stored procedures called by the pipelines and notebooks.
   ===================================================================== */

-- Called by Lookup 'Insert New Tables'. Must return a result set (Lookup requirement).
CREATE OR ALTER PROCEDURE etl.usp_InsertNewTables
    @LargeRowThreshold BIGINT = 100000
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @inserted INT;

    INSERT INTO etl.WatermarkControl (SchemaName, TableName, WatermarkColumn, LoadType, IsLarge)
    SELECT s.SchemaName,
           s.TableName,
           s.WatermarkColumn,
           CASE WHEN s.WatermarkColumn IS NULL THEN 'Static' ELSE 'Incremental' END,
           CASE WHEN s.WatermarkColumn IS NOT NULL AND ISNULL(s.ApproxRowCount, 0) >= @LargeRowThreshold
                THEN 1 ELSE 0 END
    FROM etl.NewTablesStaging s
    WHERE NOT EXISTS (SELECT 1 FROM etl.WatermarkControl c
                      WHERE c.SchemaName = s.SchemaName AND c.TableName = s.TableName);

    SET @inserted = @@ROWCOUNT;
    SELECT @inserted AS NewTablesInserted,
           (SELECT COUNT(*) FROM etl.WatermarkControl) AS TotalTables;
END;
GO

-- Called by 'Update watermark' in both watermark child pipelines.
CREATE OR ALTER PROCEDURE etl.usp_UpdateWatermark
    @ControlId    INT,
    @NewWatermark VARCHAR(50),
    @RowsCopied   BIGINT,
    @ParentRunId  VARCHAR(100),
    @ChildRunId   VARCHAR(100),
    @LoadKind     VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRAN;
        INSERT INTO etl.LoadAudit (ParentRunId, ChildRunId, ControlId, SchemaName, TableName, LoadKind,
                                   OldWatermark, NewWatermark, RowsCopied)
        SELECT @ParentRunId, @ChildRunId, ControlId, SchemaName, TableName, @LoadKind,
               WatermarkValue, @NewWatermark, @RowsCopied
        FROM etl.WatermarkControl WHERE ControlId = @ControlId;

        UPDATE etl.WatermarkControl
           SET WatermarkValue = @NewWatermark,
               LastLoadDate   = SYSUTCDATETIME(),
               LastRowCount   = @RowsCopied
         WHERE ControlId = @ControlId;
    COMMIT;
END;
GO

-- Called by the 'Run Loop Static Load' notebook and by pl_static_load_child.
CREATE OR ALTER PROCEDURE etl.usp_RecordStaticLoad
    @ControlId   INT,
    @RowsCopied  BIGINT,
    @ParentRunId VARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.LoadAudit (ParentRunId, ControlId, SchemaName, TableName, LoadKind, RowsCopied)
    SELECT @ParentRunId, ControlId, SchemaName, TableName, 'Static', @RowsCopied
    FROM etl.WatermarkControl WHERE ControlId = @ControlId;

    UPDATE etl.WatermarkControl
       SET LastLoadDate = SYSUTCDATETIME(), LastRowCount = @RowsCopied
     WHERE ControlId = @ControlId;
END;
GO

-- Called by pl_archiving.
CREATE OR ALTER PROCEDURE etl.usp_LogArchive
    @ParentRunId VARCHAR(100),
    @FilesCopied BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO etl.ArchiveLog (ParentRunId, FilesCopied) VALUES (@ParentRunId, @FilesCopied);
END;
GO
