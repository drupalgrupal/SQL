-- See blog post: https://sqlpal.blogspot.com/2019/05/find-identical-duplicate-indexes-revised.html

/*
whether to include identical indexes where one is clustered and 
the other one is non-clustered index
*/
DECLARE @include_clustered_indexes bit = 0
/*
whether to find duplicate indexes where although all columns are same, they may not be in same order
*/
DECLARE @disregard_column_order bit = 0
;WITH cte
AS
       (SELECT
                        o.schema_id,
                        o.type_desc,
                        o.object_id,
                        i.index_id,
                        i.name index_name,
                        index_columns =
                                                             COALESCE((STUFF((SELECT CAST(',' +
                                                             COL_NAME(object_id, column_id) AS varchar(max))
                               FROM sys.index_columns
                               WHERE
                          (
                                 object_id = i.object_id AND
                                         index_id = i.index_id
                          )
                               ORDER BY object_id, index_id,
                               CASE WHEN @disregard_column_order = 1
                                then column_id 
                                else key_ordinal end
                               FOR xml PATH ('')), 1, 1, '')), ''),
                        i.type_desc index_type,
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
       FROM sys.indexes i
       INNER JOIN sys.objects o ON o.object_id = i.object_id
       WHERE OBJECTPROPERTY(o.object_id, 'ismsshipped') = 0 AND index_id != 0
       AND i.index_id > CASE WHEN @include_clustered_indexes = 1 THEN 0 ELSE 1 END
)
SELECT
          SCHEMA_NAME(i1.schema_id) schema_name,
          i1.type_desc,
          OBJECT_NAME(i1.object_id) object_name,
          i1.index_name,
          i1.*
FROM cte i1
INNER JOIN (SELECT schema_id, type_desc, object_id, index_columns
            FROM cte
            GROUP BY schema_id, type_desc, object_id, index_columns
            HAVING COUNT(*) > 1) i2
                      ON i1.schema_id = i2.schema_id
           AND i1.type_desc = i2.type_desc
           AND i1.object_id = i2.object_id
           AND i1.index_columns = i2.index_columns
ORDER BY schema_name, i1.type_desc, object_name, i1.index_name
