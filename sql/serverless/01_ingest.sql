-- Serverless SQL database and the dbo.orders view over curated Parquet (week 5, Lab 5).
-- Run against the Built-in pool: the first batch in master, the rest in ingest.
-- The database is not a Synapse artifact: Publish does not create it. Re-run this after
-- every fresh deploy (by hand, or with sqlcmd in the workflow in week 7).

-- Views live in a user database, not master. UTF-8 BIN2 collation avoids
-- conversion warnings and slow string filters over Parquet.
IF DB_ID('ingest') IS NULL
    CREATE DATABASE ingest COLLATE Latin1_General_100_BIN2_UTF8;
GO
USE ingest;
GO
-- The credential that lets the view read the lake as the workspace managed identity,
-- so readers need SQL rights but no storage role.
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$(MasterKeyPassword)';   -- sqlcmd -v MasterKeyPassword=...
IF NOT EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = 'WorkspaceIdentity')
    CREATE DATABASE SCOPED CREDENTIAL WorkspaceIdentity WITH IDENTITY = 'Managed Identity';
IF NOT EXISTS (SELECT 1 FROM sys.external_data_sources WHERE name = 'lake')
    CREATE EXTERNAL DATA SOURCE lake WITH (
        LOCATION   = 'https://$(StorageAccount).dfs.core.windows.net',  -- sqlcmd -v StorageAccount=...
        CREDENTIAL = WorkspaceIdentity);
GO
-- The view owns the column types: Parquet holds every column as a string.
CREATE OR ALTER VIEW dbo.orders AS
SELECT
    CAST(r.order_id AS varchar(20))          AS order_id,
    TRY_CAST(r.order_date AS date)           AS order_date,
    CAST(r.customer_id AS varchar(20))       AS customer_id,
    TRY_CAST(r.amount AS decimal(18,2))      AS amount,
    CAST(r.filepath(1) AS date)              AS ingest_date,   -- value of the first *
    r.filename()                             AS source_file
FROM OPENROWSET(
    BULK 'curated/orders/ingest_date=*/*.parquet',
    DATA_SOURCE = 'lake',
    FORMAT = 'PARQUET') AS r;
GO
