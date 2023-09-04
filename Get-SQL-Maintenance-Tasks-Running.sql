-- See blog post: https://sqlpal.blogspot.com/p/database-maintainance-in-progress.html

SET NOCOUNT ON
SELECT r.session_id as SPID, 
       r.command, 
       a.text query_text, 
       r.start_time, 
       datediff(MINUTE, r.start_time, GETDATE()) duration_minutes,
       r.percent_complete, 
       dateadd(second,r.estimated_completion_time/1000, getdate()) estimated_completion_time 
FROM sys.dm_exec_requests r 
     CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) a 
WHERE   1=1
AND 
	(
		    r.command like 'BACKUP%' 
		or  r.command like 'RESTORE%' 
		or  r.command like 'DBCC%' 
		or  r.command like 'UPDATE STATISTIC%'
	)
