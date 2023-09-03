-- See blog post: Generate SQL Script to Allow or Disallow Access To All Data

/* 
-- List of valid permissions at the schema level
ALTER
CONTROL
CREATE SEQUENCE
DELETE
EXECUTE
INSERT
REFERENCES
SELECT
TAKE OWNERSHIP
UPDATE
VIEW CHANGE TRACKING
VIEW DEFINITION

Please see: https://learn.microsoft.com/en-us/sql/t-sql/statements/grant-schema-permissions-transact-sql?view=sql-server-ver16

*/
SET NOCOUNT ON
GO
USE <DBName>
DECLARE @schema_owner varchar(100)
DECLARE @schema_permission varchar(100) = 'EXECUTE'
SET @schema_owner = 'dbo'     

declare @valid_permissions table(valid_permission_name varchar(100))
insert into @valid_permissions
values
('ALTER'),
('CONTROL'),
('CREATE SEQUENCE'),
('DELETE'),
('EXECUTE'),
('INSERT'),
('REFERENCES'),
('SELECT'),
('TAKE OWNERSHIP'),
('UPDATE'),
('VIEW CHANGE TRACKING'),
('VIEW DEFINITION')

IF SCHEMA_ID(@schema_owner) is null
BEGIN
		RAISERROR('Error: Schema %s does not exist.', 16, 1, @schema_owner)
		GOTO QUIT
END


if not exists(select * from @valid_permissions where valid_permission_name = @schema_permission)
BEGIN
		RAISERROR('Error: Permission (%s) is not a valid schema permission.', 16, 1, @schema_permission)
		SELECT valid_permission_name FROM @valid_permissions
		GOTO QUIT
END


SELECT 
		name [user_name],
		@schema_owner [schema_name],
		'USE ' + QUOTENAME(db_name()) + ';' + 
		'GRANT ' + @schema_permission + ' ON SCHEMA::' + QUOTENAME(@schema_owner) + ' TO ' + QUOTENAME(name) + ';' [Grant_Schema_Access],

		'USE ' + QUOTENAME(db_name()) + ';' + 
		'DENY ' + @schema_permission + ' ON SCHEMA::' + QUOTENAME(@schema_owner) + ' TO ' + QUOTENAME(name) + ';' [Deny_Schema_Access]

FROM sys.database_principals
WHERE      name not in ('public','dbo','guest','INFORMATION_SCHEMA','sys')
       AND name not in ('AppUser1','AppUser2')
       AND is_fixed_role = 0
ORDER BY name

QUIT:
