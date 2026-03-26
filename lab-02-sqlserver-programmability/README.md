📌 SQL Server Lab — Programmability Objects

This lab demonstrates the creation and usage of SQL Server programmability objects, including:

Views
Stored Procedures
Triggers
Functions
Temporary tables and table variables

The goal is to practice database automation, auditing and reusable logic.

🧰 Environment
SQL Server Developer Edition
SQL Server Management Studio (SSMS)
Sample database used in course (CLIENTES)
▶️ Step 1 — Working with Views

script 1: scripts/01_views.sql
What is implemented

✔ Creation of views
✔ Filtering data using views
✔ Insert and delete through views
✔ Complex view with JOINs and aggregations
✔ Altering and dropping views

Evidence to capture (prints)

Take screenshots of:

View created in Object Explorer
SELECT * FROM vw_custumerMadrid
SELECT * FROM dailysales

Save inside /images folder.

▶️ Step 2 — Stored Procedures

Script2: scripts/02_stored_procedures.sql
What is implemented

✔ Creating stored procedures
✔ Altering and dropping procedures
✔ Input parameters
✔ Output parameters
✔ Optional parameters
✔ Variables and control flow (IF / WHILE)
✔ Dynamic SQL
✔ SQL Injection demonstration and mitigation
✔ TRY/CATCH error handling

Evidence to capture

Take screenshots of:

Executing EXEC ProductList
Procedure created under Programmability → Stored Procedures
TRY/CATCH error output
▶️ Step 3 — Triggers and Auditing

Script3: scripts/03_triggers.sql
What is implemented

✔ Audit table creation
✔ DML Trigger (INSERT / DELETE logging)
✔ Enabling and disabling triggers
✔ Server LOGON trigger example
✔ Querying active sessions

This lab simulates real auditing scenario.

Evidence to capture

Screenshots:

Insert into Product table
Data recorded in produto_auditoria
Trigger visible in SSMS

This part is VERY relevant for DBA role.

▶️ Step 4 — Functions and Temporary Objects

Script 4: scripts/04_functions_temp_tables.sql
What is implemented

✔ Scalar functions
✔ Table-valued functions
✔ Table variables
✔ Temporary tables (# and ##)
✔ Temporary stored procedures

This demonstrates reusable logic and tempdb usage.

Evidence to capture

Screenshots:

Function execution result
Temp tables in tempdb
Query results using functions
✅ Lab Results

At the end of this lab we successfully practiced:

Reusable database logic
Automation with stored procedures
Auditing with triggers
Performance and temporary storage concepts

These are core skills for SQL Server DBA and Database Developer roles.
