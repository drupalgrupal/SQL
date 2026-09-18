/*
SQL Server Transaction Log Forensics: A Hands-On sys.fn_dblog Lab
Companion material for SQLPal: https://sqlpal.blogspot.com/
Version: 1.1

TARGET: SQL Server 2017 (14.x) and later, installed Database Engine.
Not designed for Azure SQL Database, Azure SQL Managed Instance, or Synapse.
Uses compatibility level 140 and avoids post-2017 T-SQL syntax.
fn_dblog is undocumented: future builds can change its interface or behavior.
VALIDATION: Tested on SQL Server 2022

READ FIRST
  * Disposable, isolated NON-PRODUCTION instance only; sysadmin required.
  * Run the ENTIRE file in one new SSMS query window / sqlcmd connection.
  * No SQLCMD mode, GO separators, trace flags, or external libraries required.
  * Change @IUnderstandThisIsADisposableLab to 1 before running.
  * An existing database of this name causes an immediate stop, never a drop.
  * This creates a database and a real baseline .bak file on the SERVER.
  * An optional backup directory must already exist and be writable by the
    SQL Server service account. Otherwise the instance's default BACKUP folder
    is used. SQL Server 2019+ exposes InstanceDefaultBackupPath; SQL Server
    2017 on Windows uses the instance-aware BackupDirectory registry setting.
    If discovery is unavailable, supply @BackupDirectory explicitly; the lab
    never silently substitutes the data directory.
  * Exclude this lab database from any automated log-backup / maintenance jobs.
    Use a truly isolated instance if you cannot guarantee that exclusion.
  * FULL recovery + a conventional baseline full backup establish the lab's
    backup chain. No log backups are taken here. This is NOT a recommendation
    to pause production backups. Do not leave this database receiving writes.
  * The script leaves the database, evidence, and backup for you to inspect.
    Optional cleanup is commented out at the end and also supplied separately.
    It force-disconnects lab sessions and rolls back their open transactions.
    Errors in the lab do NOT automatically delete partial results.
  * If execution is cancelled, confirm @@TRANCOUNT = 0 in this connection;
    ROLLBACK any remaining lab transaction before continuing.
  * In real data loss, engage Microsoft Support and your incident lead early.

WHAT YOU WILL DO
  Setup -> baseline backup -> INSERT / UPDATE / DELETE / TRUNCATE / ROLLBACK
  -> capture fn_dblog ONCE -> investigate the saved evidence -> verify results.
*/

-- ===========================================================================
-- SETTINGS AND SAFETY GATES
-- No destructive statement runs before these checks.
-- ===========================================================================
DECLARE @IUnderstandThisIsADisposableLab bit = 0; -- Change to 1 intentionally.
DECLARE @BackupDirectory nvarchar(3500) = NULL;
-- Examples: N'D:\SQLLabBackups' or N'/var/opt/mssql/backup'

DECLARE @MajorVersion int = TRY_CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));
DECLARE @EngineEdition int = TRY_CONVERT(int, SERVERPROPERTY('EngineEdition'));
DECLARE @RunId uniqueidentifier = NEWID();
DECLARE @BackupFile nvarchar(4000);
DECLARE @Separator nchar(1);
DECLARE @CreatedDatabase bit = 0;

IF @IUnderstandThisIsADisposableLab <> 1
    THROW 51000, 'Read the header, then explicitly enable the disposable-lab setting.', 1;

IF @MajorVersion IS NULL OR @MajorVersion < 14
    THROW 51001, 'This lab targets SQL Server 2017 (14.x) and later.', 1;

IF @EngineEdition NOT IN (2, 3, 4)
    THROW 51002, 'Use an installed SQL Server Standard/Web, Enterprise/Developer, or Express instance.', 1;

IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) <> 1
    THROW 51003, 'This isolated lab requires sysadmin. Do not elevate production access for it.', 1;

IF @@TRANCOUNT <> 0
    THROW 51004, 'An existing transaction is open. Use a fresh connection.', 1;

IF (@@OPTIONS & 2) = 2
    THROW 51005, 'IMPLICIT_TRANSACTIONS must be OFF. Use a fresh connection.', 1;

IF DB_ID(N'SQLPal_LogForensicsLab') IS NOT NULL
    THROW 51006, 'SQLPal_LogForensicsLab already exists. Inspect it; use the optional cleanup block only if appropriate.', 1;

IF OBJECT_ID(N'tempdb..#SQLPalLabContext') IS NOT NULL
    THROW 51007, 'A lab context already exists in this session. Use a new connection.', 1;

SET NOCOUNT ON;
SET XACT_ABORT ON;

IF @BackupDirectory IS NULL
BEGIN
    IF @MajorVersion >= 15
        SET @BackupDirectory = CONVERT(nvarchar(3500), SERVERPROPERTY('InstanceDefaultBackupPath'));

    -- SQL Server 2017 lacks InstanceDefaultBackupPath. On Windows this
    -- instance-aware, read-only lookup also handles named instances. [S7, S8]
    -- Do not assume a Windows registry setting exists on SQL Server on Linux.
    IF NULLIF(LTRIM(RTRIM(@BackupDirectory)), N'') IS NULL
       AND EXISTS (SELECT 1 FROM sys.dm_os_host_info WHERE host_platform = N'Windows')
    BEGIN
        BEGIN TRY
            EXEC master.dbo.xp_instance_regread
                N'HKEY_LOCAL_MACHINE',
                N'SOFTWARE\Microsoft\MSSQLServer\MSSQLServer',
                N'BackupDirectory',
                @BackupDirectory OUTPUT;
        END TRY
        BEGIN CATCH
            THROW 51009, 'Default backup directory lookup failed. Set @BackupDirectory explicitly and rerun.', 1;
        END CATCH;
    END;
END;

IF NULLIF(LTRIM(RTRIM(@BackupDirectory)), N'') IS NULL
    THROW 51008, 'Default backup directory is unavailable. Set @BackupDirectory to an existing server-side writable backup directory.', 1;

SET @Separator = CASE WHEN CHARINDEX(N'/', @BackupDirectory) > 0 THEN N'/' ELSE N'\' END;
IF RIGHT(@BackupDirectory, 1) NOT IN (N'/', N'\')
    SET @BackupDirectory = @BackupDirectory + @Separator;

-- A unique filename; no FORMAT or INIT, and no operating-system file deletion.
SET @BackupFile = @BackupDirectory + N'SQLPal_LogForensicsLab_'
    + REPLACE(CONVERT(nvarchar(36), @RunId), N'-', N'') + N'.bak';

CREATE TABLE #SQLPalLabContext
(
    RunId uniqueidentifier NOT NULL,
    BackupFile nvarchar(4000) NOT NULL,
    SetupStartedAt datetime2(3) NOT NULL,
    IncidentStartAt datetime2(3) NULL,
    IncidentEndAt datetime2(3) NULL,
    CaptureStartedAt datetime2(3) NULL,
    CaptureCompletedAt datetime2(3) NULL,
    OriginalLogin sysname NOT NULL,
    SessionId int NOT NULL
);

INSERT #SQLPalLabContext (RunId, BackupFile, SetupStartedAt, OriginalLogin, SessionId)
VALUES (@RunId, @BackupFile, SYSDATETIME(), ORIGINAL_LOGIN(), @@SPID);

BEGIN TRY
    -- Dynamic batches deliberately avoid USE against a database that did not
    -- exist at initial compilation. An error stops this single outer batch.
    EXEC (N'CREATE DATABASE [SQLPal_LogForensicsLab];');
    SET @CreatedDatabase = 1;

    EXEC (N'ALTER DATABASE [SQLPal_LogForensicsLab] SET COMPATIBILITY_LEVEL = 140;');
    EXEC (N'ALTER DATABASE [SQLPal_LogForensicsLab] SET RECOVERY FULL;');
    EXEC (N'ALTER DATABASE [SQLPal_LogForensicsLab] SET AUTO_CLOSE OFF;');
    EXEC (N'ALTER DATABASE [SQLPal_LogForensicsLab] SET AUTO_SHRINK OFF;');

    -- ADR does not exist in 2017. Keep its syntax inside a version-gated
    -- dynamic batch. OFF normalizes this particular teaching setup on 2019+;
    -- do not change production ADR settings to run a forensic query.
    IF @MajorVersion >= 15
        EXEC (N'ALTER DATABASE [SQLPal_LogForensicsLab] SET ACCELERATED_DATABASE_RECOVERY = OFF;');

    -- =======================================================================
    -- SETUP: deliberately simple, uncompressed rowstore tables.
    -- =======================================================================
    EXEC sys.sp_executesql N'
USE [SQLPal_LogForensicsLab];

EXEC sys.sp_addextendedproperty
    @name = N''SQLPalLabIdentity'',
    @value = N''SQLPal.LogForensics.DisposableLab.v1'';

CREATE TABLE dbo.Customers
(
    CustomerId int NOT NULL CONSTRAINT PK_Customers PRIMARY KEY CLUSTERED,
    CustomerName varchar(40) NOT NULL,
    CreditLimit int NOT NULL
);

INSERT dbo.Customers (CustomerId, CustomerName, CreditLimit)
VALUES (1, ''Alice'', 1000), (2, ''Bob'', 2000), (3, ''Carla'', 3000),
       (4, ''Dev'', 4000), (5, ''Elena'', 5000), (6, ''Farid'', 6000);

CREATE TABLE dbo.WorkQueue
(
    WorkId int NOT NULL CONSTRAINT PK_WorkQueue PRIMARY KEY CLUSTERED,
    WorkDescription varchar(60) NOT NULL
);

INSERT dbo.WorkQueue (WorkId, WorkDescription)
VALUES (101, ''Invoice export''), (102, ''Customer reconciliation''),
       (103, ''Daily report'');

-- Known pre-incident rows are an answer key, NOT evidence recovered from log
-- bytes. They let you verify observations without inventing a row decoder.
SELECT * INTO dbo.CustomersBefore FROM dbo.Customers;
SELECT * INTO dbo.WorkQueueBefore FROM dbo.WorkQueue;

-- Capture allocation mapping BEFORE TRUNCATE changes it. Even this mapping
-- is a teaching convenience; it might not exist when a real incident begins.
-- All table allocations here are IN_ROW_DATA, mapped through hobt_id.
SELECT
    s.name AS SchemaName, t.name AS TableName, t.object_id AS ObjectId,
    p.index_id AS IndexId, p.partition_number AS PartitionNumber,
    p.hobt_id AS HobtId, au.allocation_unit_id AS AllocationUnitId,
    au.type_desc AS AllocationType
INTO dbo.AllocationMapBefore
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
JOIN sys.partitions AS p ON p.object_id = t.object_id
JOIN sys.allocation_units AS au ON au.container_id = p.hobt_id AND au.type = 1
WHERE s.name = N''dbo'' AND t.name IN (N''Customers'', N''WorkQueue'');

CREATE TABLE dbo.ScenarioGuide
(
    SequenceNumber int NOT NULL PRIMARY KEY,
    TransactionName nvarchar(32) NOT NULL,
    IntendedAction nvarchar(200) NOT NULL,
    ExpectedOutcome varchar(10) NOT NULL
);

INSERT dbo.ScenarioGuide
VALUES
 (1, N''Lab_Insert'', N''Insert CustomerId 7 (Grace)'', ''COMMIT''),
 (2, N''Lab_Update'', N''Change Bob credit limit from 2000 to 2500'', ''COMMIT''),
 (3, N''Lab_Delete'', N''Delete customers 3 and 4'', ''COMMIT''),
 (4, N''Lab_Truncate'', N''Truncate the separate WorkQueue table'', ''COMMIT''),
 (5, N''Lab_Rollback'', N''Delete customer 5, then roll the transaction back'', ''ROLLBACK'');

SELECT N''01: Baseline customers (answer key)'' AS ResultSet;
SELECT * FROM dbo.Customers ORDER BY CustomerId;
SELECT N''02: Baseline queue (answer key)'' AS ResultSet;
SELECT * FROM dbo.WorkQueue ORDER BY WorkId;
';

    -- A REAL conventional full backup starts the FULL recovery backup chain.
    -- No NUL device, no COPY_ONLY shortcut, and no backup-compression dependency.
    BACKUP DATABASE [SQLPal_LogForensicsLab]
        TO DISK = @BackupFile
        WITH CHECKSUM, NAME = N'SQLPal forensic lab baseline';

    -- =======================================================================
    -- INCIDENT, EVIDENCE CAPTURE, AND INVESTIGATION
    -- =======================================================================
    EXEC sys.sp_executesql N'
USE [SQLPal_LogForensicsLab];

UPDATE #SQLPalLabContext SET IncidentStartAt = SYSDATETIME();

-- Names are teaching labels, NOT something to expect from ordinary apps.
-- These are five independent transactions, not nested transactions. [S3, S5]
BEGIN TRANSACTION Lab_Insert;
INSERT dbo.Customers VALUES (7, ''Grace'', 7000);
COMMIT TRANSACTION;

BEGIN TRANSACTION Lab_Update;
UPDATE dbo.Customers SET CreditLimit = 2500 WHERE CustomerId = 2;
COMMIT TRANSACTION;

BEGIN TRANSACTION Lab_Delete;
DELETE dbo.Customers WHERE CustomerId IN (3, 4);
COMMIT TRANSACTION;

BEGIN TRANSACTION Lab_Truncate;
TRUNCATE TABLE dbo.WorkQueue;
COMMIT TRANSACTION;

BEGIN TRANSACTION Lab_Rollback;
DELETE dbo.Customers WHERE CustomerId = 5;
ROLLBACK TRANSACTION;

UPDATE #SQLPalLabContext
SET IncidentEndAt = SYSDATETIME(), CaptureStartedAt = SYSDATETIME();

-- THE ONLY fn_dblog CALL IN THIS LAB.
-- First materialize its full output in tempdb, not into the source database.
-- This is an educational snapshot, not a transactionally consistent physical
-- image, a log backup, or a replacement for a full forensic acquisition.
-- fn_dblog(NULL,NULL) reads the available range, not an unlimited history.
SELECT * INTO #CapturedLog
FROM sys.fn_dblog(NULL, NULL);

UPDATE #SQLPalLabContext SET CaptureCompletedAt = SYSDATETIME();

-- Persist AFTER the scan so you can close SSMS and investigate later.
-- Same-database storage is acceptable ONLY for this disposable exercise.
-- In a real incident use an approved separate evidence destination.
-- These later writes cannot change the materialized #CapturedLog result.
SELECT * INTO dbo.LogEvidence FROM #CapturedLog;

SELECT
    c.*, CONVERT(nvarchar(128), SERVERPROPERTY(''ServerName'')) AS ServerName,
    CONVERT(nvarchar(128), SERVERPROPERTY(''ProductVersion'')) AS ProductVersion,
    CONVERT(nvarchar(128), SERVERPROPERTY(''ProductLevel'')) AS ProductLevel,
    CONVERT(nvarchar(128), SERVERPROPERTY(''Edition'')) AS Edition,
    CONVERT(nvarchar(4000), @@VERSION) AS VersionDetails,
    SYSDATETIMEOFFSET() AS ManifestRecordedAtWithOffset,
    CONVERT(bigint, (SELECT COUNT_BIG(*) FROM dbo.LogEvidence)) AS CapturedRecords,
    CONVERT(int, 140) AS LabCompatibilityLevel,
    CONVERT(nvarchar(40), N''FULL; ADR OFF where available'') AS LabConfiguration
INTO dbo.LabRun
FROM #SQLPalLabContext AS c;

-- Sanity checks. Fail loudly rather than present an incomplete lab as success.
IF (SELECT COUNT(*) FROM dbo.Customers) <> 5
    THROW 51100, ''Unexpected final customer count; inspect the lab.'', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.Customers WHERE CustomerId = 5)
    THROW 51101, ''The rollback example did not preserve customer 5.'', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.Customers WHERE CustomerId = 2 AND CreditLimit = 2500)
    THROW 51102, ''The update example did not produce its expected result.'', 1;
IF EXISTS (SELECT 1 FROM dbo.WorkQueue)
    THROW 51103, ''The truncate example did not empty WorkQueue.'', 1;

-- Result 03: an exact build and capture manifest for reproducibility.
SELECT N''03: Build, time window, and backup location'' AS ResultSet;
SELECT * FROM dbo.LabRun;

-- Result 04: broad discovery BEFORE looking up our transaction labels.
-- Some log records have no AllocUnitName. Never treat NULL as no activity.
SELECT N''04: Operations present in the snapshot'' AS ResultSet;
SELECT [Operation], [Context], COUNT_BIG(*) AS LogRecordCount
FROM dbo.LogEvidence
GROUP BY [Operation], [Context]
ORDER BY LogRecordCount DESC, [Operation], [Context];

-- Result 05: identify candidate deletes by physical allocation, NOT by label.
-- The rolled-back delete is deliberately included: a delete record alone
-- does not establish that the transaction committed. [S1, S2]
SELECT N''05: Customer-delete candidates without transaction-name hints'' AS ResultSet;
SELECT e.[Current LSN], e.[Transaction ID], e.[Operation], e.[Context],
       m.SchemaName, m.TableName, e.[AllocUnitId], e.[Page ID], e.[Slot ID]
FROM dbo.LogEvidence AS e
JOIN dbo.AllocationMapBefore AS m
  ON TRY_CONVERT(bigint, e.[AllocUnitId]) = m.AllocationUnitId
WHERE m.TableName = N''Customers''
  AND e.[Operation] = N''LOP_DELETE_ROWS''
ORDER BY e.[Current LSN];

-- Result 06: all captured transaction beginnings. This is the independent
-- discovery view; the scenario guide is revealed only in the next result.
-- Times are server-local values here. Record offsets and reconcile clocks.
-- SID identifies a security context, not necessarily the human at a keyboard.
-- Shared accounts, impersonation, dropped logins, and NULL mappings matter.
-- SPIDs are reused; a SPID alone is not a durable identity. [S1]
SELECT N''06: Transaction beginnings, times, and security context'' AS ResultSet;
SELECT [Current LSN], [Transaction ID], [Transaction Name], [Begin Time],
       [SPID], [Transaction SID],
       SUSER_SNAME([Transaction SID]) AS ResolvedLoginAtQueryTime
FROM dbo.LogEvidence
WHERE [Operation] = N''LOP_BEGIN_XACT''
ORDER BY [Current LSN];

-- Teaching labels identify the five root transactions. Do not infer all
-- system/sub-transaction work belongs to the same ID. See Parent Transaction
-- ID in the raw output and Paul Randal''s explanation. [S6]
SELECT g.SequenceNumber, g.TransactionName, g.IntendedAction, g.ExpectedOutcome,
       b.[Transaction ID] AS TransactionId,
       b.[Current LSN] AS BeginLSN, b.[Begin Time] AS BeginTime,
       b.[Transaction SID] AS TransactionSID
INTO dbo.ScenarioTransactions
FROM dbo.ScenarioGuide AS g
JOIN dbo.LogEvidence AS b
  ON b.[Transaction Name] = g.TransactionName
 AND b.[Operation] = N''LOP_BEGIN_XACT'';

IF EXISTS
(
    SELECT g.SequenceNumber
    FROM dbo.ScenarioGuide AS g
    LEFT JOIN dbo.ScenarioTransactions AS t ON t.SequenceNumber = g.SequenceNumber
    GROUP BY g.SequenceNumber
    HAVING COUNT(t.TransactionId) <> 1
)
    THROW 51104, ''Missing/ambiguous labeled transaction. Inspect raw evidence, backup jobs, and build-specific fn_dblog behavior.'', 1;

SELECT N''07: Teaching answer key with observed transaction boundaries'' AS ResultSet;
SELECT t.SequenceNumber, t.TransactionName, t.IntendedAction, t.BeginLSN,
       t.BeginTime, t.ExpectedOutcome, e.[Operation] AS ObservedEndOperation,
       e.[Current LSN] AS EndLSN, e.[End Time],
       SUSER_SNAME(t.TransactionSID) AS ResolvedLoginAtQueryTime
FROM dbo.ScenarioTransactions AS t
LEFT JOIN dbo.LogEvidence AS e
  ON e.[Transaction ID] = t.TransactionId
 AND e.[Operation] IN (N''LOP_COMMIT_XACT'', N''LOP_ABORT_XACT'')
ORDER BY t.SequenceNumber, e.[Current LSN];

IF EXISTS
(
    SELECT 1 FROM dbo.ScenarioTransactions AS t
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dbo.LogEvidence AS e
        WHERE e.[Transaction ID] = t.TransactionId
          AND e.[Operation] = CASE WHEN t.ExpectedOutcome = ''COMMIT''
                                  THEN N''LOP_COMMIT_XACT'' ELSE N''LOP_ABORT_XACT'' END
    )
)
    THROW 51105, ''A required commit/abort boundary is missing. Do not treat incomplete evidence as proof.'', 1;

-- Result 08: follow every record with each root transaction ID.
-- Inspect the user allocation vs system metadata before interpreting a row
-- operation. A system-table LOP_DELETE_ROWS is not a deleted customer row.
SELECT N''08: Full record trail for the five root transactions'' AS ResultSet;
SELECT t.TransactionName, e.[Current LSN], e.[Previous LSN],
       e.[Transaction ID], e.[Parent Transaction ID], e.[Operation],
       e.[Context], e.[AllocUnitName], e.[AllocUnitId],
       e.[Page ID], e.[Slot ID], e.[Description]
FROM dbo.ScenarioTransactions AS t
JOIN dbo.LogEvidence AS e ON e.[Transaction ID] = t.TransactionId
ORDER BY t.SequenceNumber, e.[Current LSN];

-- Result 09: view raw row fragments without pretending they are complete
-- rows or original SQL text. No hardcoded binary offsets, byte casts, or
-- generic undo generator. Row formats and update logging vary.
SELECT N''09: Row-log bytes for UPDATE and committed DELETE'' AS ResultSet;
SELECT t.TransactionName, e.[Current LSN], e.[Operation], e.[Context],
       e.[AllocUnitName], e.[RowLog Contents 0], e.[RowLog Contents 1]
FROM dbo.ScenarioTransactions AS t
JOIN dbo.LogEvidence AS e ON e.[Transaction ID] = t.TransactionId
WHERE t.TransactionName IN (N''Lab_Update'', N''Lab_Delete'')
  AND e.[Operation] IN
      (N''LOP_MODIFY_ROW'', N''LOP_MODIFY_COLUMNS'', N''LOP_DELETE_ROWS'')
ORDER BY t.SequenceNumber, e.[Current LSN];

-- Result 10: TRUNCATE is logged and can be rolled back before commit, but
-- it does not log individual user-row deletions. It logs deallocation work.
-- Do not expect an identical list of operation names on every build.
-- Metadata row changes and related system transactions can also appear.
-- Deferred deallocation can move some work beyond the root transaction. [S4]
SELECT N''10: TRUNCATE root transaction, including allocation/metadata work'' AS ResultSet;
SELECT e.[Current LSN], e.[Operation], e.[Context], e.[AllocUnitId],
       e.[AllocUnitName], e.[Page ID], e.[Description]
FROM dbo.LogEvidence AS e
JOIN dbo.ScenarioTransactions AS t ON t.TransactionId = e.[Transaction ID]
WHERE t.TransactionName = N''Lab_Truncate''
ORDER BY e.[Current LSN];

-- Result 11: the abort boundary and surviving row establish the lesson.
-- Finding a logged DELETE is NOT the same as finding a committed data loss.
SELECT N''11: Rolled-back DELETE and the surviving customer'' AS ResultSet;
SELECT e.[Current LSN], e.[Operation], e.[Context], e.[Description]
FROM dbo.LogEvidence AS e
JOIN dbo.ScenarioTransactions AS t ON t.TransactionId = e.[Transaction ID]
WHERE t.TransactionName = N''Lab_Rollback''
ORDER BY e.[Current LSN];
SELECT * FROM dbo.Customers WHERE CustomerId = 5;

-- Result 12: summarize without claiming a log-record count equals row count.
SELECT N''12: Forensic summary (root-transaction record counts)'' AS ResultSet;
SELECT t.SequenceNumber, t.TransactionName, t.IntendedAction,
       t.ExpectedOutcome, t.BeginLSN, COUNT_BIG(*) AS RootTransactionLogRecords,
       SUM(CASE WHEN e.[Operation] = N''LOP_DELETE_ROWS'' THEN 1 ELSE 0 END)
           AS DeleteLogRecordsIncludingMetadata
FROM dbo.ScenarioTransactions AS t
JOIN dbo.LogEvidence AS e ON e.[Transaction ID] = t.TransactionId
GROUP BY t.SequenceNumber, t.TransactionName, t.IntendedAction,
         t.ExpectedOutcome, t.BeginLSN
ORDER BY t.SequenceNumber;

SELECT N''13: Final rows, verified against the known teaching scenario'' AS ResultSet;
SELECT * FROM dbo.Customers ORDER BY CustomerId;
SELECT * FROM dbo.WorkQueue ORDER BY WorkId;
SELECT N''PASS: data-state and transaction-boundary checks completed.'' AS LabStatus;

-- No restore is attempted. The baseline full backup does NOT include the
-- later incident transactions. An actual STOPBEFOREMARK exercise would need
-- appropriate log backups, a complete restore chain, and a SEPARATE target.
-- Identifying a beginning LSN is investigation, not recovery. [S1]
';

    DROP TABLE #SQLPalLabContext;
    SELECT N'Lab complete. Evidence remains in SQLPal_LogForensicsLab.dbo.LogEvidence.'
           AS NextStep, @BackupFile AS BaselineBackupFile;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    IF OBJECT_ID(N'tempdb..#SQLPalLabContext') IS NOT NULL
        DROP TABLE #SQLPalLabContext;

    SELECT ERROR_NUMBER() AS ErrorNumber, ERROR_MESSAGE() AS ErrorMessage,
           @CreatedDatabase AS DatabaseCreatedByThisRun,
           @BackupFile AS IntendedBaselineBackupFile,
           N'Partial lab objects are deliberately retained. Inspect before cleanup; do not blindly rerun.'
           AS NextStep;
    THROW;
END CATCH;

/*
FOLLOW-UP QUERIES: run selected text below after the lab succeeds.
They query the SAVED snapshot, not the live log.

USE [SQLPal_LogForensicsLab];

-- Pick Transaction ID from results of this query and paste it in next query to solve the exercise yourself.
SELECT e.[Current LSN], e.[Transaction ID], e.[Operation], e.[Context],
       m.SchemaName, m.TableName, e.[AllocUnitId], e.[Page ID], e.[Slot ID]
FROM dbo.LogEvidence AS e
JOIN dbo.AllocationMapBefore AS m
  ON TRY_CONVERT(bigint, e.[AllocUnitId]) = m.AllocationUnitId
WHERE m.TableName = N'Customers'
  AND e.[Operation] = N'LOP_DELETE_ROWS'
ORDER BY e.[Current LSN];

-- paste a Transaction ID as a value for this variable
DECLARE @InvestigateTransactionId nvarchar(64) = N''; -- e.g. 0000:000003a1
SELECT [Current LSN], [Operation], [Context], [Transaction ID],
       [Transaction Name], [Begin Time], [End Time], [AllocUnitName],
       [Transaction SID], [Description]
FROM dbo.LogEvidence
WHERE [Transaction ID] = @InvestigateTransactionId
ORDER BY [Current LSN];

-- Reopen the reproducibility manifest and known before/after rows.
SELECT * FROM dbo.LabRun;
SELECT * FROM dbo.CustomersBefore ORDER BY CustomerId;
SELECT * FROM dbo.Customers ORDER BY CustomerId;

CHALLENGE
  1. Ignore ScenarioGuide and ScenarioTransactions.
  2. Find candidate customer deletes using AllocationMapBefore.
  3. Follow each candidate ID back to its begin record and forward to its end.
  4. Separate the committed delete from the rolled-back delete.
  5. Explain why login SID does not prove which human issued the operation.
  6. Explain why WorkQueueBefore is an answer key, not reconstructed log data.

Do not leave this FULL-recovery lab running indefinitely without log backups.
Export any wanted results, then use the commented cleanup block below or its
standalone copy. Do not enable cleanup until you are finished investigating.
*/

/* CLEANUP
Copy the SQL below (starting at DECLARE) into a fresh query window on the
SAME disposable instance. Set the exact confirmation string, then run it.
It switches to master, checks the lab marker, and drops the lab database.

WARNING: SINGLE_USER WITH ROLLBACK IMMEDIATE force-disconnects other lab
sessions and rolls back their incomplete transactions. Export evidence first.
The baseline .bak file is NOT deleted.

DECLARE @ConfirmDrop nvarchar(128) = N''; -- Set to N'DROP SQLPal_LogForensicsLab'
DECLARE @LabIdentity nvarchar(4000);

IF @ConfirmDrop <> N'DROP SQLPal_LogForensicsLab'
    THROW 51200, 'Cleanup is disabled. Read the header and set the exact confirmation string.', 1;
IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'), 0) <> 1
    THROW 51201, 'Use the authorized sysadmin account for this disposable lab.', 1;
IF @@TRANCOUNT <> 0 OR (@@OPTIONS & 2) = 2
    THROW 51202, 'Use a fresh connection without explicit or implicit transactions.', 1;

USE [master];

IF DB_ID(N'SQLPal_LogForensicsLab') IS NULL
    THROW 51204, 'The lab database does not exist. Nothing was dropped.', 1;

EXEC sys.sp_executesql
    N'SELECT @Identity = CONVERT(nvarchar(4000), value)
      FROM [SQLPal_LogForensicsLab].sys.extended_properties
      WHERE class = 0 AND name = N''SQLPalLabIdentity'';',
    N'@Identity nvarchar(4000) OUTPUT',
    @Identity = @LabIdentity OUTPUT;

IF ISNULL(@LabIdentity, N'') <> N'SQLPal.LogForensics.DisposableLab.v1'
    THROW 51205, 'Lab marker missing or different. Refusing automatic deletion; investigate manually.', 1;

-- A partially completed lab might not yet have a LabRun table.
EXEC sys.sp_executesql N'
IF OBJECT_ID(N''SQLPal_LogForensicsLab.dbo.LabRun'', N''U'') IS NOT NULL
    SELECT BackupFile AS BackupFileToRemoveManuallyAfterReview
    FROM SQLPal_LogForensicsLab.dbo.LabRun;';

-- Keep these in one batch to minimize the gap between SINGLE_USER and DROP.
-- Disable async statistics so its background connection does not contend
-- for the single-user slot:

EXEC (N'
ALTER DATABASE [SQLPal_LogForensicsLab] SET AUTO_UPDATE_STATISTICS_ASYNC OFF;
ALTER DATABASE [SQLPal_LogForensicsLab] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE [SQLPal_LogForensicsLab];');

SELECT N'Lab database dropped. Review and remove its baseline backup manually if no longer needed.'
       AS CleanupResult;
*/
