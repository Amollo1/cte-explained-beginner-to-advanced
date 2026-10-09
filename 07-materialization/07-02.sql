-- Exercise 07-02: predicate pushdown. The filter order_date = '2025-03-12' matches 3 orders.
--   MATERIALIZED      the CTE produces all 120 order rows, THEN the filter keeps 3
--   NOT MATERIALIZED  the filter is pushed down to the table scan, which produces only 3
--   (no hint)         a CTE used once is inlined, so it behaves like NOT MATERIALIZED
-- "rows scanned" = rows the scan on the orders table produced (from EXPLAIN ANALYZE).

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

SELECT pg_temp.rows_from(pg_temp.plan_of($q$
           WITH o AS MATERIALIZED (SELECT order_id, customer_id, order_date FROM orders)
           SELECT * FROM o WHERE order_date = DATE '2025-03-12' $q$), 'orders')  AS rows_scanned_materialized,
       pg_temp.rows_from(pg_temp.plan_of($q$
           WITH o AS NOT MATERIALIZED (SELECT order_id, customer_id, order_date FROM orders)
           SELECT * FROM o WHERE order_date = DATE '2025-03-12' $q$), 'orders')  AS rows_scanned_not_materialized,
       pg_temp.rows_from(pg_temp.plan_of($q$
           WITH o AS (SELECT order_id, customer_id, order_date FROM orders)
           SELECT * FROM o WHERE order_date = DATE '2025-03-12' $q$), 'orders')  AS rows_scanned_default,
       (SELECT COUNT(*) FROM orders WHERE order_date = DATE '2025-03-12')        AS rows_in_result;
