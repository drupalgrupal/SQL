# SQL Server Transaction Log Forensics: A Hands-On sys.fn_dblog Lab

A self-contained teaching lab for the SQLPal transaction-log forensics article. Create a disposable database, stage several changes, capture log records once, and investigate the saved evidence.

**Compatibility target: SQL Server 2017 and later. Version: 1.1.** The user reports testing version 1.0 on SQL Server 2022; the exact build and assertion results were not recorded here. This revision has received static review but has not been execution-tested. Compatibility level 140 and version-gated configuration avoid dependence on newer T-SQL syntax, but an undocumented function cannot carry a future-version compatibility guarantee.

## Files

- **`sql-server-transaction-log-forensics-lab.sql`:** Database creation, sample data, baseline backup, incident simulation, evidence capture, guided queries, runtime assertions, and a commented-out cleanup block at the end.
- **`sql-server-transaction-log-forensics-cleanup.sql`:** Optional standalone copy of the same cleanup code, with an exact confirmation string and a database marker check.

## Before you run

Use a disposable, isolated SQL Server instance with enough free space for a small database and a real full backup. Do not use a production instance, even if you intend to create only a new database.

The lab requires a sysadmin connection and targets installed SQL Server, including suitable Developer, Standard, Enterprise, Web, and Express editions. Azure SQL Database, Managed Instance, and Synapse are outside this lab's scope.

Exclude the lab database from automated log backups and maintenance. If you cannot guarantee that, use a different instance.

In a real production incident, contact Microsoft Support and your incident-response team early. This script is an educational experiment, not a production evidence-preservation or recovery procedure.

## How to run

1. Open the main `.sql` file in a fresh SSMS query window against the disposable instance.
2. Read the safety header and set `@IUnderstandThisIsADisposableLab = 1`.
3. Optionally set `@BackupDirectory` to an existing server-side directory writable by the SQL Server service account. If omitted, the lab discovers the instance's default backup directory. It never substitutes the data directory or creates an operating-system directory.
4. Run the entire script as one batch. It does not require SQLCMD mode.
5. Read the numbered result sets and the comments preceding their queries.
6. Record the exact engine build from `dbo.LabRun` and the final PASS result.
7. Keep the lab only as long as needed. Export wanted results before copying and running the commented cleanup code at the end, or using its standalone copy.

If a database named `SQLPal_LogForensicsLab` exists, the main script refuses to proceed. A failed or cancelled run may leave partial objects; inspect them rather than blindly rerunning or deleting them. If cancellation leaves a transaction open, roll back that lab transaction in the original connection.

The script uses dynamic batches so the new database can be created before its objects are compiled, while keeping one outer error handler. Doubled single quotes inside those batches are T-SQL string escaping, not characters to paste into a standalone query.

## What the scenarios teach

| Scenario | Intended result | Investigation lesson |
|---|---|---|
| INSERT | Add customer 7 | Follow a simple committed transaction |
| UPDATE | Change customer 2's credit limit | Inspect row-log bytes without assuming a generic row decoder |
| DELETE | Remove customers 3 and 4 | Locate candidate records and establish transaction outcome |
| TRUNCATE | Empty the separate work queue | Examine allocation and metadata work rather than individual user-row deletion records |
| ROLLBACK | Delete customer 5, then undo it | A logged delete alone is not proof of committed data loss |

The script first offers discovery queries that do not rely on scenario labels, then reveals the teaching answer key. Named outer transactions are useful labels for this exercise, not something to assume an ordinary application supplies, as explained in [Gail Shaw's discussion of transaction names](https://www.sqlservercentral.com/blogs/why-would-you-want-to-name-a-transaction).

## How this lab keeps the example records available

The script sets FULL recovery, takes a conventional full baseline backup, and takes no subsequent log backups during the exercise. This establishes the backup chain rather than assuming that setting FULL recovery alone is sufficient; the relationship between checkpoints, log backups, and truncation is covered in [Microsoft's transaction log architecture guide](https://learn.microsoft.com/en-us/sql/relational-databases/sql-server-transaction-log-architecture-and-management-guide).

This design avoids holding a deliberately open transaction to pin the log. It also makes the exercise dependent on isolation from external log-backup jobs. It is not guidance to stop backups in a real incident, and it is not a reason to leave a FULL-recovery database receiving writes indefinitely.

The first capture goes into a temporary table. After the scan completes, the script copies that snapshot to `dbo.LogEvidence` in the lab database for convenient repeat investigation; all later queries use that saved table. This same-database convenience is deliberately limited to the disposable lab, not a recommendation for production evidence handling.

## How to read the results

- **Build and capture manifest:** `dbo.LabRun` records the engine version, backup path, session identity, incident window, and capture window. Times are server-local; a separate timestamp with offset helps document the environment.
- **Operation inventory:** Counts describe log records, not affected business rows.
- **Delete candidates:** The pre-incident allocation map identifies relevant customer-table allocations without relying on the named transaction.
- **Transaction boundaries:** Compare begin, commit, and abort records instead of inferring outcome from an isolated row operation.
- **Identity:** The saved SID and its current login-name resolution describe a security context. Treat human attribution as a separate question needing corroboration.
- **Raw bytes:** Binary fields are shown without speculative decoding or an automatic undo script.
- **TRUNCATE trail:** Inspect root-transaction records and their descriptions; do not expect identical internal operation sequences on every build.
- **Final state:** Five customers remain, customer 5 survives the rollback, customer 2 has a credit limit of 2500, and the work queue is empty.

Related engine work can use separate system transactions; the root transaction is not always the complete set of associated work, as [Paul Randal explains for Parent Transaction ID](https://www.sqlskills.com/blogs/paul/parent-transaction-id-in-2012-fn_dblog-output/). `TRUNCATE` can also involve deferred deallocation, described in [Microsoft's documentation](https://learn.microsoft.com/en-us/sql/t-sql/statements/truncate-table-transact-sql).

## What this lab does not prove

The before-image tables and scenario guide are known teaching inputs. They are not reconstructed from transaction-log bytes, and the exercise does not claim to recover arbitrary deleted rows.

The snapshot is a query result, not a complete physical forensic acquisition, log backup, original SQL transcript, or immutable audit trail. It does not establish that an identified login corresponds to a particular person.

The baseline full backup precedes the simulated incident. This lab intentionally does not take the later log backups or perform the separate-target restore needed for a `STOPBEFOREMARK` recovery exercise; investigation and restoration are separate steps in [Paul Randal's example](https://www.sqlskills.com/blogs/paul/using-fn_dblog-fn_dump_dblog-and-restoring-with-stopbeforemark-to-an-lsn/).

## Troubleshooting and cleanup

- **Backup failure:** Check the server-side path, free space, and SQL Server service-account write permissions. The file is not written to the computer running SSMS unless that computer is also the database server.
- **Existing database:** Inspect it first. Use the commented cleanup block or its standalone copy only when you intend to delete that disposable lab.
- **Missing transaction or boundary assertion:** Inspect `dbo.LogEvidence`, job history, and the exact SQL Server build. Do not silently skip assertions or declare the result complete.
- **Unsupported-function schema error:** Retain the error and build information. An undocumented output interface may require adapting the example for that build.
- **Forced cleanup:** After confirmation and marker checks, cleanup switches the lab database to `SINGLE_USER WITH ROLLBACK IMMEDIATE` and drops it in the same batch. This disconnects sessions and rolls back incomplete transactions; disabling asynchronous statistics first avoids a background connection contending for single-user access, as described in [Microsoft's single-user-mode guidance](https://learn.microsoft.com/en-us/sql/relational-databases/databases/set-a-database-to-single-user-mode).
- **Cleanup fails after switching access mode:** The lab may remain in single-user mode. Stop reconnecting tools or jobs and inspect the error before retrying; do not run this cleanup against any other database.
- **Backup file left behind:** Cleanup drops the database only. Record the `.bak` path and remove the backup manually when it is no longer wanted.
- **Missing marker after an early setup failure:** Cleanup refuses automatic deletion. Verify ownership and contents before any manual removal.

