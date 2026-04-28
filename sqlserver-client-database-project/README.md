# 🗄️ SQL Server Client Database Lab

This repository contains a complete hands-on SQL Server lab designed to simulate a real database environment and demonstrate practical DBA and Database Developer skills.

The lab covers the full lifecycle of a database:
- Database creation
- Schema design and relationships
- Seed data loading
- Queries and DML operations
- Programmability objects (views, functions, procedures and triggers)

---

## 🧰 Environment

- SQL Server Developer Edition
- SQL Server Management Studio (SSMS)

---

## 🗂️ Repository Structure
```
sqlserver-client-database-project/
├── database/
├── dml-dql/
├── programmability/
└── images/
```

---

## ▶️ Step 1 — Database, Tables & Relationships

**Script:** `database/01_create_database_and_tables.sql`

Creates the CLIENT database and all tables with their relationships.

Tables created:
- `Customer`
- `Supplier`
- `Product`
- `Order`
- `OrderItem`

Includes:
- Primary Keys
- Foreign Keys
- Relationships between entities

**Evidence**
Screenshot of the database and tables visible in Object Explorer.

![Database and Tables Created](https://github.com/davidson-dba/sqlserver-labs/tree/main/sqlserver-client-database-project/images/01_create_database_tables_created.png)

---

## ▶️ Step 2 — Seed Data (Test Dataset)

**Script:** `database/02_seed_data.sql`

Populates the database with sample data used for queries and testing.

**Evidence**
```sql
SELECT COUNT(*) FROM Customer
```

![Seed Data](images/02_seed_data.png)

---

## ▶️ Step 3 — Queries and DML Practice

**Script:** `dml-dql/01_queries_and_dml.sql`

**Queries (DQL)**
- `SELECT` statements
- `WHERE`, `IN`, `LIKE`, `BETWEEN`
- `ORDER BY`, `DISTINCT`
- Aggregations (`COUNT`, `SUM`, `AVG`, `MIN`, `MAX`)
- `GROUP BY` and `HAVING`
- `INNER JOIN`, `LEFT JOIN`, `RIGHT JOIN`
- `UNION`
- Subqueries and `EXISTS`

**Data Manipulation (DML)**
- `INSERT`, `UPDATE`, `DELETE`
- Transactions (`BEGIN TRAN` / `COMMIT` / `ROLLBACK`)

**Evidence**
Screenshot of complex JOIN query execution.

![Query Example](images/03_query_example.png)

---

## ▶️ Step 4 — Views

**Script:** `programmability/01_views.sql`

Implemented:
- Creating views
- Filtering data via views
- `INSERT` and `DELETE` using views
- Complex `JOIN` + aggregation views
- `ALTER` and `DROP` views

**Evidence**

![View Example](images/04_view_example.png)

---

## ▶️ Step 5 — Stored Procedures

**Script:** `programmability/02_procedures.sql`

Implemented:
- Creating and altering procedures
- Input and output parameters
- Optional parameters
- Variables and control flow (`IF` / `WHILE`)
- Dynamic SQL
- SQL Injection mitigation
- `TRY/CATCH` error handling

**Evidence**

![Procedure Example](images/05_procedure_example.png)

---

## ▶️ Step 6 — Triggers and Auditing

**Script:** `programmability/03_triggers.sql`

Implemented:
- Audit table creation
- DML triggers (`INSERT` / `DELETE` logging)
- Enabling and disabling triggers
- `LOGON` trigger example
- Querying active sessions

> This step simulates a real auditing scenario.

**Evidence**

![Trigger Example](images/06_trigger_example.png)

---

## ▶️ Step 7 — Functions and Temporary Objects

**Script:** `programmability/04_functions.sql`

Implemented:
- Scalar functions
- Table-valued functions
- Table variables
- Local and global temporary tables (`#` / `##`)
- Temporary stored procedures

**Evidence**

![Functions Example](images/07_functions_example.png)

---

## 🎯 Skills Demonstrated

- Database design and relationships
- SQL querying and data manipulation
- Transactions and error handling
- Automation with stored procedures
- Auditing with triggers
- Reusable logic with functions and views
- `tempdb` and temporary objects usage

---

## 🚀 Purpose

This project is part of my SQL Server and Azure certification preparation and demonstrates hands-on DBA skills using GitHub for version control.
