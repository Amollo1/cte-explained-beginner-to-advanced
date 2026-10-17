-- Exercise 13-03: find and fix three anti-patterns, with evidence for each.

CREATE OR REPLACE FUNCTION pg_temp.try_sql(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION
    WHEN query_canceled THEN RETURN 'CANCELED: ' || SQLERRM;   -- OTHERS does not catch query_canceled
    WHEN OTHERS         THEN RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- Helpers (session-only). They turn an execution plan into STABLE numbers, so nothing depends on machine speed.
CREATE OR REPLACE FUNCTION pg_temp.plan_of(q text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE r record; result text := '';
BEGIN
    PERFORM set_config('max_parallel_workers_per_gather', '0', true);   -- parallel plans report per-worker averages
    FOR r IN EXECUTE 'EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) ' || q LOOP
        result := result || r."QUERY PLAN" || E'\n';
    END LOOP;
    RETURN result;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.scans_of(plan text, rel text) RETURNS int         -- scan nodes on a table
LANGUAGE sql AS $$
    SELECT COUNT(*)::int FROM regexp_matches(plan, 'Scan[^\n]* on ' || rel || '[ (]', 'g')
$$;

CREATE OR REPLACE FUNCTION pg_temp.loops_of(plan text, node_pattern text) RETURNS bigint   -- how often a node ran
LANGUAGE sql AS $$
    SELECT COALESCE(SUM((m[1])::bigint), 0)
    FROM regexp_matches(plan, node_pattern || '[^\n]*loops=([0-9]+)', 'g') AS m
$$;

-- Part A: a CTE used ONCE just to wrap a table. It adds noise but no benefit: the planner inlines it, so the
-- plan has no CTE Scan and scans orders exactly as often as the direct query. Expected: 0, f, f, 1, 1.
SELECT (SELECT COUNT(*) FROM (SELECT * FROM (WITH all_orders AS (SELECT * FROM orders)
SELECT customer_id, COUNT(*) AS completed_orders
FROM all_orders
WHERE status = 'completed'
GROUP BY customer_id) b EXCEPT SELECT * FROM (SELECT customer_id, COUNT(*) AS completed_orders
FROM orders
WHERE status = 'completed'
GROUP BY customer_id) a) d1)
     + (SELECT COUNT(*) FROM (SELECT * FROM (SELECT customer_id, COUNT(*) AS completed_orders
FROM orders
WHERE status = 'completed'
GROUP BY customer_id) a EXCEPT SELECT * FROM (WITH all_orders AS (SELECT * FROM orders)
SELECT customer_id, COUNT(*) AS completed_orders
FROM all_orders
WHERE status = 'completed'
GROUP BY customer_id) b) d2)          AS differing_rows,
       pg_temp.plan_of($b$WITH all_orders AS (SELECT * FROM orders)
SELECT customer_id, COUNT(*) AS completed_orders
FROM all_orders
WHERE status = 'completed'
GROUP BY customer_id$b$) LIKE '%CTE Scan%'                                                       AS before_has_cte_scan,
       pg_temp.plan_of($a$SELECT customer_id, COUNT(*) AS completed_orders
FROM orders
WHERE status = 'completed'
GROUP BY customer_id$a$)  LIKE '%CTE Scan%'                                                       AS after_has_cte_scan,
       pg_temp.scans_of(pg_temp.plan_of($b$WITH all_orders AS (SELECT * FROM orders)
SELECT customer_id, COUNT(*) AS completed_orders
FROM all_orders
WHERE status = 'completed'
GROUP BY customer_id$b$), 'orders')                                             AS before_scans_of_orders,
       pg_temp.scans_of(pg_temp.plan_of($a$SELECT customer_id, COUNT(*) AS completed_orders
FROM orders
WHERE status = 'completed'
GROUP BY customer_id$a$), 'orders')                                              AS after_scans_of_orders;

-- Part B: SELECT * inside a CTE. It works today and breaks the day someone adds a column.
-- 42601 = syntax_error ("each UNION query must have the same number of columns"). Expected: ok, 42601, ok.
BEGIN;
CREATE TEMP TABLE star_check(step int, what text, outcome text);
INSERT INTO star_check SELECT 1, 'SELECT * in the CTE, before a column is added', LEFT(pg_temp.try_sql($q$WITH d AS (SELECT * FROM departments) SELECT * FROM d UNION ALL SELECT dept_id, dept_name, location FROM departments$q$), 5);
ALTER TABLE departments ADD COLUMN budget numeric;                    -- a colleague adds a column...
INSERT INTO star_check SELECT 2, 'SELECT * in the CTE, after a column is added',  LEFT(pg_temp.try_sql($q$WITH d AS (SELECT * FROM departments) SELECT * FROM d UNION ALL SELECT dept_id, dept_name, location FROM departments$q$), 5);
INSERT INTO star_check SELECT 3, 'explicit column list, after a column is added', LEFT(pg_temp.try_sql($q$WITH d AS (SELECT dept_id, dept_name, location FROM departments) SELECT * FROM d UNION ALL SELECT dept_id, dept_name, location FROM departments$q$), 5);
SELECT what, outcome FROM star_check ORDER BY step;
ROLLBACK;

-- Part C: a recursion with no stop condition. The routes graph has cycles, so it never ends and is cancelled
-- by the timeout. Adding a path check fixes it: 12 simple paths from Nairobi. Expected: t, 12.
SET statement_timeout = '300ms';
SELECT pg_temp.try_sql($q$
    WITH RECURSIVE walk(city) AS (
        SELECT 'Nairobi'::text
        UNION ALL
        SELECT r.destination FROM walk w JOIN routes r ON r.origin = w.city      -- no stop condition
    ) SELECT COUNT(*) FROM walk $q$) LIKE 'CANCELED:%' AS unguarded_search_cancelled;
RESET statement_timeout;

WITH RECURSIVE walk(city, path) AS (
    SELECT 'Nairobi'::text, ARRAY['Nairobi'::text]
    UNION ALL
    SELECT r.destination, w.path || r.destination
    FROM walk w
    JOIN routes r ON r.origin = w.city
    WHERE NOT (r.destination = ANY (w.path))                                      -- the fix: never revisit a city
)
SELECT COUNT(*) AS guarded_search_rows FROM walk;
