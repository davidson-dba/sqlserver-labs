/*==============================================================
FUNCTIONS
Functions help simplify your code. For example, you may have
a complex calculation that appears in many queries.
Instead of including the formula in each query, you can create
a function that encapsulates the formula and reuse it across queries.
==============================================================*/

-- This function will be used to support other stored procedures.
-- Based on the parameters provided — product quantity, unit price,
-- and discount percentage — the function will return the discounted price for a product.

CREATE FUNCTION FuncDiscount(
    @qty          INT,
    @unit_price   DEC(10,2),
    @discount     DEC(4,2)
)
RETURNS DEC(10,2)
AS
BEGIN
    RETURN @qty * @unit_price * (1 - @discount);
END;

-- In SSMS, navigate to the database where you created the function (in this case, the CLIENTES database),
-- go to Programmability > Functions > Scalar-Valued Functions to confirm FuncDiscount was created.
-- You can right-click the function and select Modify to edit it.

-- Calling the function with parameters
SELECT dbo.FuncDiscount(10, 100, 0.1) AS sale_value

-- This next example shows how to use the function to assist in a SQL query
SELECT
    id,
    SUM(dbo.FuncDiscount(Quantity, unitprice, 0.1)) AS final_sale_value
FROM
    orderitem
GROUP BY
    id
ORDER BY
    final_sale_value DESC;


/*============================================================================================================================
TABLE VARIABLES
- Reside in the tempdb database, not in memory.
- Table variables are a type of variable that allow you to hold data, similar to temporary tables.
- Like local variables, table variables are cleared at the end of the job or process that uses them.
- Statistics help the SQL Server query optimizer produce a good execution plan. Unfortunately,
  table variables do not contain statistics. Therefore, you should use table variables
  to hold a small number of rows.
============================================================================================================================*/

DECLARE @product_table TABLE (
    productname   VARCHAR(MAX) NOT NULL,
    id            INT NOT NULL,
    unit_price    DEC(11,2) NOT NULL
);

INSERT INTO @product_table
SELECT
    productname,
    id,
    unitprice
FROM
    product
WHERE
    [IsDiscontinued] = 0;

SELECT
    *
FROM
    @product_table;
GO


/*============================================================================================================================
TABLE VARIABLES IN FUNCTIONS
Using table variables inside user-defined functions
============================================================================================================================*/

-- Creates a function that receives a discontinued flag parameter and returns matching products.
-- The result is used to populate a table variable called @discontinued_products.

CREATE OR ALTER FUNCTION fn_get_products_by_status(
    @is_discontinued BIT)
RETURNS @discontinued_products TABLE
(
    id           INT PRIMARY KEY,
    product_name NVARCHAR(50)
)
AS
BEGIN

    INSERT INTO @discontinued_products (id, product_name)
    SELECT id, productname
    FROM product
    WHERE IsDiscontinued = @is_discontinued;

    RETURN;
END
GO

-- Calling the function with the parameter

SELECT * FROM dbo.fn_get_products_by_status(1); -- discontinued products

SELECT * FROM dbo.fn_get_products_by_status(0); -- active products

-- In SSMS, navigate to the database where you created the function (in this case, the CLIENTES database),
-- go to Programmability > Functions > Table-Valued Functions.
-- You can right-click the function and select Modify to edit it.

-- To drop a function
DROP FUNCTION IF EXISTS fn_get_products_by_status;


/*============================================================================================================================
TEMPORARY #TABLE
- Reside in the tempdb database, not in memory.
- Similar to table variables in that they allow you to hold data temporarily.
- Temporary tables are cleared at the end of the session in which they were created.
- They can be local (visible only within the same session of the user who created them) or global.
- Temporary tables contain statistics, which help the SQL Server query optimizer produce better
  execution plans. Therefore, temporary tables should be used for larger datasets and offer
  better performance than table variables. Non-clustered indexes can be created on temporary tables.
============================================================================================================================*/

-- Creating a local temporary table

CREATE TABLE #temp_products_local (
    product_name VARCHAR(MAX),
    list_price   DEC(10,2)
);

INSERT INTO #temp_products_local
SELECT
    productname,
    unitprice
FROM
    product;

SELECT * FROM #temp_products_local;

-- Open a new query window and run: SELECT * FROM #temp_products_local
-- Then return to the original window and run it again — notice the scope difference.


-- Now do the same with a global temporary table

CREATE TABLE ##temp_products_global (
    product_name VARCHAR(MAX),
    list_price   DEC(10,2)
);

INSERT INTO ##temp_products_global
SELECT
    productname,
    unitprice
FROM
    product;

SELECT * FROM ##temp_products_global;

-- Go to tempdb > Temporary Tables in SSMS to verify both tables were created.

-- To drop the global temporary table
DROP TABLE ##temp_products_global;


-- To create a temporary stored procedure

CREATE PROCEDURE #proc_local_temp AS
    SELECT 'Hello, I am a temporary stored procedure' AS message;

EXEC #proc_local_temp;
