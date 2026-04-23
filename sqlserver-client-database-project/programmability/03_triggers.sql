/*==============================================================
TRIGGER
Triggers are special stored procedures executed automatically
in response to database object events (INSERT, UPDATE, and DELETE on tables),
database events, and server events.
==============================================================*/

-- Example of trigger creation. We will create a table to serve as a log
-- to store all transactions performed on a product table.

-- CREATING THE TABLE THAT WILL STORE TRANSACTION DATA FROM THE PRODUCT TABLE

USE CLIENTES
GO

IF EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[product_audit]') AND type in (N'U'))
DROP TABLE [dbo].[product_audit]
GO

CREATE TABLE product_audit (
    id              INT IDENTITY PRIMARY KEY,
    productid       INT NOT NULL,
    productname     NVARCHAR(50) NOT NULL,
    SupplierId      INT NOT NULL,
    UnitPrice       DECIMAL(12,2) NOT NULL,
    package         NVARCHAR(30) NOT NULL,
    IsDiscontinued  BIT NOT NULL,
    updatedat       DATETIME NOT NULL,
    operation       CHAR(3) NOT NULL,
    CHECK (operation = 'INS' OR operation = 'DEL')
);


-- CREATING THE TRIGGER ON THE PRODUCT TABLE

CREATE TRIGGER [dbo].[trg_product_audit]
ON [dbo].[Product]
AFTER INSERT, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO product_audit (
        productid,
        productname,
        SupplierId,
        UnitPrice,
        package,
        IsDiscontinued,
        updatedat,
        operation
    )
    SELECT
        i.id,
        productname,
        SupplierId,
        UnitPrice,
        package,
        IsDiscontinued,
        GETDATE(),
        'INS'
    FROM
        inserted i
    UNION ALL
    SELECT
        d.id,
        productname,
        SupplierId,
        UnitPrice,
        package,
        IsDiscontinued,
        GETDATE(),
        'DEL'
    FROM
        deleted d;
END
GO

ALTER TABLE [dbo].[Product] ENABLE TRIGGER [trg_product_audit]
GO


-- Verifying the trigger in SQL Server

-- Testing the trigger

INSERT INTO product (
        productname,
        SupplierId,
        UnitPrice,
        package,
        IsDiscontinued)
VALUES (
    'PRODUCT X',
    1,
    1240,
    1,
    0);

-- Checking the audit log table

SELECT
    *
FROM
    product_audit;


-- Now let's test product deletion and see what happens

SELECT * FROM product WHERE productname = 'PRODUCT X'

DELETE FROM
    product
WHERE
    id = 79;


-- Checking the audit log table

SELECT
    *
FROM
    product_audit;


-- IT IS POSSIBLE TO CREATE TRIGGERS TO LOG PROCESSES FOR COMMANDS SUCH AS CREATE TABLE, ALTER VIEW,
-- DROP INDEX, GRANT, DENY, REVOKE, or UPDATE STATISTICS.
-- THE EXAMPLE BELOW SHOWS THIS, BUT FOR AUDITING PURPOSES, A DEDICATED AUDIT RESOURCE IS MORE APPROPRIATE
-- AND WILL BE COVERED LATER IN THE COURSE.

CREATE TRIGGER trigger_name
ON { DATABASE | ALL SERVER }
[WITH ddl_trigger_option]
FOR { event_type | event_group }
AS { sql_statement }

CREATE TRIGGER trg_index_changes
ON DATABASE
FOR
    CREATE_INDEX,
    ALTER_INDEX,
    DROP_INDEX
AS
BEGIN


-- Sometimes you need to temporarily disable a trigger via script or via SSMS
-- by right-clicking on the trigger and selecting Disable.

DISABLE TRIGGER [trg_product_audit]
ON product;

INSERT INTO product (
        productname,
        SupplierId,
        UnitPrice,
        package,
        IsDiscontinued)
VALUES (
    'PRODUCT Y',
    1,
    1240,
    1,
    0);

-- Checking the audit log table

SELECT
    *
FROM
    product_audit;


-- Re-enabling the trigger

ENABLE TRIGGER [trg_product_audit]
ON product;

INSERT INTO product (
        productname,
        SupplierId,
        UnitPrice,
        package,
        IsDiscontinued)
VALUES (
    'PRODUCT Y',
    1,
    1240,
    1,
    0);

-- Checking the audit log table

SELECT
    *
FROM
    product_audit;


-- If there are multiple triggers on a table, you can disable or enable all of them at once.

DISABLE TRIGGER ALL ON PRODUCT;

ENABLE TRIGGER ALL ON PRODUCT;


-- To list all triggers that exist in a database

USE CLIENTES
GO
SELECT
    *
FROM
    sys.triggers
WHERE
    type = 'TR';

-- To drop a trigger

DROP TRIGGER IF EXISTS trg_product_audit;


/*===============================================================================================
You can use TRIGGERS to control logons, for example by inserting records into tables
to track login activity, and even restrict logons to SQL Server or limit the number of sessions
for a specific login, restrict access from a specific client or during a certain time period.
===============================================================================================*/

-- Example: restrict the SA account so it can only connect from within the server itself.
-- Create this trigger and try to connect with the SA account from inside and outside the server.

CREATE OR ALTER TRIGGER user_audit ON ALL SERVER
    FOR LOGON
    AS
        BEGIN
            IF (ORIGINAL_LOGIN() = 'sa') AND HOST_NAME() = 'DBSRV1'  -- if connecting as SA from within the server, access will be denied
            --IF (ORIGINAL_LOGIN() = 'sa') AND HOST_NAME() <> 'DBSRV1' -- or the opposite: deny from outside
                --IF (ORIGINAL_LOGIN() = 'sa') AND APP_NAME() LIKE 'Microsoft SQL Server Management%'
                -- or prevent SA from connecting via SSMS, allowing access only through the application.
                -- You could also apply this to any user that should not connect through SSMS.
                BEGIN
                    ROLLBACK;
                END;
        END;


-- CHECK WHICH SESSIONS ARE CURRENTLY ACTIVE

SELECT is_user_process, original_login_name, *
FROM sys.dm_exec_sessions
WHERE is_user_process = 1
ORDER BY login_time DESC
GO

-- CHECK WHO IS LOGGED IN WITH AN ACTIVE SESSION AND OTHER DATA THAT CAN BE USED IN LOGON TRIGGERS

SELECT
    SUSER_SNAME()    AS username,
    APP_NAME()       AS appname,
    HOST_NAME()      AS hostname,
    @@SPID           AS spid,
    GETDATE()        AS datetimetoday,
    SESSION_USER     AS sessionuser,
    ORIGINAL_LOGIN() AS originallogin

-- NOTE: ALWAYS CAPTURE ORIGINAL_LOGIN() IN AUDITS, because other users can execute commands
-- impersonating another user, which could cause an innocent user to be wrongly accused of
-- executing a command that was actually run under their credentials by someone else.
-- Be careful when granting db_owner rights to a database or to a service account used by an
-- application, especially if its password is known.
-- By default, SQL Server's native audit already records ORIGINAL_LOGIN in the
-- session_server_principal_name field of sys.fn_get_audit_file. When audit output is written
-- to a file, you can query it with SELECT to review what has been audited.
-- Auditing will be covered in more detail later in the course.

-- As a good security practice, disable or rename the SA account, as it is well known to hackers.
-- If you disable it, make sure at least one other login with sysadmin privileges exists to manage
-- the instance. If the SA password is lost or the account is disabled and no sysadmin login exists
-- inside the SQL Server instance, you will need to manually create a sysadmin account or re-enable
-- SA and set a new password. Search online — there are several blog posts explaining how to do this.

-- DISABLING AND DROPPING THE LOGON TRIGGER

DISABLE TRIGGER user_audit ON ALL SERVER;
DROP TRIGGER user_audit ON ALL SERVER;
