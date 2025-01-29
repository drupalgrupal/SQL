--  See blog post: https://sqlpal.blogspot.com/2018/09/find-orphaned-databases-in-sql-server.html
/*

By an orphan database, I mean a database that no one
is using anymore, essentially the users and apps
using this database either migrated to a different, 
possibly upgraded copy of this database or 
simply retired. 

Such databases can be a good 
candidate for taking them offline and
decommission.

Note: UNPIVOT

The script uses the UNPIVOT, which isn't the exact reverse of 
PIVOT. PIVOT carries out an aggregation and merges possible 
multiple rows into a single row in the output. UNPIVOT doesn't 
reproduce the original table-valued expression result, because 
rows have been merged. Also, NULL values in the input of UNPIVOT 
disappear in the output. When the values disappear, it shows 
that there might have been original NULL values in the input 
before the PIVOT operation.

https://learn.microsoft.com/en-us/sql/t-sql/queries/from-using-pivot-and-unpivot


*/


SET nocount ON
SET TRANSACTION isolation level READ uncommitted

USE master

go

IF Object_id('tempdb..##t_dba_db_last_access_stats') IS NOT NULL
  DROP TABLE ##t_dba_db_last_access_stats

go

DECLARE @db_activity_since INT
SET @db_activity_since = 90 -- days

IF Object_id('tempdb..##t_dba_db_last_access_stats') IS NULL
  CREATE TABLE ##t_dba_db_last_access_stats
    (
       db_name          NVARCHAR(256),
       db_status        NVARCHAR(256),
       db_updatibility  NVARCHAR(256),
       last_user_seek   DATETIME,
       last_user_scan   DATETIME,
       last_user_lookup DATETIME,
       last_user_update DATETIME
    )

GO

EXEC Sp_msforeachdb
 '
USE [?] 
IF db_id() > 4 
BEGIN 
	INSERT INTO ##t_dba_db_last_access_stats 
	SELECT   
		DB_NAME() db_name,   
		CAST(DATABASEPROPERTYEX(DB_NAME(), 
		''status'') AS NVARCHAR(256)) db_status,   
		CAST(DATABASEPROPERTYEX(DB_NAME(), 
		''updateability'') AS NVARCHAR(256)) updateability,   

		last_user_seek = MAX(last_user_seek),   
		last_user_scan = MAX(last_user_scan),   
		last_user_lookup = MAX(last_user_lookup),   
		last_user_update = MAX(last_user_update) 
	FROM sys.dm_db_index_usage_stats AS i 
	WHERE 
		i.database_id = DB_ID() 
		AND OBJECTPROPERTY(i.object_id, ''ismsshipped'') != 1 
END 
'

SELECT Getdate()                [current_time],
       @@servername             sql_instance,
       (SELECT crdate FROM   sysdatabases WHERE  NAME = 'tempdb') sql_instance_up_since,
       db_name,
       db_status,
	  db_updatibility,
       Max(last_accessed_date)  last_accessed
FROM   ##t_dba_db_last_access_stats a
       UNPIVOT ( last_accessed_date
               FOR last_accessed_for IN (last_user_seek,
                                         last_user_scan,
                                         last_user_lookup,
                                         last_user_update ) ) AS last_accessed
GROUP  BY db_name, db_status, db_updatibility
UNION ALL   -- Lets also grab list of OFFLINE databases
SELECT Getdate()  [current_time],
       @@servername sql_instance,
       (SELECT crdate 
               FROM   sysdatabases 
               WHERE  NAME = 'tempdb') sql_instance_up_since,
       NAME  db_name,
       Cast(Databasepropertyex(NAME, 'status') AS VARCHAR(50)) db_status,
	  Cast(Databasepropertyex(NAME, 'updateability') AS VARCHAR(50)) db_updatibility,
       NULL last_accessed

FROM   sysdatabases
WHERE  NAME NOT IN ( 'master', 'model', 'msdb', 'tempdb' )
       AND Cast(Databasepropertyex(NAME, 'updateability') AS VARCHAR(50)) = 'OFFLINE'

UNION ALL   -- Lets also grab databases with no activity whatsoever
SELECT Getdate()  [current_time],
       @@servername sql_instance,
       (SELECT crdate 
               FROM   sysdatabases 
               WHERE  NAME = 'tempdb') sql_instance_up_since,
       a.db_name db_name,
       Cast(Databasepropertyex(a.db_name, 'status') AS VARCHAR(50)) db_status,
       Cast(Databasepropertyex(a.db_name, 'updateability') AS VARCHAR(50)) db_updateability,
	  NULL last_accessed

FROM   ##t_dba_db_last_access_stats a
WHERE    a.last_user_lookup IS NULL
	AND a.last_user_scan IS NULL
	AND a.last_user_seek IS NULL
	AND a.last_user_update IS NULL
ORDER  BY db_name


IF Object_id('##t_dba_db_last_access_stats') IS NOT NULL
  DROP TABLE ##t_dba_db_last_access_stats

go
