/*
RETURNS LIST OF FOLDER NAMES WHERE SQL SERVER DATABASE
FILES ARE STORED

*/

DECLARE @PRODUCTVERSION NVARCHAR(132)
DECLARE @PERMISSION_FLAG bit
SET @PRODUCTVERSION = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(32)) 
SET @PERMISSION_FLAG = 1

-- For use on older versions of sql server or if you don't have permission to sys.master_files
-- tested in sql 2000 & 20005
if SUBSTRING(@PRODUCTVERSION, 1, CHARINDEX('.', @PRODUCTVERSION)-1) < 10 OR @PERMISSION_FLAG = 0 OR @PERMISSION_FLAG IS NULL
		BEGIN
		PRINT 'We gonna use old school method.....'
		set nocount on if object_id('tempdb..#t1') is not null drop table #t1
			create table #t1 (fpath varchar(4000), fname varchar(8000))
		insert into #t1
			exec sp_msforeachdb 'select left(filename, len(filename) - charindex(''\'', reverse(rtrim(filename)))) fpath, filename fname from [?].dbo.sysfiles'
		select distinct fpath from #t1 order by 1
END

-- For use on SQL version xxx and above 
ELSE 
		with cte as
		(
				select 
					case 
						when type = 2 then physical_name     -- FILESTREAM
						else left(physical_name, len(physical_name) - charindex('\', reverse(rtrim(physical_name)))) 
					end folder_path, 
					physical_name  
				from sys.master_files
		)
		select distinct 
			folder_path,
			[create_folder] = 'mkdir -p "' + folder_path + '"'
		from cte
                order by folder_path;

