-- See blog post: https://sqlpal.blogspot.com/2019/06/what-about-orphaned-windows-users.html
/*==========================================================================================
  Script Name : Find-Fix-Orphaned-Windows-Users.sql

  Purpose:
      Identifies and optionally recreates orphaned Windows users in the current database.
      Unlike sp_change_users_login (SQL logins only), this handles Windows users/groups
      using xp_logininfo to validate Windows account existence.

  How it works:
      1. Finds database users (WINDOWS_USER type) with no matching server login SID
      2. Uses xp_logininfo @option='all' to verify if Windows account still exists
      3. Reports orphaned users OR auto-creates missing server logins

  Configuration:
      @fix_orphaned_user (BIT) 
          0 = Report-only mode (default, safe)
          1 = Auto-fix by creating missing server logins

  Prerequisites:
      - Run in target database (orphaned users are DB-scoped)
      - sysadmin or equivalent to create logins (when fixing)
      - Windows Authentication environment

  Safety Notes:
      - xp_logininfo queries Active Directory/local SAM - network dependent
      - Only creates logins, doesn't modify existing database users/permissions
      - Test in non-prod first when @fix_orphaned_user=1
      - Won't fix OS-level account issues (disabled/locked/deleted accounts)

  Typical Scenarios:
      - Database restore to new server (login SIDs don't match)
      - AD cleanup removed accounts referenced by databases
      - Failover cluster with domain trust issues
==========================================================================================*/

DECLARE @username NVARCHAR(500),
        @privilege NVARCHAR(500), 
        @sql NVARCHAR(4000),
        @fix_orphaned_user BIT,
        @cnt INT = 0;

SET @fix_orphaned_user = 0;  -- 0 = Report only (SAFE), 1 = Auto-fix logins

DECLARE c1 CURSOR LOCAL FAST_FORWARD READ_ONLY FOR 
    SELECT dp.NAME 
    FROM sys.database_principals dp 
    LEFT JOIN sys.server_principals sp ON dp.sid = sp.sid 
    WHERE dp.type_desc = 'WINDOWS_USER' 
      AND dp.authentication_type_desc = 'WINDOWS'
      AND dp.principal_id != 1  -- Exclude dbo
      AND sp.sid IS NULL;       -- No matching server login

OPEN c1;
FETCH c1 INTO @username;

WHILE @@FETCH_STATUS = 0 
BEGIN
    -- Count potential orphans before validation
    SET @cnt = @cnt + 1;

    /*
        xp_logininfo validates Windows account existence in AD/local SAM.
        @option='all' returns privilege level (user/group details).
        NULL result = account doesn't exist = TRUE orphan.
    */
    EXEC xp_logininfo 
        @acctname = @username, 
        @option = 'all', 
        @privilege = @privilege OUTPUT;

    -- Orphan confirmed (no Windows account found)
    IF @privilege IS NULL 
    BEGIN
        RAISERROR('Orphaned Windows user: %s', 10, 1, @username) WITH NOWAIT;
        
        -- AUTO-FIX: Create missing server login
        IF @fix_orphaned_user = 1 
        BEGIN 
            SET @sql = 'CREATE LOGIN [' + @username + 
                       '] FROM WINDOWS WITH DEFAULT_DATABASE = [' + DB_NAME() + ']';
            
            PRINT 'Creating login: ' + @sql;
            EXEC(@sql);
        END
    END;

    FETCH c1 INTO @username;
END;

CLOSE c1;
DEALLOCATE c1;

-- Final status message
IF @cnt = 0 
    RAISERROR('No potential orphaned Windows users found.', 10, 1) WITH NOWAIT;
ELSE IF @cnt > 0 AND @fix_orphaned_user = 0
    RAISERROR('%d potential orphaned Windows users (run with @fix_orphaned_user=1 to auto-fix).', 
              10, 1, @cnt) WITH NOWAIT;


