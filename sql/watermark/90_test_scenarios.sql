/* =====================================================================
   90_test_scenarios.sql
   Run ONE scenario block at a time, then trigger a Debug run of
   pl_watermark_incremental_parent and record what happened.
   The "check" queries at the bottom show the results.
   ===================================================================== */

/* ---------------------------------------------------------------------
   S1  First run (baseline)
   Nothing to do: run the pipeline on fresh seed data.
   Expect: Stage 1 registers 4 tables (Submissions, Bids = Incremental; Markets,
   StatusCodes = Static). Bids gets IsLarge = 1. All rows are copied.
   TotalRows > 0, so If Condition1 = True and Execute Archiving runs.
   --------------------------------------------------------------------- */

/* ---------------------------------------------------------------------
   S2  Re-run with no source changes
   Expect: 0 rows copied for the incremental tables; static tables reload.
   TotalRows = 0, so If Condition1 = False and no archiving.
   --------------------------------------------------------------------- */

/* ---------------------------------------------------------------------
   S3  New + changed rows
   Expect: only these rows are copied (3 new + 5 updated Submissions, 1,000 new Bids).
   --------------------------------------------------------------------- */
INSERT INTO src.Submissions (MarketCode, FileName, StatusCode, ModifiedDate)
VALUES ('PJM', 'submission_new_1.zip', 10, SYSUTCDATETIME()),
       ('MISO', 'submission_new_2.zip', 10, SYSUTCDATETIME()),
       ('SPP', 'submission_new_3.zip', 10, SYSUTCDATETIME());
UPDATE TOP (5) src.Submissions SET StatusCode = 60, ModifiedDate = SYSUTCDATETIME() WHERE StatusCode = 50;
;WITH n AS (SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i FROM sys.all_objects)
INSERT INTO src.Bids (MarketCode, IntervalStart, Mw, Price, ModifiedDate)
SELECT 'CAISO', CAST(SYSUTCDATETIME() AS DATETIME2(0)), i, 42.00, SYSUTCDATETIME() FROM n;
GO

/* ---------------------------------------------------------------------
   S4  New source table appears (tests Stage 1 discovery)
   Expect: src.Outages is inserted into etl.WatermarkControl and loaded in the same run.
   --------------------------------------------------------------------- */
CREATE TABLE src.Outages (
    OutageId     INT IDENTITY(1,1) PRIMARY KEY,
    MarketCode   VARCHAR(10) NOT NULL,
    Description  VARCHAR(200) NOT NULL,
    ModifiedDate DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
INSERT INTO src.Outages (MarketCode, Description) VALUES ('ERCOT', 'Planned maintenance'), ('PJM', 'Forced outage');
GO

/* ---------------------------------------------------------------------
   S5  A STANDARD table fails inside ForEach1
   Expect: 'Error Report Email' fires for Submissions. Other iterations continue.
   QUESTION TO ANSWER: what status does ForEach1 report? Stage 3 should still
   run because the link is 'Completed'.
   --------------------------------------------------------------------- */
UPDATE etl.WatermarkControl SET WatermarkColumn = 'DoesNotExist' WHERE TableName = 'Submissions';
GO

/* ---------------------------------------------------------------------
   S6  A LARGE table fails inside ForEach1_copy2   (the key risk in the breakdown)
   Expect: 'Error Report Email copy2' fires.
   QUESTION TO ANSWER: if ForEach1_copy2 reports Failed, are Run Loop Static Load,
   Notebook1, Lookup Row Counts and archiving all SKIPPED?
   --------------------------------------------------------------------- */
UPDATE etl.WatermarkControl SET WatermarkColumn = 'DoesNotExist' WHERE TableName = 'Bids';
GO

/* ---------------------------------------------------------------------
   S7  The static-load notebook fails
   Expect: 'Error Report Email copy1' fires, Notebook1 and archiving are skipped.
   --------------------------------------------------------------------- */
UPDATE etl.WatermarkControl SET TableName = 'Markets_Missing' WHERE TableName = 'Markets';
GO

/* ---------------------------------------------------------------------
   RESET after S5 / S6 / S7
   --------------------------------------------------------------------- */
UPDATE etl.WatermarkControl SET WatermarkColumn = 'ModifiedDate' WHERE TableName IN ('Submissions', 'Bids');
UPDATE etl.WatermarkControl SET TableName = 'Markets' WHERE TableName = 'Markets_Missing';
GO

/* ---------------------------------------------------------------------
   FULL RESET (start over from S1): re-run 03_source_seed.sql afterwards
   --------------------------------------------------------------------- */
-- TRUNCATE TABLE etl.LoadAudit; TRUNCATE TABLE etl.ArchiveLog; TRUNCATE TABLE etl.NewTablesStaging;
-- DELETE FROM etl.WatermarkControl; DBCC CHECKIDENT ('etl.WatermarkControl', RESEED, 0);

/* ---------------------------------------------------------------------
   CHECKS
   --------------------------------------------------------------------- */
SELECT * FROM etl.WatermarkControl ORDER BY ControlId;
SELECT TOP (50) * FROM etl.LoadAudit ORDER BY AuditId DESC;
SELECT TOP (10) * FROM etl.ArchiveLog ORDER BY ArchiveId DESC;
SELECT ParentRunId, LoadKind, COUNT(*) AS Tables, SUM(RowsCopied) AS RowsCopied,
       SUM(CASE WHEN Validated = 0 THEN 1 ELSE 0 END) AS Mismatches
FROM etl.LoadAudit GROUP BY ParentRunId, LoadKind ORDER BY MAX(AuditId) DESC;
