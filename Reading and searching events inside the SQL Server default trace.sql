-- See blog post: https://sqlpal.blogspot.com/2023/07/reading-and-searching-events-inside-sql.html

-- lets view the settings for the default trace
SELECT * FROM sys.traces WHERE is_default = 1

-- lets get the trace file name without the roll over number
Declare @trace_file_full_name nvarchar(1000);
Declare @trace_file_path nvarchar(1000);
Declare @trace_file_name nvarchar(1000);

SELECT @trace_file_full_name = path FROM sys.traces WHERE is_default = 1

-- Split the file name into path and just the file name parts
select  
       @trace_file_path = LEFT(@trace_file_full_name,LEN(@trace_file_full_name) - charindex('\',reverse(@trace_file_full_name),1) + 1),  
       @trace_file_name = RIGHT(@trace_file_full_name, CHARINDEX('\', REVERSE(@trace_file_full_name)) -1) ;

-- remove the roll over number from the trace file name
;with cte as
(
       SELECT PATINDEX('%[0-9.]%', @trace_file_name) start_at, CHARINDEX('.', @trace_file_name) end_at
)
select @trace_file_name = replace(STUFF(@trace_file_name, start_at, end_at-start_at, ''), '_', '')  from cte;

-- put the path and file name back together
select @trace_file_name = (@trace_file_path +  @trace_file_name)

select @trace_file_name trace_file_name

-- now we can look for any information available in the trace files, current as well as rolled over ones
if @trace_file_name is null
begin
    goto ErrorSection
end
        
select top 10000
       t.DatabaseName,
       e.name EventName, 
       t.Duration Duration_Micro_Seconds,
       t.Duration / 1000000 Duration_Seconds,
       t.* 
from sys.fn_trace_gettable(@trace_file_name, DEFAULT) t
inner join sys.trace_events e on e.trace_event_id = t.EventClass
inner join sys.trace_categories c ON e.category_id = c.category_id
where 1=1
and e.name  in ('Log File Auto Grow', 'Data File Auto Grow')
and t.DatabaseName !='tempdb'
order by t.starttime desc
goto Success

ErrorSection:
raiserror('Default trace file name could not be determined...', 16,1)

Success:

