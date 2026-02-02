-- See blog post: https://sqlpal.blogspot.com/2019/05/do-you-have-rarely-used-indexes-that.html
SET NOCOUNT ON;
USE [Your Database Name];
/*==========================================================================================
  Script Name : Find-Heavy-Maintenance-Low-Usage-Indexes.sql

  Purpose:
      Identifies indexes that incur heavy maintenance overhead (lots of writes) 
      but provide little query benefit (few reads). These are prime candidates for removal.

  Logic:
      - Calculates total reads (seeks + scans + lookups) vs writes (updates) from dm_db_index_usage_stats
      - Filters for indexes with write_to_read_ratio > 10 (mostly write overhead)
      - Only non-unique indexes with significant activity (>1M writes, <1K reads)
      - Helps find indexes that hurt more than they help

  Thresholds (tune for your environment):
      - total_user_writes > 1,000,000  (significant maintenance cost)
      - total_user_reads < 1,000       (minimal query benefit)
      - write_to_read_ratio > 10       (writes >> reads)

  Prerequisites:
      - Run after server uptime of 24+ hours for reliable usage stats
      - dm_db_index_usage_stats resets on server restart/index rebuild

     SAFETY WARNING:
      - Stats reset on SQL restart, index rebuilds, or stats updates
      - Review execution plans before dropping ANY index
      - Test in dev first since some "write-heavy" indexes serve critical constraints

==========================================================================================*/

WITH index_usage AS
(
    SELECT 
        DB_NAME(iu.database_id) AS db_name,
        OBJECT_NAME(iu.object_id, iu.database_id) AS object_name,
        i.name AS index_name,
        i.type_desc AS index_type,
        
        -- Total read operations (query benefit)
        SUM(iu.user_seeks + iu.user_scans + iu.user_lookups) AS total_user_reads,
        
        -- Total write operations (maintenance cost)
        SUM(iu.user_updates) AS total_user_writes
        
    FROM sys.dm_db_index_usage_stats iu
    INNER JOIN sys.indexes i 
        ON i.object_id = iu.object_id 
        AND i.index_id = iu.index_id
    
    WHERE 
        iu.database_id = DB_ID() 
        AND i.index_id > 0
        AND i.is_unique = 0
        
    GROUP BY 
        iu.database_id,
        iu.object_id,
        i.name,
        i.type_desc
)

SELECT 
    *,
    
    -- Write-to-read ratio (higher = more maintenance overhead)
    total_user_writes * 1.0 / NULLIF(total_user_reads, 0) AS write_to_read_ratio

FROM index_usage

WHERE 
    -- High maintenance cost
    total_user_writes > 1000000                    -- 1M+ writes = significant overhead
    
    -- Low/no query benefit
    AND total_user_reads < 1000                    -- <1K reads = rarely used
    
    -- Mostly write overhead
    AND (
        total_user_writes * 1.0 / NULLIF(total_user_reads, 0) > 10  -- 10:1 write bias
        OR total_user_reads = 0                                    -- Never used
    )

ORDER BY write_to_read_ratio DESC;  -- Worst offenders first

/*
  USAGE TIPS:
  
  1. Run after 24+ hours uptime for reliable stats
  2. Higher thresholds = fewer but more certain candidates
  3. Check execution plans before dropping ANY index
  4. Consider business constraints (FKs, app assumptions)
  
  EXAMPLE THRESHOLD ADJUSTMENTS:
  -- More aggressive:
  -- total_user_writes > 500000 AND total_user_reads < 500
  
  -- More conservative:
  -- total_user_writes > 5000000 AND total_user_reads < 100
*/

