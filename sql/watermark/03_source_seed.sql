/* =====================================================================
   03_source_seed.sql
   Simulated source system (schema src). Synthetic data only.
     src.Submissions  -> small, has ModifiedDate     -> Stage 2 (ForEach1)
     src.Bids         -> 200k rows, has ModifiedDate -> Stage 3 (ForEach1_copy2)
     src.Markets      -> no watermark column         -> Stage 4 (Run Loop Static Load)
     src.StatusCodes  -> no watermark column         -> Stage 4
   ===================================================================== */
IF SCHEMA_ID('src') IS NULL EXEC('CREATE SCHEMA src');
GO

DROP TABLE IF EXISTS src.Submissions, src.Bids, src.Markets, src.StatusCodes, src.Outages;
GO

CREATE TABLE src.Markets (
    MarketCode  VARCHAR(10)  PRIMARY KEY,
    MarketName  VARCHAR(100) NOT NULL
);
INSERT INTO src.Markets VALUES
 ('CAISO','California ISO'), ('MISO','Midcontinent ISO'), ('PJM','PJM Interconnection'),
 ('SPP','Southwest Power Pool'), ('ERCOT','Electric Reliability Council of Texas'),
 ('NYISO','New York ISO'), ('ISONE','ISO New England');

CREATE TABLE src.StatusCodes (
    StatusCode  INT PRIMARY KEY,
    Description VARCHAR(100) NOT NULL
);
INSERT INTO src.StatusCodes VALUES
 (10,'FTP complete'), (20,'Validation passed'), (30,'Data copy'), (40,'Archive'),
 (50,'Process pending'), (60,'Data load'), (70,'Unzip'), (80,'Rejected'), (90,'Superseded');

CREATE TABLE src.Submissions (
    SubmissionId  INT IDENTITY(1,1) PRIMARY KEY,
    MarketCode    VARCHAR(10)  NOT NULL,
    FileName      VARCHAR(200) NOT NULL,
    StatusCode    INT          NOT NULL,
    ModifiedDate  DATETIME2(3) NOT NULL
);
;WITH n AS (SELECT TOP (500) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
            FROM sys.all_objects a CROSS JOIN sys.all_objects b)
INSERT INTO src.Submissions (MarketCode, FileName, StatusCode, ModifiedDate)
SELECT CHOOSE(1 + i % 7, 'CAISO','MISO','PJM','SPP','ERCOT','NYISO','ISONE'),
       CONCAT('submission_', i, '.zip'),
       CHOOSE(1 + i % 9, 10,20,30,40,50,60,70,80,90),
       DATEADD(MINUTE, -i * 7, SYSUTCDATETIME())
FROM n;

CREATE TABLE src.Bids (
    BidId         BIGINT IDENTITY(1,1) PRIMARY KEY,
    MarketCode    VARCHAR(10)   NOT NULL,
    IntervalStart DATETIME2(0)  NOT NULL,
    Mw            DECIMAL(10,2) NOT NULL,
    Price         DECIMAL(10,2) NOT NULL,
    ModifiedDate  DATETIME2(3)  NOT NULL
);
;WITH n AS (SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
            FROM sys.all_objects a CROSS JOIN sys.all_objects b CROSS JOIN sys.all_objects c)
INSERT INTO src.Bids (MarketCode, IntervalStart, Mw, Price, ModifiedDate)
SELECT CHOOSE(1 + i % 7, 'CAISO','MISO','PJM','SPP','ERCOT','NYISO','ISONE'),
       DATEADD(MINUTE, -(i % 50000) * 5, CAST(SYSUTCDATETIME() AS DATETIME2(0))),
       CAST(i % 500 AS DECIMAL(10,2)) + 0.25,
       CAST(i % 120 AS DECIMAL(10,2)) + 0.99,
       DATEADD(SECOND, -i * 3, SYSUTCDATETIME())
FROM n;
GO

-- Statistics so sys.partitions row counts are accurate for the IsLarge decision.
UPDATE STATISTICS src.Bids;
GO
