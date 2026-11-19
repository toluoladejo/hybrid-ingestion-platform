/* =====================================================================
   04_permissions.sql
   Grants the Synapse workspace managed identity access to the DB.
   Run as the Entra ID admin of the Azure SQL server.
   syn-ingest-dev-b39ab696297dc = the workspace name (its managed identity has the same name).
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'syn-ingest-dev-b39ab696297dc')
    CREATE USER [syn-ingest-dev-b39ab696297dc] FROM EXTERNAL PROVIDER;
GO
ALTER ROLE db_datareader ADD MEMBER [syn-ingest-dev-b39ab696297dc];
ALTER ROLE db_datawriter ADD MEMBER [syn-ingest-dev-b39ab696297dc];
GRANT EXECUTE ON SCHEMA::etl TO [syn-ingest-dev-b39ab696297dc];
GRANT ALTER ON etl.NewTablesStaging TO [syn-ingest-dev-b39ab696297dc];   -- needed for TRUNCATE (pre-copy script)
GRANT VIEW DEFINITION ON SCHEMA::src TO [syn-ingest-dev-b39ab696297dc];   -- INFORMATION_SCHEMA / sys.partitions visibility
GRANT VIEW DATABASE STATE TO [syn-ingest-dev-b39ab696297dc];
GO
