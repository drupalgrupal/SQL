/*
=====================================================================
WARNING - READ BEFORE RUNNING
=====================================================================
This script DISABLES and/or RENAMES the sa login (SID 0x01).

Before running, make sure that at least one OTHER login or Windows
group with sysadmin access to this SQL Server instance:
    - exists and is enabled,
    - has been tested by actually logging in with it, and
    - will still work after this change.

If sa is the only working sysadmin account, running this script can
LOCK YOU OUT of the instance. Getting back in would mean restarting
SQL Server in single-user mode.
=====================================================================

- Rename and disable the sa login (SID 0x01), regardless of authentication mode.
- Run on every instance / AG replica separately (logins are server-scoped).

- Renaming is obscurity, not protection. SID 0x01 is easy to find, 
  so disabling it is the real control. 

- Also consider setting a long random password for sa.

- Some things refer to sa by name. Jobs and databases owned by sa 
  keep working, because ownership is tracked by SID. 

- Vendor scripts or tools that hard-code 'sa' will break. 
  Check application installers before rolling this out widely

- It runs per server. Logins aren't synced across Always On 
  replicas, so run it on each node

- The lockout check has limits. It can't confirm that a Windows 
  group in sysadmin actually has members you can use. 

- Make sure a named DBA login or group still works before you 
  disable sa in production.

*/

SET NOCOUNT ON;

DECLARE @rename_sa   bit     = 0;   -- Set to 1 to rename sa
DECLARE @disable_sa  bit     = 0;   -- Set to 1 to disable sa
DECLARE @new_sa_name sysname = N'morganiia';

DECLARE @current_sa_name sysname;
DECLARE @sa_disabled     int;
DECLARE @sql             nvarchar(max);

SET @new_sa_name = LTRIM(RTRIM(@new_sa_name));

-- Permission check
IF HAS_PERMS_BY_NAME(NULL, NULL, N'CONTROL SERVER') <> 1
    THROW 51001, N'CONTROL SERVER permission is required to alter the sa login.', 1;

-- Locate sa by SID
SELECT @current_sa_name = name,
       @sa_disabled     = CONVERT(int, is_disabled)
FROM sys.server_principals
WHERE sid = 0x01;

IF @current_sa_name IS NULL
    THROW 51002, N'Login with SID 0x01 was not found or is not visible.', 1;

RAISERROR(N'sa current name: %s', 10, 1, @current_sa_name) WITH NOWAIT;
RAISERROR(N'sa is disabled: %d', 10, 1, @sa_disabled) WITH NOWAIT;

-- Do not run as sa
IF SUSER_SID() = 0x01
    THROW 51003, N'Run this script as a different sysadmin login, not as sa.', 1;

-- Lockout protection: another enabled sysadmin must exist (service SIDs excluded)
IF @disable_sa = 1 AND NOT EXISTS (
    SELECT 1
    FROM sys.server_role_members rm
    JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
    JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'sysadmin'
      AND m.sid <> 0x01
      AND m.is_disabled = 0
      AND m.name NOT LIKE N'NT SERVICE\%')
    THROW 51004, N'No other enabled sysadmin login found; disabling sa could lock you out.', 1;

-- Rename validation (only when renaming)
IF @rename_sa = 1
BEGIN
    IF ISNULL(LEN(@new_sa_name), 0) < 8
        THROW 51000, N'New sa name cannot be NULL/empty and must be at least 8 characters long.', 1;

    IF EXISTS (SELECT 1 FROM sys.server_principals
               WHERE name = @new_sa_name AND sid <> 0x01)
        THROW 51005, N'A server principal with the new name already exists.', 1;
END;

-- Disable
IF @disable_sa = 1 AND @sa_disabled = 0
BEGIN
    RAISERROR(N'Disabling sa login...', 10, 1) WITH NOWAIT;
    SET @sql = N'ALTER LOGIN ' + QUOTENAME(@current_sa_name) + N' DISABLE;';
    EXEC sys.sp_executesql @sql;
END
ELSE IF @disable_sa = 1
    RAISERROR(N'sa login is already disabled.', 10, 1) WITH NOWAIT;

-- Rename
IF @rename_sa = 1 AND @current_sa_name <> @new_sa_name
BEGIN
    RAISERROR(N'Renaming sa login to %s...', 10, 1, @new_sa_name) WITH NOWAIT;
    SET @sql = N'ALTER LOGIN ' + QUOTENAME(@current_sa_name)
             + N' WITH NAME = ' + QUOTENAME(@new_sa_name) + N';';
    EXEC sys.sp_executesql @sql;
END
ELSE IF @rename_sa = 1
    RAISERROR(N'sa login already has the requested name.', 10, 1) WITH NOWAIT;

-- Verify
SELECT name, is_disabled, modify_date
FROM sys.server_principals
WHERE sid = 0x01;
