-- See blog post: https://sqlpal.blogspot.com/2018/04/how-to-start-sql-server-job-using-tsql.html

/******************************************************************************
 Script Name: Start SQL Server job using TSQL and wait for it to complete
  Description:
     This script starts a SQL Agent job (if not already running) and continuously
     monitors its execution status until it finishes. The script then reports
     whether the job ran successfully, was canceled, or failed.

 Use Cases:
     - Automating job execution during deployments or maintenance windows.
     - Scripting job monitoring from SQLCMD or PowerShell sessions.
     - Verifying job status without opening SQL Server Management Studio (SSMS).

 Requirements:
     - Execute in the `msdb` context.
     - Requires SQLAgentOperatorRole permission or sysadmin access.
******************************************************************************/

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET NOCOUNT ON;

DECLARE
    @job_name SYSNAME       = 'TEST',           -- Specify the SQL Agent job name to run.
    @WaitTime DATETIME      = '00:00:05',       -- Interval in seconds to wait between job status checks.
    @JobCompletionStatus INT                    -- Will hold final job completion status (from msdb.dbo.sysjobhistory).
    

--==========================================================================
-- Validation: Ensure the specified job exists.
--==========================================================================
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @job_name)
BEGIN
    RAISERROR ('[ERROR]: Job [%s] does not exist. Please verify the job name.', 16, 1, @job_name) WITH LOG;
    RETURN;
END

DECLARE @job_id UNIQUEIDENTIFIER;
DECLARE @job_owner SYSNAME;

CREATE TABLE #xp_results 
(
    job_id                UNIQUEIDENTIFIER NOT NULL,
    last_run_date         INT              NOT NULL,
    last_run_time         INT              NOT NULL,
    next_run_date         INT              NOT NULL,
    next_run_time         INT              NOT NULL,
    next_run_schedule_id  INT              NOT NULL,
    requested_to_run      INT              NOT NULL, -- Boolean: 1 = requested to run
    request_source        INT              NOT NULL,
    request_source_id     SYSNAME          COLLATE database_default NULL,
    running               INT              NOT NULL, -- Boolean: 1 = currently running
    current_step          INT              NOT NULL,
    current_retry_attempt INT              NOT NULL,
    job_state             INT              NOT NULL
);

SELECT @job_id = job_id FROM msdb.dbo.sysjobs WHERE name = @job_name;
SELECT @job_owner = SUSER_SNAME();  -- Captures current execution context (job owner).

INSERT INTO #xp_results
EXEC master.dbo.xp_sqlagent_enum_jobs 1, @job_owner, @job_id;


--==========================================================================
-- Start the job only if it is not already running.
--==========================================================================
IF NOT EXISTS (SELECT 1 FROM #xp_results WHERE running = 1)
BEGIN
    EXEC msdb.dbo.sp_start_job @job_name = @job_name;
END


-- Small wait to let the job transition into "Running" state.
WAITFOR DELAY '00:00:02';

-- Refresh job status data.
DELETE FROM #xp_results;
INSERT INTO #xp_results
EXEC master.dbo.xp_sqlagent_enum_jobs 1, @job_owner, @job_id;


--==========================================================================
-- Monitor the running job until completion.
--==========================================================================
WHILE EXISTS (SELECT 1 FROM #xp_results WHERE running = 1)
BEGIN
    -- Display progress info to console immediately.
    RAISERROR('Job [%s] is currently running...', 0, 1, @job_name) WITH NOWAIT;

    -- Wait the configured interval before checking again.
    WAITFOR DELAY @WaitTime;

    -- Refresh job status snapshot.
    DELETE FROM #xp_results;
    INSERT INTO #xp_results
    EXEC master.dbo.xp_sqlagent_enum_jobs 1, @job_owner, @job_id;
END


--==========================================================================
-- Retrieve and report final job completion status.
--==========================================================================
SELECT TOP 1 @JobCompletionStatus = run_status
FROM msdb.dbo.sysjobhistory
WHERE job_id = @job_id
  AND step_id = 0              -- step_id = 0 represents the job outcome.
ORDER BY run_date DESC, run_time DESC;


-- run_status values:
-- 0 = Failed, 1 = Succeeded, 2 = Retry, 3 = Canceled, 4 = In-progress (rarely seen here).

IF @JobCompletionStatus = 1
    PRINT 'The job completed successfully.';
ELSE IF @JobCompletionStatus = 3
    PRINT 'The job was canceled.';
ELSE
    RAISERROR('[ERROR]: Job [%s] failed or did not complete successfully.', 16, 1, @job_name) WITH LOG;


--==========================================================================
-- Cleanup
--==========================================================================
DROP TABLE #xp_results;

