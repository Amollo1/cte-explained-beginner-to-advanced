-- Module 13 worked examples: performance, best practices and anti-patterns.
-- Run:  psql -d cte_lab -f 13-best-practices/examples.sql
-- Plans and timings printed here differ on every machine. The numbers the lesson relies on (scan counts, lookups,
-- rows) are stable. Needs PostgreSQL 14 or newer and the ltree extension (included with standard installs).

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

CREATE OR REPLACE FUNCTION pg_temp.run_report(q text)
RETURNS TABLE(customer_id int, customer_name text, country text, segment text, orders bigint, revenue numeric,
              avg_order_value numeric, pct_of_country numeric, country_rank bigint, vs_country_avg text)
LANGUAGE plpgsql AS $$
BEGIN
    RETURN QUERY EXECUTE q;
END $$;

-- =====================================================================
-- Part A: refactoring a nested query into CTEs
-- =====================================================================

-- Example 1: the NESTED version. Look for the same aggregation written out three more times.
SELECT t.customer_id, t.customer_name, t.country, t.segment, t.orders,
       ROUND(t.revenue, 2) AS revenue,
       ROUND(t.revenue / t.orders, 2) AS avg_order_value,
       ROUND(100 * t.revenue / (SELECT SUM(x.revenue)
                                FROM (SELECT o2.customer_id, SUM(i2.quantity * p2.unit_price * (1 - i2.discount)) AS revenue
                                      FROM orders o2
                                      JOIN order_items i2 ON i2.order_id = o2.order_id
                                      JOIN products p2 ON p2.product_id = i2.product_id
                                      WHERE o2.status = 'completed'
                                      GROUP BY o2.customer_id) x
                                JOIN customers c2 ON c2.customer_id = x.customer_id
                                WHERE c2.country = t.country), 1) AS pct_of_country,
       (SELECT COUNT(*) + 1
        FROM (SELECT o3.customer_id, SUM(i3.quantity * p3.unit_price * (1 - i3.discount)) AS revenue
              FROM orders o3
              JOIN order_items i3 ON i3.order_id = o3.order_id
              JOIN products p3 ON p3.product_id = i3.product_id
              WHERE o3.status = 'completed'
              GROUP BY o3.customer_id) y
        JOIN customers c3 ON c3.customer_id = y.customer_id
        WHERE c3.country = t.country AND y.revenue > t.revenue) AS country_rank,
       CASE WHEN t.revenue > (SELECT AVG(z.revenue)
                              FROM (SELECT o4.customer_id, SUM(i4.quantity * p4.unit_price * (1 - i4.discount)) AS revenue
                                    FROM orders o4
                                    JOIN order_items i4 ON i4.order_id = o4.order_id
                                    JOIN products p4 ON p4.product_id = i4.product_id
                                    WHERE o4.status = 'completed'
                                    GROUP BY o4.customer_id) z
                              JOIN customers c4 ON c4.customer_id = z.customer_id
                              WHERE c4.country = t.country)
            THEN 'above' ELSE 'at or below' END AS vs_country_avg
FROM (SELECT c.customer_id, c.customer_name, c.country, c.segment,
             COUNT(DISTINCT o.order_id) AS orders,
             SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
      FROM customers c
      JOIN orders o      ON o.customer_id = c.customer_id
      JOIN order_items i ON i.order_id    = o.order_id
      JOIN products p    ON p.product_id  = i.product_id
      WHERE o.status = 'completed'
      GROUP BY c.customer_id, c.customer_name, c.country, c.segment) t
ORDER BY t.revenue DESC, t.customer_id
LIMIT 5;

-- Example 2: the CTE version. Each step has one job and a stated grain.
WITH order_totals AS (                    -- grain: one row per completed order
    SELECT o.order_id,
           o.customer_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.order_id, o.customer_id
),
customer_totals AS (                    -- grain: one row per customer
    SELECT customer_id,
           COUNT(*)     AS orders,       -- one row per order, so COUNT(*) needs no DISTINCT
           SUM(revenue) AS revenue
    FROM order_totals
    GROUP BY customer_id
),
with_country AS (                       -- same grain, plus country-level windows
    SELECT c.customer_id, c.customer_name, c.country, c.segment,
           t.orders, t.revenue,
           SUM(t.revenue) OVER (PARTITION BY c.country)                          AS country_revenue,
           RANK()         OVER (PARTITION BY c.country ORDER BY t.revenue DESC)  AS country_rank,
           AVG(t.revenue) OVER (PARTITION BY c.country)                          AS country_avg
    FROM customer_totals t
    JOIN customers c ON c.customer_id = t.customer_id
)
SELECT customer_id, customer_name, country, segment, orders,
       ROUND(revenue, 2)                         AS revenue,
       ROUND(revenue / orders, 2)                AS avg_order_value,
       ROUND(100 * revenue / country_revenue, 1) AS pct_of_country,
       country_rank,
       CASE WHEN revenue > country_avg THEN 'above' ELSE 'at or below' END AS vs_country_avg
FROM with_country
ORDER BY revenue DESC, customer_id
LIMIT 5;

-- Example 3: PROVE they agree (differences = 0), and count the repeated work (4 scans against 1).
SELECT (SELECT COUNT(*) FROM pg_temp.run_report($b$SELECT t.customer_id, t.customer_name, t.country, t.segment, t.orders,
       ROUND(t.revenue, 2) AS revenue,
       ROUND(t.revenue / t.orders, 2) AS avg_order_value,
       ROUND(100 * t.revenue / (SELECT SUM(x.revenue)
                                FROM (SELECT o2.customer_id, SUM(i2.quantity * p2.unit_price * (1 - i2.discount)) AS revenue
                                      FROM orders o2
                                      JOIN order_items i2 ON i2.order_id = o2.order_id
                                      JOIN products p2 ON p2.product_id = i2.product_id
                                      WHERE o2.status = 'completed'
                                      GROUP BY o2.customer_id) x
                                JOIN customers c2 ON c2.customer_id = x.customer_id
                                WHERE c2.country = t.country), 1) AS pct_of_country,
       (SELECT COUNT(*) + 1
        FROM (SELECT o3.customer_id, SUM(i3.quantity * p3.unit_price * (1 - i3.discount)) AS revenue
              FROM orders o3
              JOIN order_items i3 ON i3.order_id = o3.order_id
              JOIN products p3 ON p3.product_id = i3.product_id
              WHERE o3.status = 'completed'
              GROUP BY o3.customer_id) y
        JOIN customers c3 ON c3.customer_id = y.customer_id
        WHERE c3.country = t.country AND y.revenue > t.revenue) AS country_rank,
       CASE WHEN t.revenue > (SELECT AVG(z.revenue)
                              FROM (SELECT o4.customer_id, SUM(i4.quantity * p4.unit_price * (1 - i4.discount)) AS revenue
                                    FROM orders o4
                                    JOIN order_items i4 ON i4.order_id = o4.order_id
                                    JOIN products p4 ON p4.product_id = i4.product_id
                                    WHERE o4.status = 'completed'
                                    GROUP BY o4.customer_id) z
                              JOIN customers c4 ON c4.customer_id = z.customer_id
                              WHERE c4.country = t.country)
            THEN 'above' ELSE 'at or below' END AS vs_country_avg
FROM (SELECT c.customer_id, c.customer_name, c.country, c.segment,
             COUNT(DISTINCT o.order_id) AS orders,
             SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
      FROM customers c
      JOIN orders o      ON o.customer_id = c.customer_id
      JOIN order_items i ON i.order_id    = o.order_id
      JOIN products p    ON p.product_id  = i.product_id
      WHERE o.status = 'completed'
      GROUP BY c.customer_id, c.customer_name, c.country, c.segment) t$b$)) AS before_rows,
       (SELECT COUNT(*) FROM pg_temp.run_report($a$WITH order_totals AS (                    -- grain: one row per completed order
    SELECT o.order_id,
           o.customer_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.order_id, o.customer_id
),
customer_totals AS (                    -- grain: one row per customer
    SELECT customer_id,
           COUNT(*)     AS orders,       -- one row per order, so COUNT(*) needs no DISTINCT
           SUM(revenue) AS revenue
    FROM order_totals
    GROUP BY customer_id
),
with_country AS (                       -- same grain, plus country-level windows
    SELECT c.customer_id, c.customer_name, c.country, c.segment,
           t.orders, t.revenue,
           SUM(t.revenue) OVER (PARTITION BY c.country)                          AS country_revenue,
           RANK()         OVER (PARTITION BY c.country ORDER BY t.revenue DESC)  AS country_rank,
           AVG(t.revenue) OVER (PARTITION BY c.country)                          AS country_avg
    FROM customer_totals t
    JOIN customers c ON c.customer_id = t.customer_id
)
SELECT customer_id, customer_name, country, segment, orders,
       ROUND(revenue, 2)                         AS revenue,
       ROUND(revenue / orders, 2)                AS avg_order_value,
       ROUND(100 * revenue / country_revenue, 1) AS pct_of_country,
       country_rank,
       CASE WHEN revenue > country_avg THEN 'above' ELSE 'at or below' END AS vs_country_avg
FROM with_country$a$))  AS after_rows,
       (SELECT COUNT(*) FROM (SELECT * FROM pg_temp.run_report($b$SELECT t.customer_id, t.customer_name, t.country, t.segment, t.orders,
       ROUND(t.revenue, 2) AS revenue,
       ROUND(t.revenue / t.orders, 2) AS avg_order_value,
       ROUND(100 * t.revenue / (SELECT SUM(x.revenue)
                                FROM (SELECT o2.customer_id, SUM(i2.quantity * p2.unit_price * (1 - i2.discount)) AS revenue
                                      FROM orders o2
                                      JOIN order_items i2 ON i2.order_id = o2.order_id
                                      JOIN products p2 ON p2.product_id = i2.product_id
                                      WHERE o2.status = 'completed'
                                      GROUP BY o2.customer_id) x
                                JOIN customers c2 ON c2.customer_id = x.customer_id
                                WHERE c2.country = t.country), 1) AS pct_of_country,
       (SELECT COUNT(*) + 1
        FROM (SELECT o3.customer_id, SUM(i3.quantity * p3.unit_price * (1 - i3.discount)) AS revenue
              FROM orders o3
              JOIN order_items i3 ON i3.order_id = o3.order_id
              JOIN products p3 ON p3.product_id = i3.product_id
              WHERE o3.status = 'completed'
              GROUP BY o3.customer_id) y
        JOIN customers c3 ON c3.customer_id = y.customer_id
        WHERE c3.country = t.country AND y.revenue > t.revenue) AS country_rank,
       CASE WHEN t.revenue > (SELECT AVG(z.revenue)
                              FROM (SELECT o4.customer_id, SUM(i4.quantity * p4.unit_price * (1 - i4.discount)) AS revenue
                                    FROM orders o4
                                    JOIN order_items i4 ON i4.order_id = o4.order_id
                                    JOIN products p4 ON p4.product_id = i4.product_id
                                    WHERE o4.status = 'completed'
                                    GROUP BY o4.customer_id) z
                              JOIN customers c4 ON c4.customer_id = z.customer_id
                              WHERE c4.country = t.country)
            THEN 'above' ELSE 'at or below' END AS vs_country_avg
FROM (SELECT c.customer_id, c.customer_name, c.country, c.segment,
             COUNT(DISTINCT o.order_id) AS orders,
             SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
      FROM customers c
      JOIN orders o      ON o.customer_id = c.customer_id
      JOIN order_items i ON i.order_id    = o.order_id
      JOIN products p    ON p.product_id  = i.product_id
      WHERE o.status = 'completed'
      GROUP BY c.customer_id, c.customer_name, c.country, c.segment) t$b$)
                              EXCEPT SELECT * FROM pg_temp.run_report($a$WITH order_totals AS (                    -- grain: one row per completed order
    SELECT o.order_id,
           o.customer_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.order_id, o.customer_id
),
customer_totals AS (                    -- grain: one row per customer
    SELECT customer_id,
           COUNT(*)     AS orders,       -- one row per order, so COUNT(*) needs no DISTINCT
           SUM(revenue) AS revenue
    FROM order_totals
    GROUP BY customer_id
),
with_country AS (                       -- same grain, plus country-level windows
    SELECT c.customer_id, c.customer_name, c.country, c.segment,
           t.orders, t.revenue,
           SUM(t.revenue) OVER (PARTITION BY c.country)                          AS country_revenue,
           RANK()         OVER (PARTITION BY c.country ORDER BY t.revenue DESC)  AS country_rank,
           AVG(t.revenue) OVER (PARTITION BY c.country)                          AS country_avg
    FROM customer_totals t
    JOIN customers c ON c.customer_id = t.customer_id
)
SELECT customer_id, customer_name, country, segment, orders,
       ROUND(revenue, 2)                         AS revenue,
       ROUND(revenue / orders, 2)                AS avg_order_value,
       ROUND(100 * revenue / country_revenue, 1) AS pct_of_country,
       country_rank,
       CASE WHEN revenue > country_avg THEN 'above' ELSE 'at or below' END AS vs_country_avg
FROM with_country$a$)) d1)
     + (SELECT COUNT(*) FROM (SELECT * FROM pg_temp.run_report($a$WITH order_totals AS (                    -- grain: one row per completed order
    SELECT o.order_id,
           o.customer_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.order_id, o.customer_id
),
customer_totals AS (                    -- grain: one row per customer
    SELECT customer_id,
           COUNT(*)     AS orders,       -- one row per order, so COUNT(*) needs no DISTINCT
           SUM(revenue) AS revenue
    FROM order_totals
    GROUP BY customer_id
),
with_country AS (                       -- same grain, plus country-level windows
    SELECT c.customer_id, c.customer_name, c.country, c.segment,
           t.orders, t.revenue,
           SUM(t.revenue) OVER (PARTITION BY c.country)                          AS country_revenue,
           RANK()         OVER (PARTITION BY c.country ORDER BY t.revenue DESC)  AS country_rank,
           AVG(t.revenue) OVER (PARTITION BY c.country)                          AS country_avg
    FROM customer_totals t
    JOIN customers c ON c.customer_id = t.customer_id
)
SELECT customer_id, customer_name, country, segment, orders,
       ROUND(revenue, 2)                         AS revenue,
       ROUND(revenue / orders, 2)                AS avg_order_value,
       ROUND(100 * revenue / country_revenue, 1) AS pct_of_country,
       country_rank,
       CASE WHEN revenue > country_avg THEN 'above' ELSE 'at or below' END AS vs_country_avg
FROM with_country$a$)
                              EXCEPT SELECT * FROM pg_temp.run_report($b$SELECT t.customer_id, t.customer_name, t.country, t.segment, t.orders,
       ROUND(t.revenue, 2) AS revenue,
       ROUND(t.revenue / t.orders, 2) AS avg_order_value,
       ROUND(100 * t.revenue / (SELECT SUM(x.revenue)
                                FROM (SELECT o2.customer_id, SUM(i2.quantity * p2.unit_price * (1 - i2.discount)) AS revenue
                                      FROM orders o2
                                      JOIN order_items i2 ON i2.order_id = o2.order_id
                                      JOIN products p2 ON p2.product_id = i2.product_id
                                      WHERE o2.status = 'completed'
                                      GROUP BY o2.customer_id) x
                                JOIN customers c2 ON c2.customer_id = x.customer_id
                                WHERE c2.country = t.country), 1) AS pct_of_country,
       (SELECT COUNT(*) + 1
        FROM (SELECT o3.customer_id, SUM(i3.quantity * p3.unit_price * (1 - i3.discount)) AS revenue
              FROM orders o3
              JOIN order_items i3 ON i3.order_id = o3.order_id
              JOIN products p3 ON p3.product_id = i3.product_id
              WHERE o3.status = 'completed'
              GROUP BY o3.customer_id) y
        JOIN customers c3 ON c3.customer_id = y.customer_id
        WHERE c3.country = t.country AND y.revenue > t.revenue) AS country_rank,
       CASE WHEN t.revenue > (SELECT AVG(z.revenue)
                              FROM (SELECT o4.customer_id, SUM(i4.quantity * p4.unit_price * (1 - i4.discount)) AS revenue
                                    FROM orders o4
                                    JOIN order_items i4 ON i4.order_id = o4.order_id
                                    JOIN products p4 ON p4.product_id = i4.product_id
                                    WHERE o4.status = 'completed'
                                    GROUP BY o4.customer_id) z
                              JOIN customers c4 ON c4.customer_id = z.customer_id
                              WHERE c4.country = t.country)
            THEN 'above' ELSE 'at or below' END AS vs_country_avg
FROM (SELECT c.customer_id, c.customer_name, c.country, c.segment,
             COUNT(DISTINCT o.order_id) AS orders,
             SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
      FROM customers c
      JOIN orders o      ON o.customer_id = c.customer_id
      JOIN order_items i ON i.order_id    = o.order_id
      JOIN products p    ON p.product_id  = i.product_id
      WHERE o.status = 'completed'
      GROUP BY c.customer_id, c.customer_name, c.country, c.segment) t$b$)) d2) AS differences;

SELECT pg_temp.scans_of(pg_temp.plan_of($b$SELECT t.customer_id, t.customer_name, t.country, t.segment, t.orders,
       ROUND(t.revenue, 2) AS revenue,
       ROUND(t.revenue / t.orders, 2) AS avg_order_value,
       ROUND(100 * t.revenue / (SELECT SUM(x.revenue)
                                FROM (SELECT o2.customer_id, SUM(i2.quantity * p2.unit_price * (1 - i2.discount)) AS revenue
                                      FROM orders o2
                                      JOIN order_items i2 ON i2.order_id = o2.order_id
                                      JOIN products p2 ON p2.product_id = i2.product_id
                                      WHERE o2.status = 'completed'
                                      GROUP BY o2.customer_id) x
                                JOIN customers c2 ON c2.customer_id = x.customer_id
                                WHERE c2.country = t.country), 1) AS pct_of_country,
       (SELECT COUNT(*) + 1
        FROM (SELECT o3.customer_id, SUM(i3.quantity * p3.unit_price * (1 - i3.discount)) AS revenue
              FROM orders o3
              JOIN order_items i3 ON i3.order_id = o3.order_id
              JOIN products p3 ON p3.product_id = i3.product_id
              WHERE o3.status = 'completed'
              GROUP BY o3.customer_id) y
        JOIN customers c3 ON c3.customer_id = y.customer_id
        WHERE c3.country = t.country AND y.revenue > t.revenue) AS country_rank,
       CASE WHEN t.revenue > (SELECT AVG(z.revenue)
                              FROM (SELECT o4.customer_id, SUM(i4.quantity * p4.unit_price * (1 - i4.discount)) AS revenue
                                    FROM orders o4
                                    JOIN order_items i4 ON i4.order_id = o4.order_id
                                    JOIN products p4 ON p4.product_id = i4.product_id
                                    WHERE o4.status = 'completed'
                                    GROUP BY o4.customer_id) z
                              JOIN customers c4 ON c4.customer_id = z.customer_id
                              WHERE c4.country = t.country)
            THEN 'above' ELSE 'at or below' END AS vs_country_avg
FROM (SELECT c.customer_id, c.customer_name, c.country, c.segment,
             COUNT(DISTINCT o.order_id) AS orders,
             SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
      FROM customers c
      JOIN orders o      ON o.customer_id = c.customer_id
      JOIN order_items i ON i.order_id    = o.order_id
      JOIN products p    ON p.product_id  = i.product_id
      WHERE o.status = 'completed'
      GROUP BY c.customer_id, c.customer_name, c.country, c.segment) t$b$), 'order_items') AS before_scans_of_order_items,
       pg_temp.scans_of(pg_temp.plan_of($a$WITH order_totals AS (                    -- grain: one row per completed order
    SELECT o.order_id,
           o.customer_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.order_id, o.customer_id
),
customer_totals AS (                    -- grain: one row per customer
    SELECT customer_id,
           COUNT(*)     AS orders,       -- one row per order, so COUNT(*) needs no DISTINCT
           SUM(revenue) AS revenue
    FROM order_totals
    GROUP BY customer_id
),
with_country AS (                       -- same grain, plus country-level windows
    SELECT c.customer_id, c.customer_name, c.country, c.segment,
           t.orders, t.revenue,
           SUM(t.revenue) OVER (PARTITION BY c.country)                          AS country_revenue,
           RANK()         OVER (PARTITION BY c.country ORDER BY t.revenue DESC)  AS country_rank,
           AVG(t.revenue) OVER (PARTITION BY c.country)                          AS country_avg
    FROM customer_totals t
    JOIN customers c ON c.customer_id = t.customer_id
)
SELECT customer_id, customer_name, country, segment, orders,
       ROUND(revenue, 2)                         AS revenue,
       ROUND(revenue / orders, 2)                AS avg_order_value,
       ROUND(100 * revenue / country_revenue, 1) AS pct_of_country,
       country_rank,
       CASE WHEN revenue > country_avg THEN 'above' ELSE 'at or below' END AS vs_country_avg
FROM with_country$a$), 'order_items')  AS after_scans_of_order_items;

-- =====================================================================
-- Part B: indexing a recursive traversal
-- =====================================================================
DROP TABLE IF EXISTS pg_temp.big_org;
DROP TABLE IF EXISTS pg_temp.index_results;

-- A generated org chart: 111,111 people in 6 levels (every manager has 10 reports). No index on manager_id yet.
CREATE TEMP TABLE big_org AS
SELECT g AS emp_id,
       CASE WHEN g = 1 THEN NULL ELSE (g - 2) / 10 + 1 END AS manager_id,
       'employee_' || g AS full_name,
       repeat('x', 60)  AS padding
FROM generate_series(1, 111111) AS g;
ALTER TABLE big_org ADD PRIMARY KEY (emp_id);
ANALYZE big_org;

-- Example 4: the whole organisation, NO index on manager_id. Read the Seq Scan on big_org: loops = rounds.
EXPLAIN (ANALYZE, COSTS OFF)
WITH RECURSIVE org(emp_id, depth) AS (
    SELECT emp_id, 1 FROM big_org WHERE manager_id IS NULL
    UNION ALL
    SELECT e.emp_id, o.depth + 1 FROM big_org e JOIN org o ON e.manager_id = o.emp_id
)
SELECT COUNT(*), MAX(depth) FROM org;

-- Example 5: ONE TEAM of 11 people, still no index. The whole table is scanned in every round to find 10 people.
EXPLAIN (ANALYZE, COSTS OFF)
WITH RECURSIVE team(emp_id, depth) AS (
    SELECT emp_id, 1 FROM big_org WHERE emp_id = 1112
    UNION ALL
    SELECT e.emp_id, t.depth + 1 FROM big_org e JOIN team t ON e.manager_id = t.emp_id
)
SELECT COUNT(*), MAX(depth) FROM team;

CREATE INDEX idx_big_org_manager ON big_org (manager_id);
ANALYZE big_org;

-- Example 6: the same two queries WITH the index. Now an Index Scan: one lookup per person expanded.
EXPLAIN (ANALYZE, COSTS OFF)
WITH RECURSIVE org(emp_id, depth) AS (
    SELECT emp_id, 1 FROM big_org WHERE manager_id IS NULL
    UNION ALL
    SELECT e.emp_id, o.depth + 1 FROM big_org e JOIN org o ON e.manager_id = o.emp_id
)
SELECT COUNT(*), MAX(depth) FROM org;

EXPLAIN (ANALYZE, COSTS OFF)
WITH RECURSIVE team(emp_id, depth) AS (
    SELECT emp_id, 1 FROM big_org WHERE emp_id = 1112
    UNION ALL
    SELECT e.emp_id, t.depth + 1 FROM big_org e JOIN team t ON e.manager_id = t.emp_id
)
SELECT COUNT(*), MAX(depth) FROM team;

-- Example 7: the same facts as STABLE NUMBERS (no timings), measured with and without the index.
DROP INDEX idx_big_org_manager;
ANALYZE big_org;
CREATE TEMP TABLE index_results(ord int, scenario text, whole_table_scans bigint, index_lookups bigint,
                                result_rows bigint, max_depth int);

CREATE OR REPLACE FUNCTION pg_temp.measure(label text, first_ord int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE full_plan text; team_plan text; n bigint; d int;
BEGIN
    -- the whole organisation, from the top
    full_plan := pg_temp.plan_of($q$
        WITH RECURSIVE org(emp_id, depth) AS (
            SELECT emp_id, 1 FROM big_org WHERE manager_id IS NULL
            UNION ALL
            SELECT e.emp_id, o.depth + 1 FROM big_org e JOIN org o ON e.manager_id = o.emp_id
        ) SELECT COUNT(*), MAX(depth) FROM org $q$);
    WITH RECURSIVE org(emp_id, depth) AS (
        SELECT emp_id, 1 FROM big_org WHERE manager_id IS NULL
        UNION ALL
        SELECT e.emp_id, o.depth + 1 FROM big_org e JOIN org o ON e.manager_id = o.emp_id)
    SELECT COUNT(*), MAX(depth) INTO n, d FROM org;
    INSERT INTO index_results VALUES (first_ord, label || ': whole organisation',
        pg_temp.loops_of(full_plan, 'Seq Scan on big_org e'),
        pg_temp.loops_of(full_plan, 'Index Scan using idx_big_org_manager on big_org e'), n, d);

    -- one small team: employee 1112 and the 10 people under them
    team_plan := pg_temp.plan_of($q$
        WITH RECURSIVE team(emp_id, depth) AS (
            SELECT emp_id, 1 FROM big_org WHERE emp_id = 1112
            UNION ALL
            SELECT e.emp_id, t.depth + 1 FROM big_org e JOIN team t ON e.manager_id = t.emp_id
        ) SELECT COUNT(*), MAX(depth) FROM team $q$);
    WITH RECURSIVE team(emp_id, depth) AS (
        SELECT emp_id, 1 FROM big_org WHERE emp_id = 1112
        UNION ALL
        SELECT e.emp_id, t.depth + 1 FROM big_org e JOIN team t ON e.manager_id = t.emp_id)
    SELECT COUNT(*), MAX(depth) INTO n, d FROM team;
    INSERT INTO index_results VALUES (first_ord + 1, label || ': one team of 11',
        pg_temp.loops_of(team_plan, 'Seq Scan on big_org e'),
        pg_temp.loops_of(team_plan, 'Index Scan using idx_big_org_manager on big_org e'), n, d);
END $$;

DO $$ BEGIN PERFORM pg_temp.measure('no index', 1); END $$;
CREATE INDEX idx_big_org_manager ON big_org (manager_id);
ANALYZE big_org;
DO $$ BEGIN PERFORM pg_temp.measure('with index', 3); END $$;

SELECT scenario, whole_table_scans, index_lookups, result_rows, max_depth
FROM index_results
ORDER BY ord;

-- =====================================================================
-- Part C: three anti-patterns
-- =====================================================================

-- Example 8: a single-use CTE that only wraps a table. No benefit: the plan is the same.
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

-- Example 9: SELECT * inside a CTE breaks when a column is added (everything is rolled back).
BEGIN;
CREATE TEMP TABLE star_check(step int, what text, outcome text);
INSERT INTO star_check SELECT 1, 'SELECT * in the CTE, before a column is added', LEFT(pg_temp.try_sql($q$WITH d AS (SELECT * FROM departments) SELECT * FROM d UNION ALL SELECT dept_id, dept_name, location FROM departments$q$), 5);
ALTER TABLE departments ADD COLUMN budget numeric;                    -- a colleague adds a column...
INSERT INTO star_check SELECT 2, 'SELECT * in the CTE, after a column is added',  LEFT(pg_temp.try_sql($q$WITH d AS (SELECT * FROM departments) SELECT * FROM d UNION ALL SELECT dept_id, dept_name, location FROM departments$q$), 5);
INSERT INTO star_check SELECT 3, 'explicit column list, after a column is added', LEFT(pg_temp.try_sql($q$WITH d AS (SELECT dept_id, dept_name, location FROM departments) SELECT * FROM d UNION ALL SELECT dept_id, dept_name, location FROM departments$q$), 5);
SELECT what, outcome FROM star_check ORDER BY step;
ROLLBACK;

-- Example 10: recursion with no stop condition, and the fix.
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

-- =====================================================================
-- Part D: four ways to store a hierarchy
-- =====================================================================
BEGIN;
CREATE EXTENSION IF NOT EXISTS ltree;                       -- ships with PostgreSQL (contrib); the ROLLBACK below undoes it

-- Model 2: MATERIALIZED PATH. Each row stores its whole path from the root, for example '1/5/6/'.
CREATE TEMP TABLE cat_path AS
WITH RECURSIVE t(category_id, path) AS (
    SELECT category_id, category_id::text || '/' FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.category_id, t.path || c.category_id || '/' FROM categories c JOIN t ON c.parent_id = t.category_id
)
SELECT category_id, path FROM t;

-- Model 3: CLOSURE TABLE. Every node paired with each of its descendants (itself included, at depth 0).
CREATE TEMP TABLE cat_closure AS
WITH RECURSIVE c(ancestor_id, descendant_id, depth) AS (
    SELECT category_id, category_id, 0 FROM categories
    UNION ALL
    SELECT c.ancestor_id, k.category_id, c.depth + 1 FROM c JOIN categories k ON k.parent_id = c.descendant_id
)
SELECT ancestor_id, descendant_id, depth FROM c;

-- Model 4: LTREE. The same path as a special indexable type, for example 1.5.6
CREATE TEMP TABLE cat_ltree AS
SELECT category_id, replace(trim(trailing '/' FROM path), '/', '.')::ltree AS path FROM cat_path;

-- Model 1 (the one used all through this course): the categories table itself, read with a recursive CTE.
CREATE OR REPLACE FUNCTION pg_temp.subtree_adjacency(root int) RETURNS SETOF int
LANGUAGE sql AS $$
    WITH RECURSIVE d(category_id) AS (
        SELECT root
        UNION ALL
        SELECT c.category_id FROM categories c JOIN d ON c.parent_id = d.category_id
    ) SELECT category_id FROM d
$$;

-- Number of ids that appear in one array but not the other (0 = identical sets).
CREATE OR REPLACE FUNCTION pg_temp.sym_diff(a int[], b int[]) RETURNS bigint
LANGUAGE sql AS $$
    SELECT (SELECT COUNT(*) FROM (SELECT unnest(a) EXCEPT SELECT unnest(b)) x)
         + (SELECT COUNT(*) FROM (SELECT unnest(b) EXCEPT SELECT unnest(a)) y)
$$;

-- Example 11: READ the subtree of Electronics in all four models.
WITH expected AS (SELECT array_agg(x ORDER BY x) AS ids FROM pg_temp.subtree_adjacency(1) AS x)
SELECT model, rows_found, differences_from_adjacency
FROM (
    SELECT 1 AS ord, 'adjacency list + recursive CTE' AS model, cardinality(ids) AS rows_found, 0::bigint AS differences_from_adjacency
    FROM expected
    UNION ALL
    SELECT 2, 'materialized path',
           (SELECT COUNT(*) FROM cat_path WHERE path LIKE '1/%'),
           pg_temp.sym_diff((SELECT array_agg(category_id) FROM cat_path WHERE path LIKE '1/%'), (SELECT ids FROM expected))
    UNION ALL
    SELECT 3, 'closure table',
           (SELECT COUNT(*) FROM cat_closure WHERE ancestor_id = 1),
           pg_temp.sym_diff((SELECT array_agg(descendant_id) FROM cat_closure WHERE ancestor_id = 1), (SELECT ids FROM expected))
    UNION ALL
    SELECT 4, 'ltree',
           (SELECT COUNT(*) FROM cat_ltree WHERE path <@ '1'::ltree),
           pg_temp.sym_diff((SELECT array_agg(category_id) FROM cat_ltree WHERE path <@ '1'::ltree), (SELECT ids FROM expected))
) q
ORDER BY ord;

-- Example 12: WRITE. Move the Phones subtree under Office, and count the rows each model changes.
CREATE TEMP TABLE move_costs(ord int, model text, rows_changed bigint);

-- 1. adjacency list: just repoint the parent of Phones (5) to Office (8)
WITH m AS (UPDATE categories SET parent_id = 8 WHERE category_id = 5 RETURNING 1)
INSERT INTO move_costs SELECT 1, 'adjacency list + recursive CTE', COUNT(*) FROM m;

-- 2. materialized path: rewrite the path of the moved node and of everything below it
WITH m AS (UPDATE cat_path SET path = '8/5/' || substr(path, length('1/5/') + 1) WHERE path LIKE '1/5/%' RETURNING 1)
INSERT INTO move_costs SELECT 2, 'materialized path', COUNT(*) FROM m;

-- 3. closure table: remove the links from the OLD ancestors, add links from the NEW ones
WITH moved AS (SELECT descendant_id, depth FROM cat_closure WHERE ancestor_id = 5),
del AS (DELETE FROM cat_closure
        WHERE descendant_id IN (SELECT descendant_id FROM moved)
          AND ancestor_id NOT IN (SELECT descendant_id FROM moved)
        RETURNING 1),
ins AS (INSERT INTO cat_closure
        SELECT a.ancestor_id, m.descendant_id, a.depth + 1 + m.depth
        FROM cat_closure a CROSS JOIN moved m
        WHERE a.descendant_id = 8
        RETURNING 1)
INSERT INTO move_costs SELECT 3, 'closure table', (SELECT COUNT(*) FROM del) + (SELECT COUNT(*) FROM ins);

-- 4. ltree: the same rewrite as the materialized path (the moved node itself has nothing left to append)
WITH m AS (UPDATE cat_ltree
           SET path = CASE WHEN nlevel(path) = nlevel('1.5'::ltree) THEN '8.5'::ltree
                           ELSE '8.5'::ltree || subpath(path, nlevel('1.5'::ltree)) END
           WHERE path <@ '1.5'::ltree
           RETURNING 1)
INSERT INTO move_costs SELECT 4, 'ltree', COUNT(*) FROM m;

SELECT model, rows_changed FROM move_costs ORDER BY ord;

-- Example 13: are all four models still correct after the move?
SELECT m.model,
       (m.office_diff = 0)      AS office_subtree_correct,
       (m.electronics_diff = 0) AS electronics_subtree_correct
FROM (
    SELECT 1 AS ord, 'adjacency list + recursive CTE' AS model, 0::bigint AS office_diff, 0::bigint AS electronics_diff
    UNION ALL
    SELECT 2, 'materialized path',
           pg_temp.sym_diff((SELECT array_agg(category_id) FROM cat_path WHERE path LIKE '8/%'), (SELECT array_agg(x) FROM pg_temp.subtree_adjacency(8) x)),
           pg_temp.sym_diff((SELECT array_agg(category_id) FROM cat_path WHERE path LIKE '1/%'), (SELECT array_agg(x) FROM pg_temp.subtree_adjacency(1) x))
    UNION ALL
    SELECT 3, 'closure table',
           pg_temp.sym_diff((SELECT array_agg(descendant_id) FROM cat_closure WHERE ancestor_id = 8), (SELECT array_agg(x) FROM pg_temp.subtree_adjacency(8) x)),
           pg_temp.sym_diff((SELECT array_agg(descendant_id) FROM cat_closure WHERE ancestor_id = 1), (SELECT array_agg(x) FROM pg_temp.subtree_adjacency(1) x))
    UNION ALL
    SELECT 4, 'ltree',
           pg_temp.sym_diff((SELECT array_agg(category_id) FROM cat_ltree WHERE path <@ '8'::ltree), (SELECT array_agg(x) FROM pg_temp.subtree_adjacency(8) x)),
           pg_temp.sym_diff((SELECT array_agg(category_id) FROM cat_ltree WHERE path <@ '1'::ltree), (SELECT array_agg(x) FROM pg_temp.subtree_adjacency(1) x))
) m
ORDER BY m.ord;

-- Example 14: what each model stores.
SELECT model, stored_rows
FROM (
    SELECT 1 AS ord, 'adjacency list + recursive CTE' AS model, (SELECT COUNT(*) FROM categories)  AS stored_rows
    UNION ALL SELECT 2, 'materialized path', (SELECT COUNT(*) FROM cat_path)
    UNION ALL SELECT 3, 'closure table',     (SELECT COUNT(*) FROM cat_closure)
    UNION ALL SELECT 4, 'ltree',             (SELECT COUNT(*) FROM cat_ltree)
) s
ORDER BY ord;
ROLLBACK;
