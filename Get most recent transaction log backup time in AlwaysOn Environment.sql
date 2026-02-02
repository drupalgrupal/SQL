-- See blog post:
--   https://sqlpal.blogspot.com/2020/01/most-recent-sql-log-backup-time.html

/*****************************************************************************************
 Purpose:
   Show, per database, when the last transaction log backup occurred and how much
   log has accumulated since then, with Availability Group context where applicable.

 Notes:
   - Uses sys.dm_db_log_stats (SQL Server 2017+) to get last log backup time and
     log size generated since that backup.
   - Filters out SIMPLE recovery model databases because they do not use log backups.
   - log_reuse_wait_desc gives you the reason log cannot be reused yet (if any).

 Usage:
   - Run in any database (master is fine).
   - Optionally uncomment the WHERE clause warning line to highlight databases
     that have not had a log backup in more than N minutes (e.g. 60*24 for 24 hours).

******************************************************************************************/

SELECT
    D.name  AS DATABASE_NAME, 
    AG.name AS AG_NAME,                    -- If applicable
    DBL.log_backup_time AS LOG_BACKUP_TIME,

    -- How many minutes have elapsed since the last log backup.
    DATEDIFF(MINUTE, DBL.log_backup_time, GETDATE()) AS MinutesSinceLastLogBackup,

    HDRS.is_primary_replica,
    DBL.recovery_model,

    -- Approximate amount of log generated since the last log backup
    DBL.log_since_last_log_backup_mb,

    D.state_desc,
    D.is_read_only,
    D.log_reuse_wait_desc,
    DATABASEPROPERTYEX(D.name, 'Updateability') AS DATABASE_MODE

FROM
    sys.databases AS D
    LEFT JOIN sys.dm_hadr_database_replica_states AS HDRS
        ON HDRS.group_database_id = D.group_database_id
       AND HDRS.replica_id        = D.replica_id
    LEFT JOIN sys.availability_groups AS AG
        ON AG.group_id = HDRS.group_id 
    OUTER APPLY sys.dm_db_log_stats(D.database_id) AS DBL

WHERE
      1 = 1
  AND DBL.recovery_model <> 'SIMPLE'
  -- Optional - Uncomment and adjust threshold as needed 
  -- - (e.g., 60 for 1 hour, 60*4 for 4 hours, etc.).
  -- AND DATEDIFF(MINUTE, DBL.log_backup_time, GETDATE()) > 60 * 24

ORDER BY DATABASE_NAME;

