-- See blog post: https://sqlpal.blogspot.com/2019/11/finding-out-most-cached-database-in.html


SELECT 
CASE database_id   
        WHEN 32767 THEN 'ResourceDb'   
        ELSE db_name(database_id)   
        END AS database_name,
COUNT(*)AS cached_pages_count,
COUNT(*) / 128 / 1024 AS cache_size_gb
    
FROM sys.dm_os_buffer_descriptors  
GROUP BY DB_NAME(database_id) ,database_id  
ORDER BY cached_pages_count DESC; 
