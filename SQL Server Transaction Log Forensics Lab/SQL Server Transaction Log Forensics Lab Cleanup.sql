/*
SQL Server Transaction Log Forensics: Optional Lab Cleanup

DESTRUCTIVE, OPT-IN: deletes SQLPal_LogForensicsLab and its database files.
It does NOT delete the baseline .bak file. Record the backup path first.
Use only on the disposable instance where you ran the companion lab.
WARNING: SINGLE_USER WITH ROLLBACK IMMEDIATE force-disconnects other lab
sessions and rolls back their incomplete transactions. Export evidence first.
The marker is an accident guard, not an authentication/security boundary.

Run the WHOLE script in a fresh query window on the same disposable instance.
It switches to master after the confirmation and transaction checks.
*/
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
