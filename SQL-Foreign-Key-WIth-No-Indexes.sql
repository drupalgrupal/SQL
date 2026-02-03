-- See blog post: https://sqlpal.blogspot.com/2018/05/dmv-to-list-of-foreign-keys-with-no.html

;
SET NOCOUNT ON;
-- USE [Database Name]
-- =====================================================================================
-- Query: Find Foreign Keys WITHOUT Indexes - Potneitial Performance Killers
-- Purpose: Identifies unindexed foreign key columns causing delete/update performance issues,
--          lock escalations, and deadlocks during referential integrity checks.
--          Without FK indexes, SQL Server scans ENTIRE child tables 
--          during parent deletes/updates. Logical reads drop from 1000s to single digits.
--
-- Key Benefits:
--  - Finds what sys.dm_db_missing_index_details misses (small FK columns)
--  - Prioritizes by table size (used_page_count DESC)
--  - Flags CASCADE DELETE/UPDATE risks
--
-- Compatibility: SQL Server 2008+ (sys.foreign_key_columns introduced 2008)
-- Scope: Current database only
-- =====================================================================================

WITH fk_cte AS (
    SELECT 
        -- PARENT Table (PK side)
        OBJECT_NAME(fk.referenced_object_id) AS pk_table,
        c2.name AS pk_column,
        kc.name AS pk_index_name,
        
        -- CHILD Table (FK side - NEEDS INDEX!)
        OBJECT_NAME(fk.parent_object_id) AS fk_table,
        c.name AS fk_column,
        fk.name AS fk_name,
        
        -- CRITICAL: Does FK column have an index?
        CASE WHEN i.object_id IS NOT NULL THEN 1 ELSE 0 END AS does_fk_has_index,
        
        i.is_primary_key AS is_fk_a_pk_also,
        i.is_unique AS is_index_on_fk_unique,
        
        fk.object_id, fk.parent_object_id, 
        fk.referenced_object_id,
        fk.delete_referential_action,      -- 1=CASCADE, 2=SET NULL, etc.
        fk.update_referential_action,
        fk.is_not_trusted, 
        fk.is_not_for_replication, 
        fk.is_disabled
        
    FROM sys.foreign_keys fk
    
        INNER JOIN sys.foreign_key_columns fkc 
            ON fkc.constraint_object_id = fk.object_id
        
        INNER JOIN sys.columns c 
            ON c.object_id = fk.parent_object_id 
            AND c.column_id = fkc.parent_column_id
        
        LEFT JOIN sys.columns c2 
            ON c2.object_id = fk.referenced_object_id 
            AND c2.column_id = fkc.referenced_column_id
        
        LEFT JOIN sys.key_constraints kc 
            ON kc.parent_object_id = fk.referenced_object_id 
            AND kc.type = 'PK'
        
        LEFT JOIN sys.index_columns ic 
            ON ic.object_id = c.object_id 
            AND ic.column_id = c.column_id
        
        LEFT JOIN sys.indexes i 
            ON i.object_id = ic.object_id 
            AND i.index_id = ic.index_id
)
-- FINAL RESULT: ONLY unindexed FKs, prioritized by table size
SELECT * 
FROM fk_cte
    
    -- Add table size for impact prioritization (heap + clustered index)
    LEFT JOIN sys.dm_db_partition_stats ps 
        ON ps.object_id = fk_cte.parent_object_id 
        AND ps.index_id <= 1  -- Heap (0) + Clustered (1)
WHERE does_fk_has_index = 0  -- SHOW UNINDEXED FKs ONLY
  
ORDER BY used_page_count DESC, fk_table, fk_column;  -- BIGGEST TABLES FIRST
