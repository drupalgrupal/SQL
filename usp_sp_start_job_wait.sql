/******************************************************************************
NOTE: This script creates the stored procedure in the current database.
If desired, please change to the specific database where you want 
the stored procedure to be created.

Stored Procedure: dbo.usp_start_job_and_wait
Purpose: 
    Starts a specified SQL Server Agent job (if not currently running) 
    and monitors it until completion. Reports final job execution status.

Description:
    - Accepts a job name and an optional wait interval (@WaitTime)
      to control how frequently the job’s execution state is polled.
    - Waits for the SQL Agent job to finish, then outputs its run result.
    - Returns success/failure through @JobCompletionStatus output parameter.
    - Useful for automation pipelines, deployment scripts, and scheduled orchestration.

Dependencies:
    - Requires permissions to execute SQL Agent stored procedures:
      master.dbo.xp_sqlagent_enum_jobs and msdb.dbo.sp_start_job.
    - Must run under a context that has visibility into msdb job metadata.

Parameters:
@job_name SYSNAME --> Name of the SQL Agent job to run and monitor.
@WaitTime DATETIME -->
    Polling interval to recheck job status.
    Format: 'HH:MM:SS' (Default = '00:00:05').
    Valid Range: 00:00:01 – 23:59:59.
@JobCompletionStatus  INT OUTPUT -->
    Populated with the job’s final run_status value:
        0 = Failed, 1 = Succeeded, 2 = Retry, 3 = Canceled, 4 = In-progress.

Example Usage:
------------------------------------------------------------------------------
EXEC dbo.usp_start_job_and_wait 
     @job_name = N'Job - Test Procedure usp_start_job_and_wait',
     @WaitTime = '00:00:10';
******************************************************************************/

--================================================================================
-- Drop existing procedure if present
--================================================================================
IF OBJECT_ID('dbo.usp_start_job_and_wait', 'P') IS NOT NULL 
BEGIN
    PRINT 'Deleting existing stored procedure dbo.usp_start_job_and_wait ...';
    DROP PROCEDURE dbo.usp_start_job_and_wait;
END
GO

PRINT 'Creating stored procedure dbo.usp_start_job_and_wait ...';
GO

--================================================================================
-- Procedure Definition
--================================================================================
CREATE PROCEDURE dbo.usp_start_job_and_wait  
(
    @job_name SYSNAME,                        -- SQL Agent job name to execute
    @WaitTime DATETIME = '00:00:05',          -- Polling interval (HH:MM:SS format)
    @JobCompletionStatus INT = NULL OUTPUT    -- Job result (output)
)
AS
BEGIN
    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;  -- Prevent blocking when reading system tables

    --==========================================================================
    -- Validate that the specified job exists in msdb.
    --==========================================================================
    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @job_name)
    BEGIN
        RAISERROR('[ERROR]: [%s] job does not exist. Please check the name.', 16, 1, @job_name) WITH LOG;
        RETURN;
    END;

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
        requested_to_run      INT              NOT NULL,
        request_source        INT              NOT NULL,
        request_source_id     SYSNAME          COLLATE database_default NULL,
        running               INT              NOT NULL, -- Boolean: 1 = currently running
        current_step          INT              NOT NULL,
        current_retry_attempt INT              NOT NULL,
        job_state             INT              NOT NULL
    );

    -- Capture job metadata
    SELECT @job_id = job_id 
    FROM msdb.dbo.sysjobs 
    WHERE name = @job_name;

    SELECT 
        @job_owner = SUSER_SNAME();  -- Gets the executing user context

    -- Initial load of job status
    INSERT INTO #xp_results 
    EXEC master.dbo.xp_sqlagent_enum_jobs 1, @job_owner, @job_id;

    --==========================================================================
    -- Start the job if it is not already running
    --==========================================================================
    IF NOT EXISTS (SELECT 1 FROM #xp_results WHERE running = 1)
    BEGIN
        EXEC msdb.dbo.sp_start_job @job_name = @job_name;
    END;

    -- Short wait to allow job to transition into 'running' state
    WAITFOR DELAY '00:00:02';

    -- Refresh job state
    DELETE FROM #xp_results;
    INSERT INTO #xp_results
    EXEC master.dbo.xp_sqlagent_enum_jobs 1, @job_owner, @job_id;

    --==========================================================================
    -- Loop until the job is no longer running.
    --==========================================================================
    WHILE EXISTS (SELECT 1 FROM #xp_results WHERE running = 1)
    BEGIN
        RAISERROR('Job [%s] is running...', 0, 1, @job_name) WITH NOWAIT;
        WAITFOR DELAY @WaitTime;  -- Wait defined interval before polling again

        DELETE FROM #xp_results;
        INSERT INTO #xp_results
        EXEC master.dbo.xp_sqlagent_enum_jobs 1, @job_owner, @job_id;
    END;

    --==========================================================================
    -- Evaluate the final job status and return output.
    --==========================================================================
    SELECT TOP (1) @JobCompletionStatus = run_status
    FROM msdb.dbo.sysjobhistory
    WHERE job_id = @job_id
        AND step_id = 0   -- step_id = 0 indicates the job outcome
    ORDER BY run_date DESC, run_time DESC;

    --==========================================================================
    -- Display result message based on job completion status.
    --==========================================================================
    IF @JobCompletionStatus = 1
        PRINT 'The job completed successfully.';
    ELSE IF @JobCompletionStatus = 3
        PRINT 'The job was canceled by a user or system process.';
    ELSE
        RAISERROR('[ERROR]: Job [%s] failed or did not complete successfully.', 16, 1, @job_name) WITH LOG;

    --==========================================================================
    -- Cleanup temporary table
    --==========================================================================
    DROP TABLE #xp_results;
END;
GO

