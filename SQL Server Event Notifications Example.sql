-- See blog post: https://sqlpal.blogspot.com/2019/11/event-notifications-example.html

-- Create a brand new database for the testing purpose
use master
go
if db_id('temp_event_notification_test_929368242990-321836') is not null
  drop database [temp_event_notification_test_929368242990-321836]
go
CREATE DATABASE [temp_event_notification_test_929368242990-321836]
GO


-- Enable the service broker if its not already
if not exists (select * from sys.databases where name = '[temp_event_notification_test_929368242990-321836]' and is_broker_enabled = 1)
ALTER DATABASE [temp_event_notification_test_929368242990-321836] SET ENABLE_BROKER; 
go

-- set the trustworth property ON
if not exists (select * from sys.databases where name = '[temp_event_notification_test_929368242990-321836]' and is_trustworthy_on = 1)
ALTER DATABASE [temp_event_notification_test_929368242990-321836] SET TRUSTWORTHY ON;
go

-- check if there is already a service broker end point running
if not exists (select * from sys.service_broker_endpoints where type_desc = 'SERVICE_BROKER' and state_desc = 'STARTED' )
BEGIN
    -- check if there is a SB endpoint with same name
    if not exists (select * from sys.service_broker_endpoints where NAME = 'en_service_broker_929368242990-321836')
 BEGIN
    -- check to make sure the tcp port is not already in use
    if not exists (SELECT * FROM SYS.tcp_endpoints where port = 5122)
   CREATE ENDPOINT [en_service_broker_929368242990-321836]
   STATE = STARTED
   AS TCP (  LISTENER_PORT = 5122)
   FOR SERVICE_BROKER (AUTHENTICATION = WINDOWS  );
    else
   raiserror('Error: An end point cannot be created. Please check if there is already one with same port.', 16,1)
 END
 else
    raiserror('Error: An end point cannot be created. Please check if there is already one with same name.', 16,1)
END
GO
USE [temp_event_notification_test_929368242990-321836]

go
CREATE QUEUE [ent_929368242990-321836] ;  
GO  
CREATE SERVICE [ens_929368242990-321836]  
ON QUEUE [ent_929368242990-321836]  
(  
[http://schemas.microsoft.com/SQL/Notifications/PostEventNotification]  
);  
GO  

CREATE ROUTE [enr_929368242990-321836]  
WITH SERVICE_NAME = 'ens_929368242990-321836',  
ADDRESS = 'LOCAL';  
GO  

CREATE EVENT NOTIFICATION [enen_929368242990-321836]  
ON DATABASE  
FOR ALTER_TABLE  
TO SERVICE 'ens_929368242990-321836',  'current database'

-- Test
-- Generate the events
if object_id('entt_929368242990-321836') is not null
drop table [entt_929368242990-321836]
go
create table [entt_929368242990-321836] (i int)
go
alter table [entt_929368242990-321836] add b int
go

-- verify/display that the event notification was captured
SELECT TOP (1000) *, casted_message_body = 
CASE message_type_name WHEN 'X' 
  THEN CAST(message_body AS NVARCHAR(MAX)) 
  ELSE message_body 
END 
FROM [temp_event_notification_test_929368242990-321836].[dbo].[ent_929368242990-321836] WITH(NOLOCK)

if @@ROWCOUNT = 0
   RAISERROR('Error: Something is not right. Event notification was not captured.', 16,1)
else 
   SELECT 'Success!' Msg
go


-- clear the records from the queue
-- RECEIVE display the event as well as removes it from the queue

RECEIVE * FROM [ent_929368242990-321836]
go
-- verify that the queue is now empty

SELECT TOP (1000) *, casted_message_body = 
CASE message_type_name WHEN 'X' 
  THEN CAST(message_body AS NVARCHAR(MAX)) 
  ELSE message_body 
END 
FROM [temp_event_notification_test_929368242990-321836].[dbo].[ent_929368242990-321836] WITH(NOLOCK)

-- Since I am only testing, I am using the following code to clean up afterwards

/* CLEAN UP
USE [temp_event_notification_test_929368242990-321836]
go
if exists (SELECT * FROM sys.event_notifications where name = '[enen_929368242990-321836]' and parent_class_desc = 'DATABASE')
DROP EVENT NOTIFICATION [enen_929368242990-321836]  ON DATABASE;  
go

if exists (select  * from sys.routes where name = '[enr_929368242990-321836]' and address = 'LOCAL')
DROP ROUTE [enr_929368242990-321836] 

if exists (SELECT * FROM sys.services where name = 'ens_929368242990-321836')
DROP SERVICE [ens_929368242990-321836]
GO
if exists (SELECT * FROM sys.service_queues where name = 'ent_929368242990-321836' and schema_id = 1)
DROP QUEUE [dbo].[ent_929368242990-321836]
GO
use master
go
if db_id('temp_event_notification_test_929368242990-321836') is not null
  drop database [temp_event_notification_test_929368242990-321836]
go

*/


