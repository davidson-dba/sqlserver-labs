/*==============================================================*/
/* SCRIPT 04 - PROGRAMABILLITY - VIEWS                                                        */
/*                                        */
/*==============================================================*/

/*


A VIEW is a saved query in the database that behaves like a virtual table.
It does not store data physically — it only displays data from base tables.

Main advantages:

Simplifies complex queries
Improves security (expose only part of the data)
Reuse queries
Hide joins and calculations

Creating a simple view

CREATE VIEW vw_customerSP
AS
SELECT
    *
FROM
customer where city ='São Paulo'

---usage view 

select * from vw_customerSP

-- You can still apply filters:
select   *
FROM vw_customerSP
where phone like '%334%'


-- Inserting data through the view 
insert into vw_customerSP (firstname, lastname, city, country, phone)
values ('Joao', 'Carvalho', 'São Paulo', 'Brazil', '(11)5555-5555')

insert into vw_customerSP (firstname, lastname, city, country, phone)
values ('Jose', 'Martinez', 'Tijuana', 'México', '(55) 9999-5555')

select * from vw_customerSP

SELECT * FROM customer where lastname = 'Martinez'


---This removes rows from the base table.
--- Works properly only when the view is based on a single table.

delete from vw_customerSP where lastname = 'Martinez' and 'Carvalho'

SELECT * FROM vw_customerSP where lastname = 'Martinez'
SELECT * FROM customer where lastname = 'Martinez'

BEGIN TRAN
delete from vw_customerSP
where phone like '%555%'


-- Creating a view with JOIN (analytical view)

CREATE VIEW salesday
AS
SELECT
    year(orderdate) AS y,
    month(orderdate) AS m,
    day(orderdate) AS d,
    p.id,
    productname,
    quantity * i.unitprice AS sales
FROM
    [Order] AS o
INNER JOIN orderitem AS i
    ON o.id = i.orderid
INNER JOIN product AS p
    ON p.id = i.productid;

after create View, execute: 

SELECT *  FROM salesday ORDER BY y, m, d, sales desc;

--- Using the view for analytics

select y as ano, m as mes, sum(sales) as VendasMes
	from salesday
	group by y, m
	order by ano asc, mes asc

select y as ano, avg(sales) as VendasmediaANO
	from salesday
	group by y
	order by ano asc


-- ALTER VIEW INSERTING CUSTOMER DATA

CREATE OR ALTER VIEW salesday
AS
SELECT
    year(orderdate) AS y,
    month(orderdate) AS m,
    day(orderdate) AS d,
    p.id,
    productname,
    quantity * i.unitprice AS sales,
    c.FIRSTNAME, 
    c.LASTNAME
FROM
    [Order] AS o
INNER JOIN customer as c
    ON c.id = o.customerid 
INNER JOIN orderitem AS i
    ON o.id = i.orderid
INNER JOIN product AS p
    ON p.id = i.productid;

SELECT *  FROM salesday ORDER BY y, m, d, sales desc;

SELECT top 5 FirstName + ' ' + LastName , sum(d.sales) FROM salesday d
group by d.FirstName, d.LastName



DELETE DATA DIRECTLY FROM THE VIEW

delete from salesday
truncate table salesday

/*These do not work.

Why:

Views with JOIN are usually not updatable
TRUNCATE cannot be used on views
DELETE is limited or not allowed*/



-- Dropping the view

DROP VIEW salesday


