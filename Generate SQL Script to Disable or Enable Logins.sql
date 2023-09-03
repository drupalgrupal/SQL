-- See blog post: https://sqlpal.blogspot.com/2023/07/generate-sql-script-to-allow-or.html

use <DBName>
SELECT sp.name [Login_Name],
       dp.name [DB_User],
       'ALTER LOGIN ' + QUOTENAME(sp.name) +' DISABLE;' [Disable_Logins],
       'ALTER LOGIN ' + QUOTENAME(sp.name) +' ENABLE;' [Enable_Logins]
FROM sys.database_principals dp
INNER JOIN sys.server_principals sp ON dp.sid = sp.sid
WHERE dp.name not in ('public','dbo','guest','INFORMATION_SCHEMA','sys')
  AND dp.name not in ('AppUser1', 'AppUser1')
ORDER BY dp.name
