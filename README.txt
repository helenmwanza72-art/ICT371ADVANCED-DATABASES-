ICT371 Advanced Database - GitHub-ready SQL answers

Files:
- Question_01_Pharmacy.sql through Question_10_Scholarship.sql

Each file contains the complete answer for its corresponding question, numbered (a) through (g), including table creation, sample data, functions, procedures, triggers, views, indexes, scheduled-job definitions, and verification queries.

How to use:
1. Open pgAdmin and connect to your PostgreSQL database.
2. Open one SQL file in Query Tool.
3. Execute one question file at a time.
4. The scripts create separate schemas q1_pharmacy through q10_scholarship to prevent object-name conflicts.

Important scheduling note:
The scheduled-job sections use pg_cron. The extension must be installed on the PostgreSQL server and enabled by an administrator. If pg_cron is unavailable, execute the procedure manually using the CALL statement shown in the relevant script. EXPLAIN plans depend on table size and planner statistics; PostgreSQL may choose a sequential scan for small sample tables even when an index is correctly created.
