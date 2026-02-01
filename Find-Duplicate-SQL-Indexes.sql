-- See blog post: https://sqlpal.blogspot.com/2019/05/find-identical-duplicate-indexes-revised.html
SET NOCOUNT ON;
USE [Your Database Name;
/*==========================================================================================
  Script Name : Find_Identical_Duplicate_Indexes.sql
  Purpose:
      Find identical duplicate indexes on the same table (same key columns, same order
      unless configured otherwise), so you can evaluate and potentially drop redundant ones.
  High-level approach:
      - Build a comma-separated list of key columns for every index in the database.
      - Optionally:
          * Include clustered vs nonclustered index pairs.
          * Ignore column order when comparing indexes.
      - Group by (schema, object, index_columns) and return those with COUNT(*) > 1.

  Variables/Parameters:
      @include_clustered_indexes (bit)
          0 = Ignore duplicates where one index is clustered and the other is nonclustered
          1 = Include those cases as duplicates too.

      @disregard_column_order (bit)
          0 = Only consider indexes duplicates if key columns match AND are in the same order.
          1 = Consider indexes duplicates even when the same key columns are in a different order.

  Notes / Caveats:
      - This script does NOT:
          * Consider ASC/DESC sort order differences.
          * Consider included columns.
          * Distinguish filtered vs non-filtered indexes beyond exposing filter_definition.
      - Do NOT blindly drop indexes; review each case in the context of workload and plans.
==========================================================================================*/


/*
    Whether to include identical indexes where one is clustered and 
    the other one is non-clustered
*/
DECLARE @include_clustered_indexes bit = 0;


/*
    Whether to find duplicate indexes where all key columns are the same,
    but not necessarily in the same order. Typical usage:
      - 0 (default): require same column order (more strict, closer to “identical”).
      - 1: ignore key column order, treat any permutation of the same columns as duplicates.
*/
DECLARE @disregard_column_order bit = 0;


;WITH cte AS
(
    SELECT
        o.schema_id,
        o.type_desc,
        o.object_id,
        i.index_id,
        i.name AS index_name,

        /*
            Build a comma-separated list of key column names for this index.
              - We need a stable string representation of the key columns to compare indexes.
              - Ordering of columns in the list is controlled by @disregard_column_order:
                    @disregard_column_order = 0 → order by key_ordinal (true index order)
                    @disregard_column_order = 1 → order by column_id (logical column order)
        */
        index_columns =
            COALESCE(
                STUFF
                (
                    (
                        SELECT
                            CAST(',' + COL_NAME(object_id, column_id) AS varchar(max))
                        FROM sys.index_columns
                        WHERE object_id = i.object_id
                          AND index_id  = i.index_id
                          AND is_included_column = 0          -- Only key columns, not INCLUDE
                        ORDER BY 
                            object_id, 
                            index_id,
                            CASE 
                                WHEN @disregard_column_order = 1 
                                    THEN column_id           -- Ignore index key order
                                ELSE key_ordinal            -- Respect index key order
                            END
                        FOR XML PATH(''), TYPE
                    ).value('.', 'varchar(max)')
                    , 1, 1, ''
                )
            , ''),

        -- Index metadata for review and decision making
        i.type_desc       AS index_type,
        i.is_unique,
        i.data_space_id,
        i.ignore_dup_key,
        i.is_primary_key,
        i.is_unique_constraint,
        i.fill_factor,
        i.is_padded,
        i.is_disabled,
        i.is_hypothetical,
        i.allow_row_locks,
        i.allow_page_locks,
        i.has_filter,
        i.filter_definition

    FROM sys.indexes AS i
    INNER JOIN sys.objects AS o 
        ON o.object_id = i.object_id
    WHERE 
        OBJECTPROPERTY(o.object_id, 'IsMsShipped') = 0   -- Skip system objects
        AND i.index_id <> 0                              -- Skip the heap "index"
        /*
            Control whether clustered indexes participate:

            - If @include_clustered_indexes = 0:
                  i.index_id > 1 → only nonclustered indexes.
            - If @include_clustered_indexes = 1:
                  i.index_id > 0 → clustered + nonclustered.
        */
        AND i.index_id > CASE WHEN @include_clustered_indexes = 1 THEN 0 ELSE 1 END
)

-- Find indexes with identical index_columns on the same object and same type
SELECT
    SCHEMA_NAME(i1.schema_id) AS schema_name,
    i1.type_desc,
    OBJECT_NAME(i1.object_id) AS object_name,
    i1.index_name,
    i1.*  -- Includes index_columns + metadata for review
FROM cte AS i1
INNER JOIN 
(
    /*
        Identify combinations of (schema_id, type_desc, object_id, index_columns)
        that occur more than once → those represent duplicate index definitions.
    */
    SELECT 
        schema_id, 
        type_desc, 
        object_id, 
        index_columns
    FROM cte
    GROUP BY 
        schema_id, 
        type_desc, 
        object_id, 
        index_columns
    HAVING COUNT(*) > 1
) AS i2
    ON  i1.schema_id     = i2.schema_id
    AND i1.type_desc     = i2.type_desc
    AND i1.object_id     = i2.object_id
    AND i1.index_columns = i2.index_columns
ORDER BY 
    schema_name, 
    i1.type_desc, 
    object_name, 
    i1.index_name;

