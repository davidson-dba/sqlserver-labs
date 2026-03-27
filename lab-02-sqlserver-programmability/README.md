This repository contains a complete hands-on SQL Server lab designed to simulate a real database environment and demonstrate practical DBA and Database Developer skills.

The lab covers the full lifecycle of a database:

- Database creation
- Schema design and relationships
- Seed data loading
- Queries and DML operations
- Programmability objects (views, functions, procedures and triggers)

---

# 🧰 Environment

- SQL Server Developer Edition  
- SQL Server Management Studio (SSMS)

---

# 🗂 Repository Structure


database/
dml-dql/
programmability/
images/


---

# ▶️ Step 1 — Database Creation

Script:

database/01_create_database.sql


Creates the database and prepares the environment.

### Evidence to capture
Screenshot of the database visible in Object Explorer.


images/01_database_created.png


---

# ▶️ Step 2 — Schema Creation (Tables & Relationships)

Script:

database/02_create_tables.sql


Tables created:

- Customer
- Supplier
- Product
- Order
- OrderItem

Includes:
- Primary Keys
- Foreign Keys
- Relationships between entities

### Evidence to capture
Screenshot of tables created.


images/02_tables_created.png


---

# ▶️ Step 3 — Seed Data (Test Dataset)

Script:

database/03_seed_data.sql


Populates the database with sample data used for queries and testing.

### Evidence to capture
 SELECT COUNT(*) FROM Customer
images/03_seed_data.png

#▶️ Step 4 — Queries and DML Practice

Script:

dml-dql/01_queries_and_dml.sql

This section demonstrates core SQL querying and data manipulation:

Queries (DQL)
SELECT statements
WHERE, IN, LIKE, BETWEEN
ORDER BY
DISTINCT
Aggregations (COUNT, SUM, AVG, MIN, MAX)
GROUP BY and HAVING
INNER JOIN, LEFT JOIN, RIGHT JOIN
UNION
Subqueries and EXISTS
Data Manipulation (DML)
INSERT
UPDATE
DELETE
Transactions (BEGIN TRAN / COMMIT / ROLLBACK)
Evidence to capture'''

Screenshot of complex JOIN query execution.

images/04_query_example.png
# ▶️ Step 5 — Views

Script:

programmability/01_views.sql

Implemented:

Creating views
Filtering data via views
INSERT and DELETE using views
Complex JOIN + aggregation views
ALTER and DROP views
Evidence
images/05_view_example.png
# ▶️ Step 6 — Stored Procedures

Script:

programmability/02_procedures.sql

Implemented:

Creating and altering procedures
Input and output parameters
Optional parameters
Variables and control flow (IF / WHILE)
Dynamic SQL
SQL Injection mitigation
TRY/CATCH error handling
Evidence
images/06_procedure_example.png
# ▶️ Step 7 — Triggers and Auditing

Script:

programmability/03_triggers.sql

Implemented:

Audit table creation
DML triggers (INSERT / DELETE logging)
Enabling and disabling triggers
LOGON trigger example
Querying active sessions

This step simulates a real auditing scenario.

Evidence
images/07_trigger_example.png
# ▶️ Step 8 — Functions and Temporary Objects

Script:

programmability/04_functions.sql

Implemented:

Scalar functions
Table-valued functions
Table variables
Local and global temporary tables (# / ##)
Temporary stored procedures
🎯 Skills Demonstrated

By completing this lab, the following skills were practiced:

Database design and relationships
SQL querying and data manipulation
Transactions and error handling
Automation with stored procedures
Auditing with triggers
Reusable logic with functions and views
tempdb and temporary objects usage
🚀 Purpose

This project is part of my SQL Server and Azure certification preparation and demonstrates hands-on DBA skills using GitHub for version control.
