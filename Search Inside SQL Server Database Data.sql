-- https://sqlpal.blogspot.com/2024/04/data-search-within-sql-server-databases.html

/* 
-- CREATE A TEST TABLE FOR DEMO 
IF OBJECT_ID('my_data_search_table', 'U') IS NOT NULL
    DROP TABLE my_data_search_table;

CREATE TABLE my_data_search_table (
    id INT,
    name VARCHAR(100)
);

INSERT INTO my_data_search_table (id, name)
VALUES (1996, 'dummy');

*/
SET NOCOUNT ON;
USE <Your DB Name Here>;
GO

-- Drop temp tables if exists
IF OBJECT_ID('tempdb..#t_table_columns') IS NOT NULL DROP TABLE #t_table_columns;
IF OBJECT_ID('tempdb..#results') IS NOT NULL DROP TABLE #results;
GO

-- Search string
DECLARE @search_value NVARCHAR(4000) = N'dummy'; -- Example search value

/* Limit what column data types to search into 
Here, you can specify whether to search within numeric data types, 
other data types, or both. This helps in narrowing down the search 
to relevant fields, potentially speeding up the search 
process and reducing the load on the database.
*/
-- valid values are numeric, other or both
DECLARE @search_datatype   VARCHAR(10)  
-- SET @search_datatype   = 'numeric'

-- Search mode
DECLARE @exact_match       BIT = 1; 

-- EXECUTION OPTIONS
DECLARE @execute           BIT = 1; -- 1 to execute the search queries
DECLARE @debug             BIT = 0; -- 1 to print only
DECLARE @show_progress     BIT = 1; -- 1 to print progress messages
DECLARE @progress_interval INT = 100;

-- Schema, Table, and Column Filtering (NULL means no filter)
DECLARE @search_column_name NVARCHAR(1000);
DECLARE @search_table_name  NVARCHAR(1000);
DECLARE @search_schema_name NVARCHAR(1000);

-- Dynamic SQL query
DECLARE @SQL NVARCHAR(4000);

-- If wild card searfch is requested i.e. @exact_match = 0 
IF @exact_match = 0 SET @search_value = N'%' + @search_value + N'%';

-- Temp table to store columns metadata
SELECT s.name AS [schema_name],
       t.name AS [table_name], 
       c.name AS [column_name],
       TYPE_NAME(c.system_type_id) AS [column_type]
INTO #t_table_columns 
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
JOIN sys.columns c ON t.object_id = c.object_id
WHERE t.is_ms_shipped = 0
  AND TYPE_NAME(c.system_type_id) NOT IN ('image', 'varbinary');


-- Store list of numeric data types into a table variable
DECLARE @numeric_types TABLE (name VARCHAR(100));

INSERT INTO @numeric_types (name)
VALUES
    ('bigint'),
    ('bit'),
    ('decimal'),
    ('int'),
    ('money'),
    ('numeric'),
    ('smallint'),
    ('smallmoney'),
    ('tinyint'),
    ('float'),
    ('real');


IF (@search_datatype = 'numeric' AND ISNUMERIC(@search_value) = 0)
BEGIN
   RAISERROR('Error: Search value (%s) invalid for numeric search.', 16, 1, @search_value)
   GOTO QUIT
END

-- Apply filters
IF @search_schema_name IS NOT NULL AND @search_schema_name <> ''
    DELETE FROM #t_table_columns WHERE [schema_name] <> @search_schema_name;
IF @search_table_name IS NOT NULL AND @search_table_name <> ''
    DELETE FROM #t_table_columns WHERE [table_name] <> @search_table_name;
IF @search_column_name IS NOT NULL AND @search_column_name <> ''
    DELETE FROM #t_table_columns WHERE [column_name] <> @search_column_name;

IF @search_datatype IS NOT NULL AND @search_datatype <> ''
BEGIN
	IF @search_datatype NOT IN ('numeric', 'other', 'both')
	BEGIN
		RAISERROR('Error: Invalid value %s for @search_datatype.', 16, 1, @search_datatype) WITH NOWAIT
		RAISERROR('Valid values are 1) numeric 2) other 3) both.', 16, 1) WITH NOWAIT
		GOTO QUIT
	END
	ELSE IF @search_datatype = 'numeric'
	    DELETE #t_table_columns FROM #t_table_columns t
			WHERE NOT EXISTS (SELECT * FROM @numeric_types v WHERE v.name = t.[column_type])
	ELSE IF @search_datatype = 'other'
	    DELETE #t_table_columns FROM #t_table_columns t
			INNER JOIN @numeric_types v ON v.name = t.[column_type]
END

-- Placeholder for results
SELECT TOP 0 * INTO #results FROM #t_table_columns;

-- Progress tracking
DECLARE @total_columns INT;
DECLARE @counter INT = 0;

-- Variables for cursor
DECLARE @schema_name SYSNAME,
        @table_name  SYSNAME,
        @column_name SYSNAME,
        @column_type NVARCHAR(500);

-- Declare cursor
DECLARE c1 CURSOR STATIC FOR 
    SELECT * FROM #t_table_columns 
    ORDER BY [schema_name], [table_name], [column_name];

OPEN c1;
SELECT @total_columns = @@CURSOR_ROWS; 


FETCH NEXT FROM c1 INTO 
    @schema_name, @table_name, @column_name, @column_type;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @counter = @counter + 1;

    -- Progress message
    IF @counter % @progress_interval = 0 AND @show_progress = 1
        RAISERROR('%i columns of %i processed', 10, 1, @counter, @total_columns) WITH NOWAIT;

    -- Build and execute the search query
    SET @SQL = N'SELECT TOP 1 ''' + @schema_name + N''' AS [schema_name], ''' 
               + @table_name + N''' AS [table_name], ''' +  @column_name 
               + N''' AS [column_name], ''' +  @column_type 
               + N''' AS [column_type] FROM ' + QUOTENAME(@schema_name) 
               + N'.' + QUOTENAME(@table_name) + N' WHERE TRY_CAST(' 
               + QUOTENAME(@column_name) + N' AS VARCHAR(8000)) LIKE ''' 
               + @search_value + N''';';

    IF @debug = 1 PRINT @SQL;

    -- Insert into results if match is found
    IF @execute = 1 BEGIN
        INSERT INTO #results EXEC (@SQL);
        IF @@ROWCOUNT > 0 BEGIN
            PRINT '';
            RAISERROR('*** match found ***', 10, 1) WITH NOWAIT;
            PRINT @SQL;
            PRINT '';
        END
    END

    FETCH NEXT FROM c1 INTO 
        @schema_name, @table_name, @column_name, @column_type;
END

-- Cleanup
CLOSE c1;
DEALLOCATE c1;

-- Display results with export commands
SELECT *,
       'SELECT COUNT(*) [' + [schema_name] + '.' + [table_name] 
       + '] FROM '  + QUOTENAME([schema_name]) + '.' 
       + QUOTENAME([table_name]) + ' WHERE TRY_CAST(' 
       + QUOTENAME([column_name])  + ' AS VARCHAR(8000)) LIKE ''' 
       + @search_value + N''';' AS [SQL],
       'Send-SQLDataToExcel -Connection "Server=' + @@SERVERNAME 
       + ';Trusted_Connection=True;" -MsSQLserver -DataBase "' 
       + DB_NAME() + '" -SQL "select * from ' 
       + QUOTENAME([schema_name]) + '.' + QUOTENAME([table_name]) 
       + '" -Path "$env:USERPROFILE\Documents\' + DB_NAME() +  '.' 
       + [schema_name] + '.' + [table_name] + '.xlsx"' AS [PS Export],
       'BCP ' + QUOTENAME(DB_NAME()) + '.' +  QUOTENAME([schema_name]) 
       + '.' + QUOTENAME([table_name]) + ' out %USERPROFILE%\Documents\' 
       + DB_NAME() + '_' +  [schema_name] + '_' + [table_name] 
       + '.txt -c -t, -T -S' + @@SERVERNAME AS [BCP Export]
FROM #results 
ORDER BY [schema_name], [table_name], [column_name];

QUIT:

