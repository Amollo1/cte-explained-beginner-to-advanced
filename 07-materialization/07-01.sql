-- Exercise 07-01: a CTE referenced twice, MATERIALIZED vs NOT MATERIALIZED.
-- The query lists the months whose revenue is above the average month. The monthly_revenue CTE
-- is used twice (the rows, and their average).
--   Expected: MATERIALIZED scans order_items once (computed once, stored, read twice);
--             NOT MATERIALIZED scans it twice (the whole CTE is inlined at both references).
-- To READ the plans yourself, run EXPLAIN (ANALYZE) on each version (see exercises.md).
-- This file turns the plans into stable numbers so it can be tested automatically.

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

-- Part A: the plan facts
SELECT pg_temp.scans_of(m.plan, 'order_items')   AS materialized_scans,
       pg_temp.scans_of(n.plan, 'order_items')   AS not_materialized_scans,
       m.plan LIKE '%CTE Scan%'                  AS materialized_has_cte_scan,
       n.plan LIKE '%CTE Scan%'                  AS not_materialized_has_cte_scan
FROM (SELECT pg_temp.plan_of($q$
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
      $q$) AS plan) m,
     (SELECT pg_temp.plan_of($q$
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
      $q$) AS plan) n;

-- Part B: the hint changes HOW the answer is computed, never WHAT the answer is.
WITH materialized_version AS (
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
),
not_materialized_version AS (
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
)
SELECT (SELECT COUNT(*) FROM materialized_version) AS result_rows,
       (SELECT COUNT(*) FROM (SELECT * FROM materialized_version EXCEPT SELECT * FROM not_materialized_version) a)
     + (SELECT COUNT(*) FROM (SELECT * FROM not_materialized_version EXCEPT SELECT * FROM materialized_version) b) AS differences;
