-- =================================================================
-- SQL Server Instant File Initialization (IFI) Test Script
-- =================================================================
-- Purpose: Demonstrates the performance benefit of Instant File Initialization
--          for data file growth by timing expansion of a test database's data
--          and log files. IFI speeds up data file allocation (no zeroing required),
--          but log files are always zero-initialized (except small autogrowths <=64MB in SQL 2022+).
--
-- Prerequisites:
-- - Minimum permissions required: 
--   VIEW SERVER STATE + dbcreator server role (Unless you are already a sysadmin)
--
-- - Data and Log file paths must exist and be writable
--   by SQL Server service account.
-- - Instant File Initialization must be enabled (via Local Security Policy: 
--   grant SQL Server service account "Perform volume maintenance tasks").  
-- - Test uses 8MB initial size, grows to 4GB (4096MB).
--
-- Expected Results:
-- - Data file growth: Near-instantaneous (<1 second) with IFI enabled.
-- - Log file growth: Noticeably slower (zero-initialization time depends on disk speed).
--
-- Test Results:
-- - Azure VM (Premium SSD v2 P30, 5K IOPS): 204 MB/s uncached sequential writes, avg latency 2.567 ms
--   - 4GB log expansion: 20 seconds
-- - Hyper-V VM (Ultra SSD, 10K IOPS): 714 MB/s uncached sequential writes, avg latency 0.715 ms  
--   - 4GB log expansion: 5 seconds
--
-- Notes:
-- - IFI does NOT apply to log files in this test (expansion >64MB).
-- - Database name includes GUID-like suffix for uniqueness.
-- - Script is safely re-runnable: drops existing test DB if present.
-- - Cleans up test database at end.
-- - Uses RAISERROR with NOWAIT for real-time progress output.
--
-- Author: 
-- Version: 2.2 (Single-batch version with fixes)
-- Compatible: SQL Server 2016+ (recommended 2022 for paths/versions)
-- =================================================================

SET NOCOUNT ON;
USE master;

-- Check if Instant File Initialization is enabled
RAISERROR('INFO: Checking if Instant File Initialization (IFI) is enabled...', 0, 1) WITH NOWAIT;
IF NOT EXISTS (
    SELECT 1 
    FROM sys.dm_server_services 
    WHERE servicename LIKE 'SQL Server (%'
      AND instant_file_initialization_enabled = 'Y'
)
BEGIN
    THROW 50001, 'ERROR: Instant File Initialization is not enabled. Grant ''Perform volume maintenance tasks'' to the SQL Server service account via secpol.msc, then restart SQL Server.', 1;
END;

RAISERROR('INFO: Instant File Initialization is enabled.', 0, 1) WITH NOWAIT;

-- Drop test database if it exists
RAISERROR('INFO: Checking/dropping existing test database if present...', 0, 1) WITH NOWAIT;
IF DB_ID('IFIDemoDB-5EEDFB08') IS NOT NULL
BEGIN
    ALTER DATABASE [IFIDemoDB-5EEDFB08] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [IFIDemoDB-5EEDFB08];
END;

-- Create test database with small initial files (8MB = 8192KB)
RAISERROR('INFO: Creating test database...', 0, 1) WITH NOWAIT;
CREATE DATABASE [IFIDemoDB-5EEDFB08]
 ON PRIMARY 
 ( NAME = N'IFIDemoDB-5EEDFB08', 
   FILENAME = N'K:\SQLDATA\IFIDemoDB-5EEDFB08.mdf', 
   SIZE = 8192KB, 
   FILEGROWTH = 65536KB 
 )
 LOG ON 
 ( NAME = N'IFIDemoDB-5EEDFB08_log', 
   FILENAME = N'L:\SQLLOG\IFIDemoDB-5EEDFB08_log.ldf', 
   SIZE = 8192KB, 
   FILEGROWTH = 65536KB 
 );

-- Variables for timing
DECLARE @StartTime DATETIME2(3);
DECLARE @DataFileDuration INT;
DECLARE @LogFileDuration INT;

-- Expand data file to 4096MB and time it (should be fast with IFI)
RAISERROR('INFO: Expanding data file from 8MB to 4096MB (IFI applies)...', 0, 1) WITH NOWAIT;
SET @StartTime = SYSDATETIME();
ALTER DATABASE [IFIDemoDB-5EEDFB08] 
MODIFY FILE (NAME = N'IFIDemoDB-5EEDFB08', SIZE = 4096MB);
SET @DataFileDuration = DATEDIFF(SECOND, @StartTime, SYSDATETIME());

-- Expand log file to 4096MB and time it (zero-initialized, no IFI)
RAISERROR('INFO: Expanding log file from 8MB to 4096MB (zero-initialized, no IFI)...', 0, 1) WITH NOWAIT;
SET @StartTime = SYSDATETIME();
ALTER DATABASE [IFIDemoDB-5EEDFB08] 
MODIFY FILE (NAME = N'IFIDemoDB-5EEDFB08_log', SIZE = 4096MB);
SET @LogFileDuration = DATEDIFF(SECOND, @StartTime, SYSDATETIME());

-- Display results
RAISERROR('', 0, 1) WITH NOWAIT;

RAISERROR('RESULTS (durations in seconds):', 10, 1) WITH NOWAIT;
SELECT 
    @DataFileDuration AS [Data File Growth (IFI Enabled)],
    @LogFileDuration AS [Log File Growth (Zero-Initialized)]
    -- Expected: Data ~0-1s, Log >10s depending on disk
;

-- Cleanup
RAISERROR('INFO: Cleaning up test database...', 0, 1) WITH NOWAIT;
IF DB_ID('IFIDemoDB-5EEDFB08') IS NOT NULL
BEGIN
    ALTER DATABASE [IFIDemoDB-5EEDFB08] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [IFIDemoDB-5EEDFB08];
END;

RAISERROR('INFO: Test complete. Check results above.', 0, 1) WITH NOWAIT;

