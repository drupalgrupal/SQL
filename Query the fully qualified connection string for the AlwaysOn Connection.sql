-- See blog post: https://sqlpal.blogspot.com/2023/07/query-fully-qualified-connection-string.html

/* GET FULLY QUALIFIED SQL CONNECTION STRING FOR ALWAYSON DATABASE

There is only one parameter, @dbname, if you are looking to get connection string 
for a single database

So, if the value for @dbname is null or an empty string, this script  will return 
connection strings for all AGs defined in the current sql session

*/

declare @dbname nvarchar(500)
set @dbname = ''

-- Read the domain name suffix for the current server that we will
-- append to the listener's DNS Name.
DECLARE @DomainName NVARCHAR(100)
EXEC master.dbo.xp_regread 'HKEY_LOCAL_MACHINE', 'SYSTEM\CurrentControlSet\services\Tcpip\Parameters', N'Domain',@DomainName OUTPUT

-- throw an error if @dbname provided does not exist on the current sql server
IF db_id(@dbname) is null and @dbname != ''   raiserror('No database found with name %s.', 16, 1, @dbname)

-- check to see if the @dbname is an AG database
ELSE IF db_id(@dbname) is not null and @dbname != ''   and NOT EXISTS (select * from sys.availability_databases_cluster where database_name = @dbname) 
   raiserror('Database is not part of an Availability Group: %s.', 16, 1, @dbname)

ELSE IF SERVERPROPERTY('IsHadrEnabled') = 1
BEGIN
	DECLARE @ClusterNodes VARCHAR(8000) 
	SELECT @ClusterNodes = COALESCE(@ClusterNodes + ', ', '') + node_name
	FROM (select distinct node_name from sys.dm_hadr_availability_replica_cluster_nodes) a

	select   UPPER(case when SERVERPROPERTY('InstanceName') is null then dns_name
	           else CONCAT(dns_name, ISNULL(CONCAT('.', @DomainName), ''), '\', CAST(SERVERPROPERTY('InstanceName') as nvarchar(100)))  end) ConnString, 
			 UPPER(ag.name) AGName,
			 UPPER(dns_name) DNSName, 
			 UPPER(CAST(SERVERPROPERTY('InstanceName')  as nvarchar(100))) SQLInstance, 
			 UPPER(@ClusterNodes) ClusterNodes,
			 port TCPPort
			 from sys.availability_groups ag
			 inner join sys.availability_group_listeners agl on ag.group_id = agl.group_id
			 where cast(agl.group_id as varchar(100)) like case when @dbname is null or @dbname = '' then '%' 
			       else (select cast(group_id as varchar(100)) from sys.availability_databases_cluster where database_name = @dbname) END

END
ELSE IF SERVERPROPERTY('IsHadrEnabled') = 1 RAISERROR('SQL Server is not an AlwaysOn Cluster.', 16,1)
ELSE
	RAISERROR('Unknown error occurred.', 16,1)

