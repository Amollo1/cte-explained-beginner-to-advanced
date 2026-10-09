-- Module 7 worked examples: MATERIALIZED vs NOT MATERIALIZED.
-- Run:  psql -d cte_lab -f 07-materialization/examples.sql
-- Plans are printed for you to READ. The numbers that matter (rows, scan counts) are stable;
-- timings (Part C) differ on every machine and every run.

-- Test helpers (session-only, in pg_temp). They turn an execution plan into STABLE numbers,
-- so results do not depend on machine speed or timing noise.
--   plan_of(query)        runs EXPLAIN ANALYZE on the query text and returns the plan as text
--   scans_of(plan, table) counts scan nodes on a table
--   rows_from(plan, table) adds up the rows those scan nodes actually produced
CREATE OR REPLACE FUNCTION pg_temp.plan_of(q text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE r record; result text := '';
BEGIN
    -- Parallel plans report per-worker AVERAGES, which would distort row counts. Switch them off
    -- for this transaction only, so the measurement is the same on every machine.
    PERFORM set_config('max_parallel_workers_per_gather', '0', true);
    FOR r IN EXECUTE 'EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) ' || q LOOP
        result := result || r."QUERY PLAN" || E'\n';
    END LOOP;
    RETURN result;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.scans_of(plan text, rel text) RETURNS int
LANGUAGE sql AS $$
    SELECT COUNT(*)::int FROM regexp_matches(plan, 'Scan[^\n]* on ' || rel || '[ (]', 'g')
$$;

CREATE OR REPLACE FUNCTION pg_temp.rows_from(plan text, rel text) RETURNS bigint
LANGUAGE sql AS $$
    SELECT COALESCE(SUM((m[1])::bigint), 0)
    FROM regexp_matches(plan, 'Scan[^\n]* on ' || rel || '[ (][^\n]*actual rows=([0-9]+)', 'g') AS m
$$;

-- =====================================================================
-- Part A: what PostgreSQL does by DEFAULT (small tables, deterministic)
-- =====================================================================

-- Example 1: a CTE referenced ONCE is inlined: there is no "CTE Scan" node in the plan.
EXPLAIN (COSTS OFF)
WITH o AS (SELECT * FROM orders)
SELECT * FROM o WHERE order_id = 5;

-- Example 2: a CTE referenced TWICE is materialized by default: look for "CTE Scan".
EXPLAIN (COSTS OFF)
WITH o AS (SELECT order_id, status FROM orders)
SELECT (SELECT status FROM o WHERE order_id = 5) AS a,
       (SELECT status FROM o WHERE order_id = 6) AS b;

-- Example 3: PREDICATE PUSHDOWN. The filter order_date = '2025-03-12' matches 3 orders.
-- MATERIALIZED: the CTE reads all 120 rows first, then the filter runs on the stored result.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
WITH o AS MATERIALIZED (SELECT order_id, customer_id, order_date FROM orders)
SELECT * FROM o WHERE order_date = DATE '2025-03-12';

-- NOT MATERIALIZED: the filter is pushed down to the table, so only 3 rows are produced.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
WITH o AS NOT MATERIALIZED (SELECT order_id, customer_id, order_date FROM orders)
SELECT * FROM o WHERE order_date = DATE '2025-03-12';

-- Example 4: the same facts as NUMBERS, using the helpers (stable across machines).
SELECT pg_temp.rows_from(pg_temp.plan_of($q$
           WITH o AS MATERIALIZED (SELECT order_id, customer_id, order_date FROM orders)
           SELECT * FROM o WHERE order_date = DATE '2025-03-12' $q$), 'orders')     AS rows_scanned_materialized,
       pg_temp.rows_from(pg_temp.plan_of($q$
           WITH o AS NOT MATERIALIZED (SELECT order_id, customer_id, order_date FROM orders)
           SELECT * FROM o WHERE order_date = DATE '2025-03-12' $q$), 'orders')     AS rows_scanned_not_materialized;

-- Example 5: DUPLICATE WORK. This CTE is used twice (the monthly rows and their average).
-- Count how many times each version scans order_items.
SELECT pg_temp.scans_of(pg_temp.plan_of($q$
WITH monthly AS MATERIALIZED (
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
)
SELECT month, revenue FROM monthly WHERE revenue > (SELECT AVG(revenue) FROM monthly)
       $q$), 'order_items') AS order_items_scans_materialized,
       pg_temp.scans_of(pg_temp.plan_of($q$
WITH monthly AS NOT MATERIALIZED (
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
)
SELECT month, revenue FROM monthly WHERE revenue > (SELECT AVG(revenue) FROM monthly)
       $q$), 'order_items') AS order_items_scans_not_materialized;

-- Example 6: a CTE containing a VOLATILE function (random()) is never inlined, hint or not.
-- Both references see the SAME value. A plain subquery calls random() each time.
SELECT COUNT(*) FILTER (WHERE default_same) AS default_same,
       COUNT(*) FILTER (WHERE hint_same)    AS not_materialized_hint_same,
       COUNT(*) FILTER (WHERE subquery_same) AS subquery_same,
       COUNT(*)                              AS runs
FROM (SELECT (WITH r AS (SELECT random() AS x)                  SELECT (SELECT x FROM r) = (SELECT x FROM r)) AS default_same,
             (WITH r AS NOT MATERIALIZED (SELECT random() AS x) SELECT (SELECT x FROM r) = (SELECT x FROM r)) AS hint_same,
             ((SELECT random()) = (SELECT random()))                                                          AS subquery_same
      FROM generate_series(1, 2000)) t;

-- =====================================================================
-- Part B: reading a plan (print one in full)
-- =====================================================================

-- Example 7: the full plan for the duplicated-work query, MATERIALIZED version.
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
WITH monthly AS MATERIALIZED (
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
)
SELECT month, revenue FROM monthly WHERE revenue > (SELECT AVG(revenue) FROM monthly);

-- =====================================================================
-- Part C: at scale. A 500,000-row temporary table shows when the choice REALLY matters.
-- Timings below differ on every machine; the row counts are what stay constant.
-- =====================================================================
CREATE TEMP TABLE big_orders AS
SELECT g                                   AS order_id,
       (g % 5000) + 1                      AS customer_id,
       DATE '2024-01-01' + (g % 900)       AS order_date,
       ROUND((random() * 500)::numeric, 2) AS amount
FROM generate_series(1, 500000) g;
ALTER TABLE big_orders ADD PRIMARY KEY (order_id);
ANALYZE big_orders;

-- Example 8a: ONE reference, selective lookup. Default = inlined = index scan, a fraction of a millisecond.
EXPLAIN (ANALYZE, COSTS OFF)
WITH o AS (SELECT * FROM big_orders) SELECT * FROM o WHERE order_id = 123456;

-- Example 8b: forcing MATERIALIZED reads all 500,000 rows first, then filters.
EXPLAIN (ANALYZE, COSTS OFF)
WITH o AS MATERIALIZED (SELECT * FROM big_orders) SELECT * FROM o WHERE order_id = 123456;

-- Example 9a: TWO references, each a selective lookup. Default = materialized = full scan.
EXPLAIN (ANALYZE, COSTS OFF)
WITH o AS (SELECT * FROM big_orders)
SELECT (SELECT amount FROM o WHERE order_id = 100) AS a,
       (SELECT amount FROM o WHERE order_id = 200) AS b;

-- Example 9b: NOT MATERIALIZED turns them into two index lookups.
EXPLAIN (ANALYZE, COSTS OFF)
WITH o AS NOT MATERIALIZED (SELECT * FROM big_orders)
SELECT (SELECT amount FROM o WHERE order_id = 100) AS a,
       (SELECT amount FROM o WHERE order_id = 200) AS b;

-- Example 10a: an EXPENSIVE aggregate used twice. MATERIALIZED computes it once...
EXPLAIN (ANALYZE, COSTS OFF)
WITH agg AS MATERIALIZED (SELECT customer_id, SUM(amount) AS total FROM big_orders GROUP BY customer_id)
SELECT (SELECT MAX(total) FROM agg) AS biggest, (SELECT MIN(total) FROM agg) AS smallest;

-- Example 10b: ...NOT MATERIALIZED computes it twice (two full passes over 500,000 rows).
EXPLAIN (ANALYZE, COSTS OFF)
WITH agg AS NOT MATERIALIZED (SELECT customer_id, SUM(amount) AS total FROM big_orders GROUP BY customer_id)
SELECT (SELECT MAX(total) FROM agg) AS biggest, (SELECT MIN(total) FROM agg) AS smallest;
