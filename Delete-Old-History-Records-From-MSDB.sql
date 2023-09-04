-- See blog post: https://sqlpal.blogspot.com/p/delete-old-history-records-from-msdb.html

/*
Using the buil-in system stored procedures, purges history records from MSDB:

- Backup History
- Jobs history
- Mantainance plan logs history
- DB mail history


*/

use msdb
go
-- Add index on backupset table to improve performance
if not exists(select * from sys.indexes where name = 'idx__backupset_backup_finish_date_for_cleanup')
		CREATE NONCLUSTERED INDEX idx__backupset_backup_finish_date_for_cleanup
		ON [dbo].[backupset] ([backup_finish_date])
		INCLUDE ([media_set_id])
go

declare @days int, @delete_before_date datetime
-- Delete history records older than x days
set @days = 365                                      
set @delete_before_date = GETDATE()-@days


print 'Cleaning up backup history....'
exec sp_delete_backuphistory @oldest_date =  @delete_before_date

print 'Cleaning up job history....'
EXECUTE dbo.sp_purge_jobhistory @oldest_date = @delete_before_date

print 'Cleaning up mantainance plan logs history....'
EXEC sp_maintplan_delete_log @oldest_time = @delete_before_date

print 'Cleaning up db mail history....'
exec sysmail_delete_mailitems_sp  @sent_before = @delete_before_date 
exec sysmail_delete_log_sp  @logged_before = @delete_before_date

