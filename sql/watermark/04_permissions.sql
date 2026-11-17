/* =====================================================================
   04_permissions.sql
   Grants the Synapse workspace managed identity access to the DB.
   Run as the Entra ID admin of the Azure SQL server.
   __SYNAPSE_WORKSPACE__ = the workspace name (its managed identity has the same name).
   ===================================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '__SYNAPSE_WORKSPACE__')
    CREATE USER [__SYNAPSE_WORKSPACE__] FROM EXTERNAL PROVIDER;
GO
ALTER ROLE db_datareader ADD MEMBER [__SYNAPSE_WORKSPACE__];
ALTER ROLE db_datawriter ADD MEMBER [__SYNAPSE_WORKSPACE__];
GRANT EXECUTE ON SCHEMA::etl TO [__SYNAPSE_WORKSPACE__];
GRANT ALTER ON etl.NewTablesStaging TO [__SYNAPSE_WORKSPACE__];   -- needed for TRUNCATE (pre-copy script)
GRANT VIEW DEFINITION ON SCHEMA::src TO [__SYNAPSE_WORKSPACE__];   -- INFORMATION_SCHEMA / sys.partitions visibility
GRANT VIEW DATABASE STATE TO [__SYNAPSE_WORKSPACE__];
GO
