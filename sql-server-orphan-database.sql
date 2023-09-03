--  See blog post: https://sqlpal.blogspot.com/2018/09/find-orphaned-databases-in-sql-server.html
/*

By an orphan database, I mean a database that no one
is using anymore. Such databases can be a good 
candidate for taking them offline and
decommission.

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
       last_user_seek   DATETIME,
       last_user_scan   DATETIME,
       last_user_lookup DATETIME,
       last_user_update DATETIME
    )

go

EXEC Sp_msforeachdb
  ' use [?] if db_id() > 4 begin insert into ##t_dba_db_last_access_stats SELECT   DB_NAME() db_name,   CAST(DATABASEPROPERTYEX(DB_NAME(), ''Updateability'') AS NVARCHAR(256)) db_status,   last_user_seek = MAX(last_user_seek),   last_user_scan = MAX(last_user_scan),   last_user_lookup = MAX(last_user_lookup),   last_user_update = MAX(last_user_update) FROM sys.dm_db_index_usage_stats AS i WHERE i.database_id = DB_ID() AND OBJECTPROPERTY(i.object_id, ''ismsshipped'') != 1 end '

SELECT Getdate()                [current_time],
       @@servername             sql_instance,
       (SELECT crdate FROM   sysdatabases WHERE  NAME = 'tempdb') sql_instance_up_since,
       db_name,
       db_status,
       Max(last_accessed_date)  last_accessed
FROM   ##t_dba_db_last_access_stats a
       UNPIVOT ( last_accessed_date
               FOR last_accessed_for IN (last_user_seek,
                                         last_user_scan,
                                         last_user_lookup,
                                         last_user_update ) ) AS last_accessed
GROUP  BY db_name, db_status
UNION ALL                       -- Lets also grab list of OFFLINE databases
SELECT Getdate()  [current_time],
       @@servername sql_instance,
       (SELECT crdate 
               FROM   sysdatabases 
               WHERE  NAME = 'tempdb') sql_instance_up_since,
       NAME  db_name,
       Cast(Databasepropertyex(NAME, 'status') AS VARCHAR(50)) db_status,
       NULL last_accessed

FROM   sysdatabases
WHERE  NAME NOT IN ( 'master', 'model', 'msdb', 'tempdb' )
       AND Cast(Databasepropertyex(NAME, 'status') AS VARCHAR(50)) = 'OFFLINE'
ORDER  BY db_name

IF Object_id('##t_dba_db_last_access_stats') IS NOT NULL
  DROP TABLE ##t_dba_db_last_access_stats

go
