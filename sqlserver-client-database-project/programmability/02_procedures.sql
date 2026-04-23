/*==============================================================*/
/* SCRIPT 05 - STORED PROCEDURES                                            */
/*==============================================================*



-- CREATING FIRST STORED PROCEDURE

CREATE PROCEDURE ProductList
AS
BEGIN
   SELECT TOP (1000) [Id]
      ,[ProductName]
      ,[SupplierId]
      ,[UnitPrice]
      ,[Package]
      ,[IsDiscontinued]
  FROM [CLIENT].[dbo].[Product]
  ORDER BY [ProductName] DESC
END;

-- VERIFY THE CREATED STORED PROCEDURE IN SSMS


-- EXECUTING THE CREATED STORED PROCEDURE

EXECUTE ProductList;

-- OR

EXEC ProductList;


-- MODIFYING THE STORED PROCEDURE

ALTER PROCEDURE ProductList
    AS
    BEGIN
       SELECT TOP (1000) [Id]
          ,[ProductName]
          ,[SupplierId]
          ,[UnitPrice]
      FROM [CLIENT].[dbo].[Product]
      ORDER BY [ProductName] ASC
    END;

-- EXECUTE AGAIN AND SEE THE RESULT
EXEC ProductList;


CREATE OR ALTER PROCEDURE ProductList
    AS
    BEGIN
       SELECT TOP (1000) [Id]
          ,[ProductName]
          ,[UnitPrice]
      FROM [CLIENT].[dbo].[Product]   
    END;

EXEC ProductList;

-- DELETING STORED PROCEDURE

DROP PROCEDURE ProductList;

-- OR

DROP PROC ProductList;


-- Parameters in Stored Procedures

CREATE OR ALTER PROCEDURE ProductList
    AS
    BEGIN
       SELECT [Id]
          ,[ProductName]
          ,[UnitPrice]
      FROM [CLIENT].[dbo].[Product]   
      ORDER BY [UnitPrice] DESC
    END;

EXEC ProductList;

-- Passing a Parameter to the Stored Procedure

ALTER PROCEDURE ProductList (@max_listprice AS DECIMAL)
AS
BEGIN
    SELECT [Id]
          ,[ProductName]
          ,[UnitPrice]
    FROM [CLIENT].[dbo].[Product]  
    WHERE
        [UnitPrice] <= @max_listprice
    ORDER BY
       UnitPrice;
END;

EXEC ProductList 10;

-- Passing more than 1 Parameter to the Stored Procedure

ALTER PROCEDURE ProductList (@min_listprice AS DECIMAL, @max_listprice AS DECIMAL)
AS
BEGIN
    SELECT [Id]
          ,[ProductName]
          ,[UnitPrice]
    FROM [CLIENT].[dbo].[Product]  
    WHERE
         [UnitPrice] >= @min_listprice AND
         [UnitPrice] <= @max_listprice 
    ORDER BY
        UnitPrice;
END;

EXECUTE ProductList 10, 200; -- the order of the parameters passed is essential.

EXECUTE ProductList 12, 14;

-- Best practice for calling Stored Procedures. In this case, the order of the parameters passed does not matter.

EXECUTE ProductList 
    @min_listprice = 12, 
    @max_listprice = 15;

-- Modifying the Stored Procedure

ALTER PROCEDURE ProductList (@min_listprice AS DECIMAL, @max_listprice AS DECIMAL, @productname AS NVARCHAR(50))
AS
BEGIN
    SELECT [Id]
          ,[ProductName]
          ,[UnitPrice]
    FROM [CLIENT].[dbo].[Product]  
    WHERE
         ([UnitPrice] >= @min_listprice AND
         [UnitPrice] <= @max_listprice) AND
          ProductName LIKE '%' + @productname + '%'
    ORDER BY
        UnitPrice;
END;

EXECUTE ProductList 
    @min_listprice = 12, 
    @max_listprice = 15,
    @productname = 'hok';

-- Creating optional parameters

-- When executing the ProductList Stored Procedure, you must pass all three arguments corresponding to the three parameters.
-- SQL Server allows you to specify default values for parameters so that when calling the SP (Stored Procedure),
-- you can omit parameters that have default values.

ALTER PROCEDURE ProductList (@min_listprice AS DECIMAL = 0, @max_listprice AS DECIMAL = 999999, @productname AS NVARCHAR(50))
AS
BEGIN
    SELECT [Id]
          ,[ProductName]
          ,[UnitPrice]
    FROM [CLIENT].[dbo].[Product]  
    WHERE
         ([UnitPrice] >= @min_listprice AND
         [UnitPrice] <= @max_listprice) AND
          ProductName LIKE '%' + @productname + '%'
    ORDER BY
        UnitPrice;
END;

EXECUTE ProductList 
    @min_listprice = 12, 
    @max_listprice = 15,
    @productname = 'hok';

EXECUTE ProductList 
    @productname = 'chef';

EXECUTE ProductList @min_listprice = 70, @productname = 'a';


-- Using NULL as optional parameters. Most commonly used approach, because if products with values greater than 999999 ever exist,
-- you would have to modify the stored procedure.

ALTER PROCEDURE ProductList (@min_listprice AS DECIMAL = 0, @max_listprice AS DECIMAL = NULL, @productname AS NVARCHAR(50))
AS
BEGIN
    SELECT [Id]
          ,[ProductName]
          ,[UnitPrice]
    FROM [CLIENT].[dbo].[Product]  
    WHERE
         [UnitPrice] >= @min_listprice AND
         (@max_listprice IS NULL OR [UnitPrice] <= @max_listprice) AND
          ProductName LIKE '%' + @productname + '%'
    ORDER BY
        UnitPrice;
END;


EXECUTE ProductList @min_listprice = 70, @productname = 'a';

EXECUTE ProductList @min_listprice = 70, @max_listprice = 124, @productname = 'a';


-- DECLARING VARIABLES. By default, when a variable is declared, its value is NULL

DECLARE @orderyear SMALLINT
SET @orderyear = 2013 -- ASSIGNING VALUES TO VARIABLES.

SELECT TOP (1000) [Id]
      ,[OrderDate]
      ,[OrderNumber]
      ,[CustomerId]
      ,[TotalAmount]
  FROM [CLIENT].[dbo].[Order]
  WHERE YEAR([OrderDate]) = @orderyear


-- Storing the result of a query in a variable

DECLARE @suppliercount INT

SET @suppliercount = (
    SELECT 
        COUNT(*) 
    FROM 
        supplier
)

SELECT @suppliercount; -- displaying the value stored in the variable @suppliercount

PRINT 'The number of suppliers is ' + CAST(@suppliercount AS VARCHAR(50)); -- Printing the content of a variable

-- Click on Messages tab to check the output of the Print command
-- To hide the "rows affected" message: SET NOCOUNT ON;

SET NOCOUNT ON;  
DECLARE @suppliercount INT
SET @suppliercount = (
    SELECT 
        COUNT(*) 
    FROM 
        supplier
)
SELECT @suppliercount; -- displaying the value stored in the variable @suppliercount
PRINT 'The number of suppliers is ' + CAST(@suppliercount AS VARCHAR(50)); -- Printing the content of a variable
SET NOCOUNT OFF;

-- Storing values in variables

SELECT * FROM Product

DECLARE 
    @productname NVARCHAR(50),
    @listprice DECIMAL(10,2);

SELECT  @productname = [ProductName]
      , @listprice   = [UnitPrice]
    FROM [CLIENT].[dbo].[Product]  
    WHERE
        id = 1;
 
SELECT @productname AS [Product Name];
SELECT @listprice   AS [Unit Price];


-- NOTE: if you remove the WHERE clause, no error will occur, but it will return the data from the last record

-- Accumulating values in variables

DECLARE 
    @productname NVARCHAR(50),
    @listprice DECIMAL(10,2),
    @allproducts VARCHAR(MAX); -- 2GB of storage, with about 1 billion characters due to unicode which uses 2 bytes per stored character

SET @allproducts = '';

SELECT @allproducts = @allproducts + [ProductName] + CHAR(10)
    FROM [CLIENT].[dbo].[Product];
   
SELECT @allproducts AS [All Product Names];
--PRINT @allproducts


-- Output Parameters

-- The following SP (Stored Procedure) finds products by unit price and returns
-- the number of products through the output parameter @productcount which has the OUTPUT keyword:

CREATE PROCEDURE FindProductByPrice (
    @unitprice SMALLINT,
    @productcount INT OUTPUT
) AS
BEGIN
    SELECT 
        productname,
        unitprice
    FROM
        product
    WHERE
        unitprice = @unitprice;

    SELECT @productcount = @@ROWCOUNT; -- @@ROWCOUNT is a system variable that returns the number of rows read 
END;

-- CALLING THE SP, passing parameter @unitprice = 18

DECLARE @count INT;

EXEC FindProductByPrice
    @unitprice = 18,
    @productcount = @count OUTPUT;

SELECT @count AS 'Number of Products Found';


-- ELSE IF

DECLARE @totalsales INT;

SELECT 
    @totalsales = SUM(unitprice * quantity)
FROM
    orderitem i
INNER JOIN [Order] oo ON oo.id = i.OrderId
WHERE
    YEAR(oo.orderdate) = 2012;

SELECT @totalsales;

IF @totalsales > 10000
BEGIN
    PRINT '2012 sales are greater than 10000';
END
ELSE
BEGIN
    PRINT '2012 sales are not greater than 10000';
END


-- WHILE

DECLARE @counter INT = 1;

WHILE @counter <= 5
BEGIN
    PRINT @counter;
    SET @counter = @counter + 1;
END

-- BREAK

DECLARE @counter INT = 0;

WHILE @counter <= 5
BEGIN
    SET @counter = @counter + 1;
    IF @counter = 4
        BREAK;
    PRINT @counter;
END


-- SQL Server Dynamic SQL
-- example 1

DECLARE 
    @tablename NVARCHAR(128),
    @sql NVARCHAR(MAX);

SET @tablename = N'product';

SET @sql = N'SELECT * FROM ' + @tablename;

EXEC sp_executesql @sql;


-- example 2

CREATE OR ALTER PROC QueryTopX(
    @tablename NVARCHAR(128),
    @topx INT,
    @byColumn NVARCHAR(128)
)
AS
BEGIN
    DECLARE 
        @sql NVARCHAR(MAX),
        @topxStr NVARCHAR(MAX);

    SET @topxStr = CAST(@topx AS NVARCHAR(MAX));

    SET @sql = N'SELECT TOP ' + @topxStr + 
                ' * FROM ' + @tablename + 
                ' ORDER BY ' + @byColumn + ' DESC';
    
    EXEC sp_executesql @sql;
    
END;

-- Calling the procedure passing parameters

EXEC QueryTopX 
    'product',
    10, 
    'unitprice';

EXEC QueryTopX 
    'customer',
    10, 
    'FirstName';


-- SQL Injection

-- Let's create a test table
CREATE TABLE SalesTest (id INT); 

-- Create SP
CREATE OR ALTER PROCEDURE SpSales (@tablename NCHAR(250))
AS
DECLARE @sql NCHAR(250)
SET @sql = 'SELECT * FROM ' + @tablename
EXEC sp_executesql @sql;

-- Execute SP
EXEC SpSales 'customer'

-- Intercepting the SP call and modifying it
EXEC SpSales 'customer;DROP TABLE SalesTest'

-- Check what happened to the table.


-- To prevent SQL injection, you can use the QUOTENAME() function as shown in the following query:
-- https://docs.microsoft.com/en-us/sql/t-sql/functions/quotename-transact-sql?view=sql-server-ver15

CREATE OR ALTER PROCEDURE SpSales (@schema NVARCHAR(128), @tablename NVARCHAR(128))
AS
DECLARE @sql NCHAR(128)
SET @sql = N'SELECT * FROM ' 
            + QUOTENAME(@schema) 
            + '.' 
            + QUOTENAME(@tablename);

EXEC sp_executesql @sql;

EXEC SpSales 'dbo', 'customer'

EXEC SpSales 'dbo', 'customer;DROP TABLE SalesTest'

-- More information and techniques to prevent SQL injection: https://docs.microsoft.com/en-us/sql/relational-databases/security/sql-injection?view=sql-server-ver15


-- TRY CATCH

CREATE PROC usp_divide(
    @a DECIMAL,
    @b DECIMAL,
    @result DECIMAL OUTPUT
) AS
BEGIN
    BEGIN TRY
        SET @result = @a / @b;
    END TRY
    BEGIN CATCH
        SELECT  
            ERROR_NUMBER()     AS ErrorNumber  
            ,ERROR_SEVERITY()  AS ErrorSeverity  
            ,ERROR_STATE()     AS ErrorState  
            ,ERROR_PROCEDURE() AS ErrorProcedure  
            ,ERROR_LINE()      AS ErrorLine  
            ,ERROR_MESSAGE()   AS ErrorMessage;  
    END CATCH
END;
GO

-- Calling the SP

DECLARE @result DECIMAL;
EXEC usp_divide 10, 2, @result OUTPUT;
PRINT @result;

DECLARE @result DECIMAL;
EXEC usp_divide 10, 0, @result OUTPUT;
PRINT @result;
