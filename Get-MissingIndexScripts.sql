-- Get-MissingIndexScripts.sql
--
SELECT 
    LEFT(PARSENAME(mid.statement, 3), 32) AS DB_Name,
    PARSENAME(mid.statement, 2) AS schema_name,
    PARSENAME(mid.statement, 1) AS table_name,
    
    -- Improvement score (higher = bigger win)
    CAST(migs.avg_total_user_cost * (migs.avg_user_impact / 100.0) * 
         (migs.user_seeks + migs.user_scans) AS BIGINT) AS estimated_benefit,

    -- GENERATE CREATE INDEX STATEMENT
    'CREATE INDEX [missing_idx_' + 
        LEFT(PARSENAME(mid.statement, 1), 32) + 
        ISNULL('_' + REPLACE(COALESCE(PARSENAME(mid.equality_columns, 1), ''), ',', '_'), '') +
        ISNULL('_' + REPLACE(COALESCE(PARSENAME(mid.inequality_columns, 1), ''), ',', '_'), '') +
        '_' + CAST(migs.group_handle AS VARCHAR(50)) + 

    '] ON ' + mid.statement +
    ' (' + 
        ISNULL(mid.equality_columns, '') +
        CASE WHEN mid.equality_columns IS NOT NULL AND mid.inequality_columns IS NOT NULL 
             THEN ',' ELSE '' END +
        ISNULL(mid.inequality_columns, '') +
    ')' AS create_index_statement,

    -- Column counts for index analysis
    ISNULL(LEN(mid.equality_columns) - LEN(REPLACE(mid.equality_columns, ',', '')) + 1, 0) 
        AS equality_columns_count,
    ISNULL(LEN(mid.inequality_columns) - LEN(REPLACE(mid.inequality_columns, ',', '')) + 1, 0) 
        AS inequality_columns_count,
    ISNULL(LEN(mid.included_columns) - LEN(REPLACE(mid.included_columns, ',', '')) + 1, 0) 
        AS included_columns_count

FROM sys.dm_db_missing_index_groups mig
INNER JOIN sys.dm_db_missing_index_group_stats migs 
    ON migs.group_handle = mig.index_group_handle
INNER JOIN sys.dm_db_missing_index_details mid 
    ON mig.index_handle = mid.index_handle

WHERE 
    -- High impact only
    migs.avg_total_user_cost * (migs.avg_user_impact / 100.0) * (migs.user_seeks + migs.user_scans) > 1000
    AND (migs.user_seeks + migs.user_scans) > 500
    AND migs.avg_user_impact > 50
    
    -- Recent activity (last 24 hours)
    AND (migs.last_user_seek > DATEADD(DAY, -1, GETDATE()) 
         OR migs.last_user_scan > DATEADD(DAY, -1, GETDATE()))
    
    -- Reasonable index size limits
    AND ISNULL(LEN(mid.equality_columns) - LEN(REPLACE(mid.equality_columns, ',', '')) + 1, 0) < 6

ORDER BY estimated_benefit DESC;

