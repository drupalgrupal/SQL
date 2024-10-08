/* DEPLOYS SP dbo.usp_start_job_and_wait

NOTE: THE SCRIPT CREATES THE SP IN CURRENT DATABASE

IF DESIRED, PLEAES CHANGE TO THE SPECIFIC DATABASE 
YOU WOULD LIKE TO CREATE THE STORED PROCEDURE IN

*/

IF OBJECT_ID('dbo.usp_start_job_and_wait', 'P') IS NOT NULL 
BEGIN
	PRINT 'Deleting existing stored procedure dbo.usp_start_job_and_wait ....'
	DROP PROCEDURE dbo.usp_start_job_and_wait;
END;


GO

/** NOTES REGARDING PARAMETER @WaitTime 

*  THOUGH NOT EXPLICITY ENFORCED, NOTICE THAT THE FORMAT FOR 
   @WaitTime PARAMETER IS IN HH:MM:SS STRING

   VALID RANGE: Any value between 00:00:01 and 23:59:59

* Examples: 
exec dbo.usp_start_job_and_wait N'Job - Test  Procedure usp_start_job_and_wait', @WaitTime = '00:00:01';
exec dbo.usp_start_job_and_wait N'Job - Test  Procedure usp_start_job_and_wait', @WaitTime = '23:59:59';
exec dbo.usp_start_job_and_wait N'Job - Test  Procedure usp_start_job_and_wait', @WaitTime = '00:00:11';
exec dbo.usp_start_job_and_wait N'Job - Test  Procedure usp_start_job_and_wait', @WaitTime = 1;


**/
PRINT 'Creating stored procedure dbo.usp_start_job_and_wait ....';
GO

CREATE PROCEDURE dbo.usp_start_job_and_wait  
(  
@job_name SYSNAME,
@WaitTime DATETIME = '00:00:05',  -- default check frequency in HH:MM:SS string format
@JobCompletionStatus INT = null OUTPUT
)  
AS  

SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED
SET NOCOUNT ON

-- CHECK IF IT IS A VALID AND EXISTING JOB NAME

IF NOT EXISTS (SELECT * FROM msdb..sysjobs WHERE name = @job_name)
BEGIN
       RAISERROR ('[ERROR]:[%s] job does not exist. Please check',16, 1, @job_name) WITH LOG
       RETURN
END


DECLARE @job_id      UNIQUEIDENTIFIER
DECLARE @job_owner   sysname

--Createing TEMP TABLE
CREATE TABLE #xp_results 
(
    job_id                UNIQUEIDENTIFIER NOT NULL,
    last_run_date         INT              NOT NULL,
    last_run_time         INT              NOT NULL,
    next_run_date         INT              NOT NULL,
    next_run_time         INT              NOT NULL,
    next_run_schedule_id  INT              NOT NULL,
    requested_to_run      INT              NOT NULL, -- BOOL
    request_source        INT              NOT NULL,
    request_source_id     sysname          COLLATE database_default NULL,
    running               INT              NOT NULL, -- BOOL
    current_step          INT              NOT NULL,
    current_retry_attempt INT              NOT NULL,
    job_state             INT              NOT NULL
)

SELECT @job_id = job_id FROM msdb.dbo.sysjobs WHERE name = @job_name

SELECT @job_owner = SUSER_SNAME()

INSERT INTO #xp_results EXECUTE master.dbo.xp_sqlagent_enum_jobs  1, @job_owner, @job_id

-- Start the job only if it is not already running
IF NOT EXISTS(SELECT TOP 1 * FROM #xp_results WHERE running = 1)
       EXEC msdb.dbo.sp_start_job @job_name = @job_name

-- Wait x seconds to ensure the job is startable and is indeed started
WAITFOR DELAY '00:00:02'

DELETE FROM #xp_results
INSERT INTO #xp_results
EXECUTE master.dbo.xp_sqlagent_enum_jobs  1, @job_owner, @job_id

WHILE EXISTS(SELECT TOP 1 * FROM #xp_results WHERE running = 1)
BEGIN

       WAITFOR DELAY @WaitTime

       -- Display informational message at each interval
       raiserror('JOB IS RUNNING', 0, 1 ) WITH NOWAIT 

       DELETE FROM #xp_results

       INSERT INTO #xp_results
       EXECUTE master.dbo.xp_sqlagent_enum_jobs  1, @job_owner, @job_id

END

SELECT top 1 @JobCompletionStatus = run_status    FROM msdb.dbo.sysjobhistory   
WHERE job_id = @job_id     AND step_id = 0   
order by run_date desc, run_time desc   


IF @JobCompletionStatus = 1
       PRINT 'The job ran Successful'
ELSE IF @JobCompletionStatus = 3
       PRINT 'The job is Cancelled'
ELSE
BEGIN
       RAISERROR ('[ERROR]:%s job is either failed or not in good state. Please check',16, 1, @job_name) WITH LOG
END
