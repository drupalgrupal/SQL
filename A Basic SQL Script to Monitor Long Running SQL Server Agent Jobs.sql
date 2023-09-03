-- See blog post: https://sqlpal.blogspot.com/2023/07/long-running-sql-server-jobs.html

-- PART 1: Check for active/running jobs and their duration so far
SET NOCOUNT ON
IF OBJECT_ID('tempdb..#job_durations') IS NOT NULL DROP TABLE #job_durations
go
;WITH cte_jobs AS
(
	SELECT 
	       sja.session_id [Session ID],
		   sj.Name [Job Name], 
		   r.command [Command],
		   [Status] = CASE
				WHEN sja.start_execution_date IS NULL THEN 'Not running'
				WHEN sja.start_execution_date IS NOT NULL AND sja.stop_execution_date IS NULL THEN 'Running'
				WHEN sja.start_execution_date IS NOT NULL AND sja.stop_execution_date IS NOT NULL THEN 'Not running'
				END,
		   sja.start_execution_date [Job Start Time],

		   -- the total_elapsed_time is in milliseconds
		   r.total_elapsed_time 'Elapsed Milliseconds',
		   r.total_elapsed_time / (1000) 'Elapsed Seconds',
		   r.total_elapsed_time / (1000) / 60 'Elapsed Minutes',
		   r.total_elapsed_time / (1000) / 60 / 60 'Elapsed Hours',
		   sj.job_id [Job ID] 

	FROM msdb..sysjobs sj
	INNER JOIN msdb..sysjobactivity sja ON sj.job_id = sja.job_id
	INNER JOIN (SELECT TRY_CONVERT(binary(30), SUBSTRING(program_name, 30, 34), 1) job_id, *
					FROM sys.dm_exec_sessions 
					WHERE program_name like 'SQLAgent - TSQL JobStep%') s on sj.job_id = s.job_id
	LEFT JOIN sys.dm_exec_requests r on s.session_id = r.session_id
	WHERE sja.session_id = (SELECT MAX(session_id) FROM msdb..sysjobactivity where job_id = sj.job_id)
)

SELECT cte.*,
		-- Convert the duration into words
		[Duration] = 
			CASE WHEN [Elapsed Hours] > 0 THEN CAST([Elapsed Hours] AS VARCHAR(20)) +' Hours' ELSE '' END +

			CASE WHEN [Elapsed Minutes] > 0 AND [Elapsed Hours] = 0 THEN CAST([Elapsed Minutes] AS VARCHAR(20)) +' Minutes' ELSE '' END +
			CASE WHEN [Elapsed Minutes] > 0 AND [Elapsed Hours] > 0 THEN ', ' + CAST([Elapsed Minutes] - ([Elapsed Hours]*60) AS VARCHAR(20)) + 
					', Minutes' ELSE '' END +

			CASE WHEN [Elapsed Seconds] > 0 AND [Elapsed Minutes] = 0 AND [Elapsed Hours] = 0 THEN CAST([Elapsed Seconds] AS VARCHAR(20)) +
					' Seconds' ELSE '' END  +
			CASE WHEN [Elapsed Seconds] > 0 AND [Elapsed Minutes] > 0 THEN ', ' + CAST([Elapsed Seconds] - ([Elapsed Minutes] * 60) AS VARCHAR(20)) +
					' Seconds' ELSE '' END   
		
INTO #job_durations
		
FROM cte_jobs cte
WHERE  1 = 1
AND [Status]	='Running'
AND [Elapsed Minutes] > 30
--    AND [Elapsed Hours] > 1
--    AND [Job Name] = 'DBA - Simulate Long Running Job'
;

SELECT [Session ID], [Job Name], Command, [Job Start Time], Duration, [Elapsed Milliseconds] FROM #job_durations order by [Elapsed Milliseconds] desc;

IF @@ROWCOUNT = 0 GOTO QUIT

-- PART 2: Send email alert

-- variables for html formatted email
declare @html_body NVARCHAR(MAX), @html_table_head VARCHAR(1000),  @html_table_tail VARCHAR(1000)
set @html_table_tail = '</table></body></html>' ;
set @html_table_head = '<html><head>' + '<style>'
	+ 'td {border: solid black;border-width: 1px;padding-left:5px;padding-right:5px;padding-top:1px;padding-bottom:1px;font: 15px arial} '
	+ '</style>' + '</head>' + '<body>'  
	+ '<pre style="font-weight: bold">'
	+ 'SQL Server Instance: ' + @@SERVERNAME

	+ '<br> <br> Report generated on : '+ cast(getdate() as varchar(100)) 
	+ ' <br> <table cellpadding=0 cellspacing=0 border=0>' 
	+ '<br> <tr> ' 
	+ '<td bgcolor=#E6E6FA><b>Job Name</b></td>'
	+ '<td bgcolor=#E6E6FA><b>Duration</b></td>'
	+ '<td bgcolor=#E6E6FA><b>Command</b></td></tr>' ;

set @html_body = ( SELECT    td = left([Job Name], 50), '',
td = Duration, '',
td = [Command], ''
FROM      #job_durations 
order by [Elapsed Milliseconds] desc
FOR   XML RAW('tr'),ELEMENTS);

SELECT  @html_body = @html_table_head + ISNULL(@html_body, '') + @html_table_tail

EXEC msdb.dbo.sp_send_dbmail  
   --    @profile_name = 'DBMail_DBA',  -- If using a named mail profile
		@recipients = '<EmailAddress>',  
		@body = @html_body,  
		@subject = 'Long Running SQL Server Jobs found',
		@body_format = 'HTML' ;
