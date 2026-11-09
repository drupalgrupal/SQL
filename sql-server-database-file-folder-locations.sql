-- https://sqlpal.blogspot.com/2024/01/How%20to%20Find%20Where%20Your%20Databases%20Reside%20In%20The%20File%20System.html

/*****************************************************************************************
 Script  : Get SQL Server Database File Folder Locations
 
Purpose : 
 Returns a DISTINCT list of folders that must exist before database files
 can be created or restored on an instance with the same layout (for example,
 when building a DR server, a migration target, or a restore destination).

 Supports: SQL Server 2005 and later on Windows; SQL Server 2017 and 
           later on Linux. SQL Server 2000 is NOT supported.

 -----------------------------------------------------------------------------------------
 FEATURES
 -----------------------------------------------------------------------------------------
  * Reads every database's files from sys.master_files in a single query, 
    so offline, restoring, and otherwise inaccessible databases are included.
  * Covers data (ROWS), transaction log (LOG), and FILESTREAM / 
    memory-optimized container files (type 2).
  * Handles both Windows (backslash) and Linux (forward slash) paths.
  * Returns the PARENT folder of FILESTREAM / memory-optimized containers, 
    because SQL Server requires the container folder itself to NOT exist 
    when it is created.
  * Flags folders that hold a container (has_container_parent = 1) so 
    you don't pre-create the container under them by mistake.
  * Generates ready-to-run commands for each folder:
      - check_if_folder_exists : T-SQL  - EXEC master.dbo.xp_fileexist
      - xp_create_subdir       : T-SQL  - EXEC master.dbo.xp_create_subdir
                                 (PREFERRED method - see PREFERRED METHOD below)
      - os_create_folder       : OS shell command, depending on the path type:
                                   * Windows paths -> Windows PowerShell command
                                     (New-Item -ItemType Directory -Force).
                                     Run it in a PowerShell window, NOT cmd.exe.
                                   * Linux paths   -> bash command (mkdir -p).
                                 Provided as an ALTERNATIVE only.
  * Escapes single quotes in folder names so the generated commands stay valid.
  * Prints a warning when the caller lacks the permissions sys.master_files 
    needs to return a complete result.

 -----------------------------------------------------------------------------------------
 PREFERRED METHOD: xp_create_subdir
 -----------------------------------------------------------------------------------------
  The script provides os_create_folder, but xp_create_subdir is the PREFERRED 
  way to create the folders. Use os_create_folder only when xp_create_subdir 
  is not an option (for example, you are not sysadmin, or the SQL Server 
  instance is not installed yet).

  Why xp_create_subdir is preferred:
   * It creates the folder AS THE SQL SERVER SERVICE ACCOUNT, the same account that
     will later create, restore, and open the database files. If the command succeeds,
     you know that account can create folders at that location.
   * The service account becomes the folder's owner, so the folder will not end up
     owned by your personal or admin account. On Linux this matters most: a folder
     created with "sudo mkdir -p" is owned by root, and SQL Server (running as the
     mssql user) cannot write to it until someone runs chown/chmod.
   * os_create_folder runs as whoever opens the shell. A folder created that way may
     exist but still be inaccessible to SQL Server, and the failure only appears later
     when CREATE DATABASE or RESTORE fails with an "access denied" or OS error.
   * It runs from the same SQL session (SSMS, sqlcmd, or a SQL Agent job) as the
     restore or create, with no RDP or SSH logon to the server.
   * The same T-SQL command works on Windows and Linux instances.
   * Like mkdir -p, it creates any missing intermediate folders.

  Caveats:
   * xp_create_subdir is undocumented and requires sysadmin.
   * The service account still needs rights on the PARENT path. If it lacks them,
     xp_create_subdir fails. Treat that failure as a useful early warning, not
     something to work around with os_create_folder.

 -----------------------------------------------------------------------------------------
 HOW IT WORKS
 -----------------------------------------------------------------------------------------
  1. Permission check:
     HAS_PERMS_BY_NAME tests for VIEW ANY DEFINITION, ALTER ANY DATABASE, and
     CREATE ANY DATABASE. sys.master_files does not raise an error when these are
     missing; it silently returns fewer rows. The script only warns; it does not stop.

  2. Path separator detection (CTE f):
     A path starting with '/' is treated as Linux; everything else as Windows ('\').

  3. Trailing separator cleanup (CTE f2):
     Removes a trailing '\' or '/' so the next step strips the correct segment.

  4. Folder extraction (CTE d):
     REVERSE + CHARINDEX finds the last separator, and LEFT keeps everything before it.
       - Data/log file : D:\Data\Sales.mdf   ->  D:\Data
       - Container     : D:\FS\SalesFS       ->  D:\FS   (the container's parent)

  5. Deduplication and filtering (CTE g):
     GROUP BY returns each folder once. Drive roots (D:) and empty results (root-level
     Linux files) are excluded because they don't need to be created.

  6. Command generation (final SELECT):
     Builds the check and create commands, escaping single quotes for T-SQL ('')
     and for bash ('\'').
     For Windows paths, os_create_folder contains a Windows PowerShell command,
     not a cmd.exe command. In PowerShell, single quotes are escaped by doubling ('').

 -----------------------------------------------------------------------------------------
 REQUIREMENTS
 -----------------------------------------------------------------------------------------
  * Running the query      : VIEW ANY DEFINITION, ALTER ANY DATABASE, or
                             CREATE ANY DATABASE (sysadmin has all three).
  * Generated xp_ commands : sysadmin.
  * Generated OS commands  : An OS account with rights to create folders on the target.
                             Windows paths: run os_create_folder in Windows PowerShell
                             (or PowerShell 7) on the target server.
                             Linux paths  : run os_create_folder in a bash shell.
                             Afterward, confirm the SQL Server service account has
                             full rights on the new folders.

 -----------------------------------------------------------------------------------------
 LIMITATIONS
 -----------------------------------------------------------------------------------------
  * xp_fileexist and xp_create_subdir are undocumented and unsupported by Microsoft.
    They can change or be removed in a future release.
  * The xp_ commands run as the SQL Server service account, NOT as your login.
    That account needs NTFS/Linux permissions on the parent path.
  * Folders created with os_create_folder are owned by the account that ran the
    command, not the SQL Server service account. Permissions may need to be fixed
    before SQL Server can use them.
  * The script only GENERATES commands; it does not run them. Review the output
    before running it on the target server.
  * The output reflects THIS instance's file layout. Run it on the source, then
    execute the generated commands on the target.
  * The Windows os_create_folder command is Windows PowerShell syntax and will not
    work in cmd.exe.
  * Full-text catalog entries (type 4, SQL 2005-2008 R2) are excluded.
  * UNC paths (\\server\share\...), mount points, and symbolic links have not been
    specifically handled; results may need manual review.
  * On a case-sensitive server collation, folders that differ only by case
    (D:\Data vs D:\DATA) appear as separate rows, even though Windows treats them
    as the same folder.
  * Folder names ending in spaces may be trimmed, because LEN ignores trailing spaces.
  * Azure SQL Database and Azure SQL Managed Instance are out of scope; their file
    paths are managed by the platform.
  * The permission check warns but does not fall back to another method.

 -----------------------------------------------------------------------------------------
 TESTING STATUS -- PLEASE READ
 -----------------------------------------------------------------------------------------
  This script has gone through VERY LIMITED testing. It has NOT been tested in some 
  edge cases or rare configurations, including but not limited to:
    - Folder names containing apostrophes, Unicode, or trailing spaces
    - UNC paths, mount points, or symbolic links

  Validate the output in a non-production environment before relying on it.
  Use at your own risk.
******************************************************************************************/
SET NOCOUNT ON;

IF  ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW ANY DEFINITION'), 0) = 0
AND ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER ANY DATABASE'), 0) = 0
AND ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'CREATE ANY DATABASE'), 0) = 0
    PRINT 'WARNING: Missing VIEW ANY DEFINITION / ALTER ANY DATABASE / CREATE ANY DATABASE. '
        + 'sys.master_files may return incomplete results.';

;WITH f AS (
    SELECT
        mf.type,
        sep = CASE WHEN mf.physical_name LIKE N'/%' THEN N'/' ELSE N'\' END,
        p   = mf.physical_name
    FROM sys.master_files AS mf
    WHERE mf.type IN (0, 1, 2)          -- ROWS, LOG, FILESTREAM/memory-optimized
),
f2 AS (                                  -- strip any trailing separator
    SELECT type, sep,
           p = CASE WHEN RIGHT(p, 1) = sep THEN LEFT(p, LEN(p) - 1) ELSE p END
    FROM f
),
d AS (                                   -- parent folder (for type 2 = container's parent)
    SELECT type, sep,
           folder_path = LEFT(p, LEN(p) - CHARINDEX(sep, REVERSE(p)))
    FROM f2
    WHERE CHARINDEX(sep, p) > 0
),
g AS (
    SELECT folder_path, sep,
           has_container_parent = MAX(CASE WHEN type = 2 THEN 1 ELSE 0 END)
    FROM d
    WHERE folder_path <> N''
      AND folder_path NOT LIKE N'_:'     -- skip drive roots
    GROUP BY folder_path, sep
)
SELECT
    folder_path,
    has_container_parent,                -- 1 = do NOT pre-create the container under it
    check_if_folder_exists =             -- T-SQL
        N'EXEC master.dbo.xp_fileexist N''' + REPLACE(folder_path, N'''', N'''''') + N''';',
    xp_create_subdir =                   -- T-SQL - PREFERRED (runs as SQL Server service account)
        N'EXEC master.dbo.xp_create_subdir N''' + REPLACE(folder_path, N'''', N'''''') + N''';',
    os_create_folder =                   -- ALTERNATIVE only (runs as the shell user)
        CASE WHEN sep = N'/'
             -- Linux path: bash command
             THEN N'mkdir -p ''' + REPLACE(folder_path, N'''', N'''\''''') + N''''
             -- Windows path: Windows PowerShell command (do NOT run in cmd.exe)
             ELSE N'New-Item -ItemType Directory -Force -Path '''
                  + REPLACE(folder_path, N'''', N'''''') + N''' | Out-Null'
        END
FROM g
ORDER BY folder_path;

