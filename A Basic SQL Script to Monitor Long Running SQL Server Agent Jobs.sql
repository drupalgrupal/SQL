-- See blog post: https://sqlpal.blogspot.com/2023/07/long-running-sql-server-jobs.html
-- 
/*==========================================================================================
  Script Name : Monitor_Long_Running_SQL_Agent_Jobs.sql

  Purpose     : 
      Identify currently running SQL Server Agent jobs that exceed a configurable 
      runtime threshold and optionally send an HTML email alert with details 
      (job name, duration, and command text).

  Context / Typical Use:
      - Scheduled as a SQL Agent job (e.g., every 5–10 minutes) on production 
        instances to detect runaway or stuck jobs.
      - Can be run interactively to quickly see which jobs are currently 
        running long.

  Key Behaviors (Why it is written this way):
      - Uses msdb job metadata plus dm_exec dynamic views to correlate SQL Agent 
        job execution with live session/request runtime metrics.
      - Filters only *currently running* jobs and applies a runtime threshold 
        (default: > 30 minutes) to avoid noise from short/expected jobs.
      - Builds an HTML table via FOR XML so the email is readable and easy to scan.
      - Skips the email step entirely when no qualifying long-running jobs exist.

  Assumptions / Requirements:
      - Database Mail is configured and usable on this instance.
      - Caller has appropriate permissions on msdb and server-level DMVs.
      - SQL Server Agent uses the standard "SQLAgent - TSQL JobStep" program_name 
        format for job sessions.

  Configuration Variables (at top of script):
      @MinutesThreshold  - Minimum runtime (minutes) before flagging as "long-running"
      @EmailRecipients   - Semicolon-delimited list of email addresses to notify
      @MailProfile       - Database Mail profile name (optional; uses default if NULL)

  How to Adjust:
      - Modify @MinutesThreshold for your SLA (e.g., 15 for aggressive monitoring).
      - Update @EmailRecipients for environment-specific oncall lists.
      - Set @MailProfile if you use named profiles instead of the default.

  Output:
      - Result set in SSMS with long-running jobs.
      - HTML email with one row per long-running job, when any are found.

  Maintenance Notes:
      - When changing thresholds, recipients, or HTML layout, keep this header 
        updated so behavior matches documentation.
      - If SQL Server version or Agent behavior changes (e.g., program_name 
        format), revisit the session-to-job mapping query.

  Last Updated:
      - 2026-01-29 : Added configurable @MinutesThreshold and @EmailRecipients variables.

==========================================================================================*/

-- ==========================================
-- CONFIGURATION VARIABLES - Modify these per environment
-- ==========================================
DECLARE @MinutesThreshold INT = 30;        -- Jobs running longer than this (minutes) trigger alerts
DECLARE @EmailRecipients  NVARCHAR(500) = '<dba-team@company.com;oncall@company.com>';  -- Semicolon-delimited recipients
DECLARE @MailProfile      NVARCHAR(128) = NULL;  -- Optional: Database Mail profile name; NULL uses default

-- PART 1: Check for active/running jobs and their duration so far
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#job_durations') IS NOT NULL 
    DROP TABLE #job_durations;

;WITH cte_jobs AS
(
    SELECT 
           sja.session_id AS [Session ID],
           sj.name        AS [Job Name], 
           r.command      AS [Command],

           -- WHY: We derive a simplified job status from start/stop times so that 
           --      downstream logic can just check [Status] instead of multiple datetime columns.
           [Status] = CASE
                WHEN sja.start_execution_date IS NULL THEN 'Not running'
                WHEN sja.start_execution_date IS NOT NULL 
                     AND sja.stop_execution_date IS NULL THEN 'Running'
                WHEN sja.start_execution_date IS NOT NULL 
                     AND sja.stop_execution_date IS NOT NULL THEN 'Not running'
           END,

           sja.start_execution_date AS [Job Start Time],

           r.total_elapsed_time         AS [Elapsed Milliseconds],
           r.total_elapsed_time / 1000  AS [Elapsed Seconds],
           r.total_elapsed_time / 1000 / 60        AS [Elapsed Minutes],
           r.total_elapsed_time / 1000 / 60 / 60   AS [Elapsed Hours],
           sj.job_id                    AS [Job ID] 

    FROM msdb..sysjobs sj
    INNER JOIN msdb..sysjobactivity sja 
        ON sj.job_id = sja.job_id

    -- WHY: SQL Agent job steps appear as sessions whose program_name starts with
    --      'SQLAgent - TSQL JobStep'.  This trick lets us map from dm_exec_sessions
    --      back to the msdb job_id by decoding the program_name.
    INNER JOIN (
        SELECT 
            TRY_CONVERT(binary(30), SUBSTRING(program_name, 30, 34), 1) AS job_id,
            *
        FROM sys.dm_exec_sessions 
        WHERE program_name LIKE 'SQLAgent - TSQL JobStep%'
    ) s ON sj.job_id = s.job_id

    LEFT JOIN sys.dm_exec_requests r 
        ON s.session_id = r.session_id

    WHERE sja.session_id = (
        SELECT MAX(session_id) 
        FROM msdb..sysjobactivity 
        WHERE job_id = sj.job_id
    )
)

-- Persist and enrich only the jobs that are currently running and above the threshold
SELECT 
    cte.*,

    -- Convert the duration into words
    -- WHY: This human-readable string is meant for quick eyeballing in an email 
    --      or SSMS result grid, especially during incident response.
    [Duration] = 
        CASE WHEN [Elapsed Hours] > 0 
             THEN CAST([Elapsed Hours] AS VARCHAR(20)) + ' Hours' 
             ELSE '' 
        END +

        CASE WHEN [Elapsed Minutes] > 0 AND [Elapsed Hours] = 0 
             THEN CAST([Elapsed Minutes] AS VARCHAR(20)) + ' Minutes' 
             ELSE '' 
        END +
        CASE WHEN [Elapsed Minutes] > 0 AND [Elapsed Hours] > 0 
             THEN ', ' + CAST([Elapsed Minutes] - ([Elapsed Hours]*60) AS VARCHAR(20)) 
                      + ' Minutes' 
             ELSE '' 
        END +

        CASE WHEN [Elapsed Seconds] > 0 AND [Elapsed Minutes] = 0 AND [Elapsed Hours] = 0 
             THEN CAST([Elapsed Seconds] AS VARCHAR(20)) + ' Seconds' 
             ELSE '' 
        END +
        CASE WHEN [Elapsed Seconds] > 0 AND [Elapsed Minutes] > 0 
             THEN ', ' + CAST([Elapsed Seconds] - ([Elapsed Minutes] * 60) AS VARCHAR(20)) 
                      + ' Seconds' 
             ELSE '' 
        END   
INTO #job_durations
FROM cte_jobs cte
WHERE [Status] = 'Running'            -- Only currently running jobs matter here
  AND [Elapsed Minutes] > @MinutesThreshold 

SELECT 
    [Session ID], 
    [Job Name], 
    [Command], 
    [Job Start Time], 
    [Duration], 
    [Elapsed Milliseconds] 
FROM #job_durations 
ORDER BY [Elapsed Milliseconds] DESC;

-- WHY: If there are no rows, we skip sending an email. Using GOTO here keeps
--      the control flow simple in a single script that may run under Agent.
IF @@ROWCOUNT = 0 
    GOTO QUIT;

-- PART 2: Send email alert

-- Variables for HTML-formatted email
DECLARE 
    @html_body       NVARCHAR(MAX), 
    @html_table_head VARCHAR(1000),  
    @html_table_tail VARCHAR(1000);

SET @html_table_tail = '</table></body></html>';

SET @html_table_head = 
      '<html><head>'
    + '<style>'
    + 'td {border: solid black;border-width: 1px;padding-left:5px;padding-right:5px;'
    + 'padding-top:1px;padding-bottom:1px;font: 15px arial} '
    + '</style>'
    + '</head>'
    + '<body>'  
    + '<pre style="font-weight: bold">'
    + 'SQL Server Instance: ' + @@SERVERNAME
    + '<br> <br> Report generated on : ' + CAST(GETDATE() AS VARCHAR(100))
    + '<br> <br> Long-running threshold: ' + CAST(@MinutesThreshold AS VARCHAR(10)) + ' minutes'
    + ' <br> <table cellpadding=0 cellspacing=0 border=0>' 
    + '<br> <tr> ' 
    + '<td bgcolor=#E6E6FA><b>Job Name</b></td>'
    + '<td bgcolor=#E6E6FA><b>Duration</b></td>'
    + '<td bgcolor=#E6E6FA><b>Command</b></td></tr>';

SET @html_body = (
    SELECT    
        td = LEFT([Job Name], 50), '',
        td = Duration, '',
        td = [Command], ''
    FROM #job_durations 
    ORDER BY [Elapsed Milliseconds] DESC
    FOR XML RAW('tr'), ELEMENTS
);

-- Combine header, body, and footer into a complete HTML document
SELECT @html_body = @html_table_head + ISNULL(@html_body, '') + @html_table_tail;

-- Send email with HTML body

DECLARE @EmailSubject NVARCHAR(500) = 'Long Running SQL Server Jobs found (>' + CAST(@MinutesThreshold AS VARCHAR(10)) + ' min)';
EXEC msdb.dbo.sp_send_dbmail  
       @profile_name = @MailProfile,  -- NULL uses default profile
       @recipients   = @EmailRecipients,  
       @body         = @html_body,  
       @subject      = @EmailSubject,
       @body_format  = 'HTML';

QUIT:

