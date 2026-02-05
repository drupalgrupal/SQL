/********************************************************************************************
    Script: Get Fully Qualified SQL Connection String for Always On Databases
    Author: [Your Name or Handle]
    Reference: https://sqlpal.blogspot.com/2023/07/query-fully-qualified-connection-string.html
    Purpose:
        Returns a list of SQL Server connection strings for databases 
        participating in an Always On Availability Group (AG).

    Parameters:
        @dbname NVARCHAR(500)
            - If NULL or empty string, returns connection strings for *all* AG databases.
            - If a specific database name is provided, validates that it exists 
              and belongs to an AG.

    Output Columns:
        ConnString   : Fully qualified DNS\Instance connection string.
        AGName       : Availability Group name.
        DNSName      : Listener DNS name.
        SQLInstance  : Current SQL instance name.
        ClusterNodes : List of participating cluster node names.
        TCPPort      : Listener port number.

    Notes:
        - Requires VIEW SERVER STATE permission (to access DMVs).
        - xp_regread requires sysadmin privileges (reads registry).
********************************************************************************************/

DECLARE @dbname NVARCHAR(500)
SET @dbname = N''   -- Set to a specific database name if desired.

-- STEP 1: Retrieve current server's domain name suffix from registry.
-- This is used to append FQDN to the listener name.
DECLARE @DomainName NVARCHAR(100)
EXEC master.dbo.xp_regread 
     'HKEY_LOCAL_MACHINE',
     'SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters',
     N'Domain',
     @DomainName OUTPUT

-- STEP 2: Input validation.
-- Ensure that the provided database exists locally.
IF DB_ID(@dbname) IS NULL AND @dbname <> ''
    RAISERROR('No database found with name %s.', 16, 1, @dbname)

-- If the database exists but is not part of any Availability Group, raise an error.
ELSE IF DB_ID(@dbname) IS NOT NULL AND @dbname <> '' 
     AND NOT EXISTS (SELECT * FROM sys.availability_databases_cluster WHERE database_name = @dbname)
    RAISERROR('Database is not part of an Availability Group: %s.', 16, 1, @dbname)

-- STEP 3: Check if Always On is enabled before proceeding.
ELSE IF SERVERPROPERTY('IsHadrEnabled') = 1
BEGIN
    -- Build a comma-separated list of all cluster node names for reference.
    DECLARE @ClusterNodes VARCHAR(8000)
    SELECT @ClusterNodes = COALESCE(@ClusterNodes + ', ', '') + node_name
    FROM (SELECT DISTINCT node_name 
          FROM sys.dm_hadr_availability_replica_cluster_nodes) AS a

    -- STEP 4: Generate and return connection info for each AG listener.
    SELECT 
        -- Construct the FQDN + Instance connection string.
        UPPER(
            CASE 
                WHEN SERVERPROPERTY('InstanceName') IS NULL 
                    THEN DNS_NAME 
                ELSE CONCAT(
                        DNS_NAME, 
                        ISNULL(CONCAT('.', @DomainName), ''), 
                        '\', 
                        CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(100))
                     )
            END
        ) AS ConnString,
        UPPER(ag.name) AS AGName,
        UPPER(dns_name) AS DNSName,
        UPPER(CAST(SERVERPROPERTY('InstanceName') AS NVARCHAR(100))) AS SQLInstance,
        UPPER(@ClusterNodes) AS ClusterNodes,
        port AS TCPPort
    FROM sys.availability_groups AS ag
    INNER JOIN sys.availability_group_listeners AS agl 
        ON ag.group_id = agl.group_id
    WHERE CAST(agl.group_id AS VARCHAR(100)) LIKE 
          CASE 
              WHEN @dbname IS NULL OR @dbname = '' THEN '%'
              ELSE (
                    SELECT CAST(group_id AS VARCHAR(100)) 
                    FROM sys.availability_databases_cluster 
                    WHERE database_name = @dbname
                   )
          END
END

-- STEP 5: Handle case when Always On is not enabled.
ELSE IF SERVERPROPERTY('IsHadrEnabled') = 0
    RAISERROR('SQL Server is not an AlwaysOn Cluster.', 16, 1)
ELSE
    RAISERROR('Unknown error occurred.', 16, 1)
