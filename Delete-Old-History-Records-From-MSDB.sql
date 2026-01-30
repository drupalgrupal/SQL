-- See blog post: https://sqlpal.blogspot.com/p/delete-old-history-records-from-msdb.html
--
/*==========================================================================================
  Script Name : Purge_MSDB_History_Cleanup.sql

  Purpose     : 
      Safely purges old history records from key MSDB tables using built-in system 
      stored procedures to reclaim space and improve query performance.

  Typical Use:
      - Schedule as a SQL Server Agent job to run daily,weekly,monthly etc 
      - Run after confirming backup retention requirements are met

  What Gets Cleaned:
      - Backup history (backupset, backupmediafamily tables)  
      - SQL Agent job history (jobhistory table)
      - Maintenance plan logs (sysplanlog, sysplanstepdetail tables)
      - Database Mail history (sysmail_mailitems, sysmail_event_log tables)

  Notes:
      - Uses Microsoft's built-in sp_* procedures instead of direct DELETEs to maintain 
        referential integrity between related MSDB tables
      - Creates a performance index on backupset.backup_finish_date if missing (helps 
        the cleanup procs run faster on bloated tables)
      - Single configurable @DaysRetention parameter controls all cleanup operations

  Configuration Variables:
      @DaysRetention    - Keep this many days of history (default: 365 = 1 year)
                          Adjust based on your backup retention policy and reporting needs

  Safety / Prerequisites:
      - Run as sysadmin or MSDB owner during maintenance window (can take minutes-hours)
      - Verify backup retention requirements before lowering @DaysRetention
      - Test on non-prod first - especially if MSDB > 10GB
      - Monitor disk space during execution (tempdb growth possible)

  Expected Impact:
      - Space reclaimed: 50-90% of MSDB size reduction typical
      - Performance: Query plans improve dramatically on history tables
      - Runtime: 5-60+ minutes depending on table sizes

  How to Monitor Progress:
      -- During execution, check:
      SELECT * FROM sys.dm_exec_requests WHERE command LIKE '%DELETE%';
      SELECT * FROM sys.dm_tran_active_snapshot_database_transactions;

  TESTING / DRY-RUN MODE (Strongly Recommended First):
  To test without making permanent changes
  Wrap the entire cleanup section inside a transaction
   
  Last Updated:
      - 2026-01-29 : Switched PRINT to RAISERROR for real-time messaging

==========================================================================================*/

SET NOCOUNT OFF; -- Yes we want to see affected rows count
USE msdb;
GO

-- BEGIN TRAN -- UNCOMMENT TO TEST

-- ==========================================
-- PERFORMANCE OPTIMIZATION (Optional but recommended)
-- ==========================================
IF NOT EXISTS(SELECT * FROM sys.indexes WHERE name = 'idx__backupset_backup_finish_date_for_cleanup')
BEGIN
    RAISERROR('Creating performance index on backupset.backup_finish_date...', 0, 1) WITH NOWAIT;
    
    CREATE NONCLUSTERED INDEX idx__backupset_backup_finish_date_for_cleanup
        ON [dbo].[backupset] ([backup_finish_date])
        INCLUDE ([media_set_id]);  -- Helps joins to backupmediafamily
    
    RAISERROR('Index created successfully.', 0, 1) WITH NOWAIT;
END
ELSE
    RAISERROR('Performance index already exists - skipping creation.', 0, 1) WITH NOWAIT;
GO

-- ==========================================
-- This parameter controls all retention
-- ==========================================
DECLARE @DaysRetention     INT     = 10;  -- Keep 1 year of history (adjust per policy)
DECLARE @DeleteBeforeDate  DATETIME;

SET @DeleteBeforeDate = DATEADD(DAY, -@DaysRetention, GETDATE());
-- Anything BEFORE this date gets purged

DECLARE @DeleteBeforeDateText NVARCHAR(100) = CONVERT(VARCHAR(23), @DeleteBeforeDate, 121);
RAISERROR('========================================', 0, 1) WITH NOWAIT;
RAISERROR('MSDB History Cleanup Starting...', 0, 1) WITH NOWAIT;
RAISERROR('Retention: %d days', 0, 1, @DaysRetention) WITH NOWAIT;
RAISERROR('Purging records BEFORE: %s', 0, 1, @DeleteBeforeDateText) WITH NOWAIT;
RAISERROR('========================================', 0, 1) WITH NOWAIT;

-- ==========================================
-- 1. BACKUP HISTORY CLEANUP (Usually biggest space saver)
-- ==========================================
RAISERROR('==> Cleaning up backup history...', 0, 1) WITH NOWAIT;
RAISERROR('    (backupset, backupmediafamily tables)', 0, 1) WITH NOWAIT;

EXEC sp_delete_backuphistory @oldest_date = @DeleteBeforeDate;

RAISERROR('    Backup history cleanup complete.', 0, 1) WITH NOWAIT;

-- ==========================================
-- 2. SQL AGENT JOB HISTORY CLEANUP
-- ==========================================
RAISERROR('==> Cleaning up SQL Agent job history...', 0, 1) WITH NOWAIT;
RAISERROR('    (jobhistory table)', 0, 1) WITH NOWAIT;

EXEC dbo.sp_purge_jobhistory @oldest_date = @DeleteBeforeDate;

RAISERROR('    Job history cleanup complete.', 0, 1) WITH NOWAIT;

-- ==========================================
-- 3. MAINTENANCE PLAN LOGS CLEANUP
-- ==========================================
RAISERROR('==> Cleaning up Maintenance Plan logs...', 0, 1) WITH NOWAIT;
RAISERROR('    (sysplanlog, sysplanstepdetail tables)', 0, 1) WITH NOWAIT;

EXEC sp_maintplan_delete_log @oldest_time = @DeleteBeforeDate;

RAISERROR('    Maintenance plan logs cleanup complete.', 0, 1) WITH NOWAIT;

-- ==========================================
-- 4. DATABASE MAIL HISTORY CLEANUP
-- ==========================================
RAISERROR('==> Cleaning up Database Mail history...', 0, 1) WITH NOWAIT;
RAISERROR('    (sysmail_mailitems, sysmail_event_log tables)', 0, 1) WITH NOWAIT;

-- Delete sent mail items
EXEC sysmail_delete_mailitems_sp @sent_before = @DeleteBeforeDate;

-- Delete mail log events  
EXEC sysmail_delete_log_sp @logged_before = @DeleteBeforeDate;

RAISERROR('    Database Mail history cleanup complete.', 0, 1) WITH NOWAIT;

-- ==========================================
-- FINAL STATUS
-- ==========================================
RAISERROR('========================================', 0, 1) WITH NOWAIT;
RAISERROR('MSDB History Cleanup COMPLETED SUCCESSFULLY!', 0, 1) WITH NOWAIT;
RAISERROR('Records older than %d days purged.', 0, 1, @DaysRetention) WITH NOWAIT;
RAISERROR('========================================', 0, 1) WITH NOWAIT;

-- ROLLBACK; -- UNCOMMENT TO TEST
