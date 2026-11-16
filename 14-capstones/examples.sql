-- Module 14 worked examples: the patterns used by all four capstone projects.
-- Run:  psql -d cte_lab -f 14-capstones/examples.sql
-- Everything happens inside BEGIN ... ROLLBACK, so the practice data is never changed.

CREATE OR REPLACE FUNCTION pg_temp.try_sql(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION
    WHEN query_canceled THEN RETURN 'CANCELED: ' || SQLERRM;
    WHEN OTHERS         THEN RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- =====================================================================
-- Pattern 1: the SELF-CHECK table. A deliverable proves its own correctness: for every claim, an expected value
-- (computed independently) beside the actual value, and a passed flag. Here the last check fails on purpose.
-- =====================================================================
WITH checks(ord, check_name, expected, actual) AS (
    VALUES
    (1, 'two plus two',                   '4',  (2 + 2)::text),
    (2, 'customers in the practice data', '30', (SELECT COUNT(*) FROM customers)::text),
    (3, 'a deliberately failing check',   '31', (SELECT COUNT(*) FROM customers)::text)
)
SELECT check_name, expected, actual, (expected = actual) AS passed
FROM checks
ORDER BY ord;

BEGIN;

-- =====================================================================
-- Pattern 2: make failure LOUD. A view of checks plus an assertion that raises an error if any check fails.
-- In CI (or a scheduled job) this turns a silent wrong number into a visible failure.
-- =====================================================================
CREATE TEMP VIEW demo_checks AS
SELECT ord, check_name, expected, actual, (expected = actual) AS passed
FROM (VALUES (1, 'customers', '30',  (SELECT COUNT(*) FROM customers)::text),
             (2, 'orders',    '121', (SELECT COUNT(*) FROM orders)::text)) c(ord, check_name, expected, actual);

CREATE FUNCTION pg_temp.assert_checks(v regclass) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE failed text;
BEGIN
    EXECUTE format('SELECT string_agg(check_name, ''; '' ORDER BY ord) FROM %s WHERE NOT passed', v) INTO failed;
    IF failed IS NOT NULL THEN
        RAISE EXCEPTION 'failed checks: %', failed;
    END IF;
END $$;

SELECT pg_temp.try_sql($q$ SELECT pg_temp.assert_checks('demo_checks') $q$) AS assertion_result;   -- P0001 = raise_exception

-- =====================================================================
-- Pattern 3: a SCHEMA per project, documented with COMMENTs, and a data dictionary generated from the catalog.
-- =====================================================================
CREATE SCHEMA demo;
COMMENT ON SCHEMA demo IS 'Throw-away demonstration schema.';
CREATE TABLE demo.customer_summary AS
SELECT c.customer_id AS customer_key, c.customer_name, c.country, COUNT(o.order_id) AS orders
FROM customers c LEFT JOIN orders o ON o.customer_id = c.customer_id
GROUP BY c.customer_id, c.customer_name, c.country;
ALTER TABLE demo.customer_summary ADD PRIMARY KEY (customer_key);
COMMENT ON TABLE  demo.customer_summary IS 'One row per customer with the number of orders placed.';
COMMENT ON COLUMN demo.customer_summary.orders IS 'All statuses; zero for customers who never ordered.';
CREATE VIEW demo.v_top_customers AS
SELECT customer_name, orders FROM demo.customer_summary ORDER BY orders DESC, customer_key LIMIT 3;

-- The data dictionary: table, column, type, nullable, comment. Paste this into any project README.
SELECT c.table_name, c.column_name, c.data_type, c.is_nullable,
       col_description(format('%I.%I', c.table_schema, c.table_name)::regclass, c.ordinal_position::int) AS description
FROM information_schema.columns c
WHERE c.table_schema = 'demo' AND c.table_name = 'customer_summary'
ORDER BY c.ordinal_position;

-- An inventory of what the project created: tables, views and functions in the schema.
SELECT (SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'demo' AND c.relkind = 'r') AS tables,
       (SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'demo' AND c.relkind = 'v') AS views,
       (SELECT COUNT(*) FROM pg_proc p  JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'demo')                      AS functions;

SELECT * FROM demo.v_top_customers;

ROLLBACK;

-- The schema is gone, so re-running is always safe. Expected: 0.
SELECT COUNT(*) AS demo_schemas_left FROM information_schema.schemata WHERE schema_name = 'demo';
