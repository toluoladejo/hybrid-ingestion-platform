-- Let identities other than Synapse Administrators read dbo.orders (week 5, Lab 5).
-- Each reader needs a database user, db_datareader, and REFERENCES on the credential.
-- Replace the names below: the CI app's display name and a Power BI user.
USE ingest;
GO
CREATE USER [gh-<owner>-hybrid-ingestion-platform] FROM EXTERNAL PROVIDER;
CREATE USER [analyst@contoso.com] FROM EXTERNAL PROVIDER;

ALTER ROLE db_datareader ADD MEMBER [gh-<owner>-hybrid-ingestion-platform];
ALTER ROLE db_datareader ADD MEMBER [analyst@contoso.com];

GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::WorkspaceIdentity TO [gh-<owner>-hybrid-ingestion-platform];
GRANT REFERENCES ON DATABASE SCOPED CREDENTIAL::WorkspaceIdentity TO [analyst@contoso.com];
GO
