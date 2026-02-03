-- See blog post: https://sqlpal.blogspot.com/2019/11/finding-out-most-cached-database-in.html
-- =====================================================================================
-- Query: Find the Most Cached Database in SQL Server Buffer Cache
-- Purpose: Identifies databases consuming the most buffer cache (data pages in memory).
--          Helps pinpoint heavily used, under-optimized, or problematic databases.
--          Useful for performance tuning, capacity planning, and resource allocation.
-- 
-- DMV: sys.dm_os_buffer_descriptors - Returns information about buffer pool pages.
--      Each row represents one 8KB page in the buffer cache.
-- 
-- PERFORMANCE WARNING: On modern SQL Servers with large memory (>128GB RAM),
--      sys.dm_os_buffer_descriptors contains millions of rows and be slow to VERY slow.
--      Consider running during maintenance windows or using sampled approaches on huge systems.

-- Compatibility: Tested on SQL Server 2008 SP3 and later versions (up to 2025).
--                Works across all editions (Express, Standard, Enterprise).
-- 
-- =====================================================================================

SELECT 
    CASE database_id   
        WHEN 32767 THEN 'ResourceDb'   
        ELSE DB_NAME(database_id)   
    END AS database_name,
    
    COUNT(*) AS cached_pages_count,
    
    -- Convert page count to GB for easier readability
    -- Page size = 8KB = 8192 bytes
    -- Formula: (pages * 8KB) / 1024 / 1024 = GB
    COUNT(*) * 8 / 1024 / 1024 AS cache_size_gb

FROM sys.dm_os_buffer_descriptors  
GROUP BY DB_NAME(database_id), database_id  
ORDER BY cached_pages_count DESC;

