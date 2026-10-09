-- Exercise 07-03: when is it right to choose the materialization yourself?
-- Three situations, each shown with a stable measurement.

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

-- Part A: VOLATILE functions. A CTE whose query calls random() is never inlined, even with
-- NOT MATERIALIZED, so every reference sees the same value. A plain subquery calls it afresh.
-- Over 2000 runs: all three checks are true.
SELECT COUNT(*) FILTER (WHERE default_same)  = 2000 AS cte_always_same,
       COUNT(*) FILTER (WHERE hint_same)     = 2000 AS not_materialized_hint_still_same,
       COUNT(*) FILTER (WHERE subquery_same) = 0    AS subquery_never_same
FROM (SELECT (WITH r AS (SELECT random() AS x)                  SELECT (SELECT x FROM r) = (SELECT x FROM r)) AS default_same,
             (WITH r AS NOT MATERIALIZED (SELECT random() AS x) SELECT (SELECT x FROM r) = (SELECT x FROM r)) AS hint_same,
             ((SELECT random()) = (SELECT random()))                                                          AS subquery_same
      FROM generate_series(1, 2000)) t;

-- Part B: an EXPENSIVE computation used twice. Keep it MATERIALIZED (also the default for 2 references):
-- it is computed once. NOT MATERIALIZED would repeat the whole join and aggregation.
SELECT pg_temp.scans_of(pg_temp.plan_of($q$
WITH customer_totals AS MATERIALIZED (
    SELECT o.customer_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.customer_id
)
SELECT (SELECT MAX(revenue) FROM customer_totals) AS biggest,
       (SELECT MIN(revenue) FROM customer_totals) AS smallest
       $q$), 'order_items') AS order_items_scans_materialized,
       pg_temp.scans_of(pg_temp.plan_of($q$
WITH customer_totals AS NOT MATERIALIZED (
    SELECT o.customer_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.customer_id
)
SELECT (SELECT MAX(revenue) FROM customer_totals) AS biggest,
       (SELECT MIN(revenue) FROM customer_totals) AS smallest
       $q$), 'order_items') AS order_items_scans_not_materialized;

-- Part C: the OPPOSITE case. Two references, each a selective lookup. By default (materialized)
-- the whole table is read once to build the CTE (120 rows). NOT MATERIALIZED lets each lookup
-- touch only the row it needs (1 + 1 = 2 rows).
SELECT pg_temp.rows_from(pg_temp.plan_of($q$
           WITH o AS MATERIALIZED (SELECT * FROM orders)
           SELECT (SELECT status FROM o WHERE order_id = 5) AS a,
                  (SELECT status FROM o WHERE order_id = 6) AS b $q$), 'orders') AS rows_read_materialized,
       pg_temp.rows_from(pg_temp.plan_of($q$
           WITH o AS NOT MATERIALIZED (SELECT * FROM orders)
           SELECT (SELECT status FROM o WHERE order_id = 5) AS a,
                  (SELECT status FROM o WHERE order_id = 6) AS b $q$), 'orders') AS rows_read_not_materialized;
