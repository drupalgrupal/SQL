-- See blog post: https://sqlpal.blogspot.com/2023/07/generate-sql-script-to-allow-or.html

USE AdminDBA;  -- Change to your target database
GO

-- =============================================
-- Generate Login DISABLE/ENABLE Scripts
-- =============================================
-- Purpose: Creates ALTER LOGIN DISABLE/ENABLE statements
--          for ALL database users mapped to SQL Server logins
-- Usage:   Run in target database. Copy DISABLE scripts to block all logins.
-- Note:    Excludes Windows groups, roles, certificates - SQL logins only
-- =============================================

SELECT 
    sp.name AS [Login_Name],
    dp.name AS [DB_User],
    -- DISABLE script (blocks login server-wide)
    'ALTER LOGIN ' + QUOTENAME(sp.name) + ' DISABLE;' AS [Disable_Login],
    
    -- ENABLE script (restores login access)
    'ALTER LOGIN ' + QUOTENAME(sp.name) + ' ENABLE;' AS [Enable_Login]

FROM sys.database_principals dp
    INNER JOIN sys.server_principals sp
        ON dp.sid = sp.sid
WHERE dp.name NOT IN ('public','dbo','guest','INFORMATION_SCHEMA','sys')
  AND dp.name NOT IN ('AppUser1', 'AppUser2')     -- FIXED: was duplicate AppUser1
  AND sp.type = 'S'                               -- SQL Server logins only
  AND sp.is_disabled = 0                          -- Currently enabled logins only
ORDER BY dp.name;

