-- See blog post: https://sqlpal.blogspot.com/2024/01/How%20to%20Find%20Where%20Your%20Databases%20Reside%20In%20The%20File%20System.html
--
/*****************************************************************************************
 Script: Get SQL Server Database File Folder Locations
 Purpose: Returns DISTINCT list of all folders containing SQL Server database files 
          (data + log + FILESTREAM) across all databases on the instance.

 Features:
  * Works on SQL Server 2000-2025
  * Generates TWO create-directory methods:
     - xp_create_subdir: T-SQL for Windows/SQL Agent jobs (xp_cmdshell required)
     - mkdir -p: Linux shell commands for backup/migration targets
  * Falls back to legacy method if VIEW SERVER STATE denied or old version

 Usage: Run as sysadmin or user with VIEW SERVER STATE permission
******************************************************************************************/

SET NOCOUNT ON;

DECLARE @PRODUCTVERSION NVARCHAR(132)
DECLARE @PERMISSION_FLAG bit = 1  -- Set to 0 to force legacy path (testing)

-- Get major version number (e.g. '15' for SQL 2019, '16' for 2022)
SET @PRODUCTVERSION = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(32)) 

-- Extract major version: everything before first decimal point
DECLARE @MAJOR_VERSION INT = CAST(SUBSTRING(@PRODUCTVERSION, 1, CHARINDEX('.', @PRODUCTVERSION)-1) AS INT);

-- LEGACY PATH: SQL Server 2000-2008R2 OR no VIEW SERVER STATE permission
IF @MAJOR_VERSION < 10 OR @PERMISSION_FLAG = 0
BEGIN
    PRINT 'Using legacy method (SQL 2000-2008R2 compatibility or VIEW SERVER STATE denied)...';
    
    -- Clean up any existing temp table
    IF OBJECT_ID('tempdb..#t1') IS NOT NULL 
        DROP TABLE #t1;
    
    -- Temp table to hold folder paths and filenames from sysfiles
    CREATE TABLE #t1 (
        fpath   VARCHAR(4000),  -- Folder path only
        fname   VARCHAR(8000)   -- Full filename for reference
    );
    
    -- sp_MSforeachdb visits every DB on instance (undocumented but reliable)
    INSERT INTO #t1 (fpath, fname)
    EXEC sp_MSforeachdb '
        SELECT 
            LEFT(filename, LEN(filename) - CHARINDEX(''\\'', REVERSE(RTRIM(filename)))) AS fpath,
            filename AS fname 
        FROM [?].dbo.sysfiles
    ';
    
    SELECT DISTINCT fpath AS folder_path
    FROM #t1 
    ORDER BY fpath;
    
    DROP TABLE #t1;
END

-- MODERN PATH: SQL Server 2012+ with sys.master_files (recommended)
ELSE 
BEGIN
    PRINT 'Using modern sys.master_files method (SQL 2012+)...';
    
    WITH cte AS (
        SELECT 
            CASE 
                -- FILESTREAM files (type=2) use full physical_name as "folder"
                WHEN type = 2 THEN physical_name     
                -- Regular files: strip filename to get folder path
                ELSE LEFT(physical_name, 
                         LEN(physical_name) - CHARINDEX('\', REVERSE(RTRIM(physical_name)))) 
            END AS folder_path, 
            physical_name  
        FROM sys.master_files
        WHERE type IN (0,1,2)  -- ROWS, LOG, FILESTREAM only
    )
    SELECT DISTINCT 
        folder_path,
        'EXEC master.dbo.xp_create_subdir N''' + folder_path + '''' AS xp_create_subdir,
        'mkdir -p "' + folder_path + '"' AS create_folder
    FROM cte
    ORDER BY folder_path;
END

