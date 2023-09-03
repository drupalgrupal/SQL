-- See blog post: https://sqlpal.blogspot.com/2020/01/getting-most-recent-transaction-log.html

SELECT
    D.NAME    DATABASE_NAME,
    AG.NAME   AG_NAME,
    DBL.LOG_BACKUP_TIME,
    DATEDIFF(MINUTE, DBL.LOG_BACKUP_TIME, GETDATE()) MinutesSinceLastLogBackup,
    HDRS.IS_PRIMARY_REPLICA,
    DBL.RECOVERY_MODEL,
    DBL.LOG_SINCE_LAST_LOG_BACKUP_MB,
    D.STATE_DESC,
    D.IS_READ_ONLY,
    D.LOG_REUSE_WAIT_DESC,
    DATABASEPROPERTYEX(D.NAME, 'Updateability') DATABASE_MODE

FROM
    SYS.DATABASES D
    LEFT JOIN SYS.DM_HADR_DATABASE_REPLICA_STATES HDRS 
         ON HDRS.GROUP_DATABASE_ID = D.GROUP_DATABASE_ID
            AND HDRS.REPLICA_ID = D.REPLICA_ID
    LEFT JOIN SYS.AVAILABILITY_GROUPS AG ON AG.GROUP_ID = HDRS.GROUP_ID 
    OUTER APPLY SYS.DM_DB_LOG_STATS ( D.DATABASE_ID )    DBL

WHERE  1 = 1
   AND DBL.RECOVERY_MODEL != 'SIMPLE'
--   AND DATEDIFF(MINUTE, DBL.LOG_BACKUP_TIME, GETDATE()) > 60*24

ORDER BY  DATABASE_NAME
