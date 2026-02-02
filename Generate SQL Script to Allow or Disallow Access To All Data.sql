-- See blog post: Generate SQL Script to Allow or Disallow Access To All Data
SET NOCOUNT ON;
-- USE [Your Database Name];

-- =============================================
-- Generate GRANT/DENY Schema Permission Scripts
-- =============================================
-- Purpose: Creates ready-to-execute GRANT/DENY statements for schema permissions
--          on ALL valid database users (excluding system accounts)
-- Usage:   Change @SchemaName and @Permission below, then execute
-- Output:  Columns with GRANT and DENY scripts for each user
-- Blog:    Generate SQL Script to Allow or Disallow Access To All Data
-- =============================================


-- CONFIGURATION - CHANGE THESE VALUES
DECLARE @SchemaName     SYSNAME = 'dbo';        -- Target schema (must exist)
DECLARE @Permission     VARCHAR(100) = 'EXECUTE'; -- Permission to grant/deny
-- Valid: ALTER, DELETE, EXECUTE, INSERT, SELECT, UPDATE, etc.


-- Valid schema-level permissions (per MS Docs)
DECLARE @ValidPermissions TABLE (PermissionName SYSNAME PRIMARY KEY);
INSERT @ValidPermissions (PermissionName) VALUES
    ('ALTER'), ('CONTROL'), ('CREATE SEQUENCE'), ('DELETE'), ('EXECUTE'),
    ('INSERT'), ('REFERENCES'), ('SELECT'), ('TAKE OWNERSHIP'), 
    ('UPDATE'), ('VIEW CHANGE TRACKING'), ('VIEW DEFINITION');

-- =============================================
-- VALIDATION
-- =============================================
-- Check if schema exists
IF SCHEMA_ID(@SchemaName) IS NULL
BEGIN
    RAISERROR('ERROR: Schema ''%s'' does not exist.', 16, 1, @SchemaName);
    RETURN;
END

-- Check if permission is valid
IF NOT EXISTS (SELECT 1 FROM @ValidPermissions WHERE PermissionName = @Permission)
BEGIN
    RAISERROR('ERROR: ''%s'' is not a valid schema permission.', 16, 1, @Permission);
    PRINT 'Valid schema permissions:';
    SELECT PermissionName + ',' FROM @ValidPermissions ORDER BY PermissionName
    FOR XML PATH('');
    RETURN;
END

-- =============================================
-- GENERATE GRANT/DENY SCRIPTS
-- =============================================
SELECT 
    dp.name AS [UserName],
    @SchemaName AS [SchemaName],
    -- GRANT script (fully qualified, ready to execute)
    'USE ' + QUOTENAME(DB_NAME()) + ';' + CHAR(13) + CHAR(10) + 
    'GRANT ' + @Permission + ' ON SCHEMA::' + QUOTENAME(@SchemaName) + 
    ' TO ' + QUOTENAME(dp.name) + ';' AS [GrantScript],
    
    -- DENY script (fully qualified, ready to execute)
    'USE ' + QUOTENAME(DB_NAME()) + ';' + CHAR(13) + CHAR(10) + 
    'DENY ' + @Permission + ' ON SCHEMA::' + QUOTENAME(@SchemaName) + 
    ' TO ' + QUOTENAME(dp.name) + ';' AS [DenyScript]

FROM sys.database_principals dp
WHERE dp.name NOT IN ('public', 'dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
  AND dp.name NOT LIKE '#%'
  AND dp.name NOT IN ('AppUser1', 'AppUser2')  -- Customize exclusions
  AND dp.is_fixed_role = 0                    -- Exclude fixed roles
  AND dp.type IN ('S', 'U', 'G')              -- SQL Users, Windows Users, Windows Groups only
ORDER BY dp.name;

