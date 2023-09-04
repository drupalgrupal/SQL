-- See blog post: https://sqlpal.blogspot.com/p/dirty-pages-in-sql-server-buffer-cache.html

;WITH cte
     AS (SELECT Cast(Count(*) AS FLOAT) Total_Pages,
                Count(CASE WHEN is_modified = 0 THEN 1 END) Clean_Pages,
                Count(CASE WHEN is_modified = 1 THEN 1 END) Dirty_Pages
         FROM   sys.dm_os_buffer_descriptors
         WHERE  page_type IN ( 'DATA_PAGE', 'INDEX_PAGE', 'TEXT_MIX_PAGE' ))

SELECT Total_Pages,
       Clean_Pages,
       Dirty_Pages,
       Dirty_Pages_Percentage = Cast(( Dirty_Pages / Total_Pages ) * 100 
              AS DECIMAL(4, 2)) 
FROM   cte; 
