-- Exercise 13-01: refactor a tangled nested report into named, commented CTEs.
-- The report: for every customer with completed orders: orders, revenue, average order value, share of the
-- country's revenue, rank within the country, and whether they beat the country's average.
-- The nested version writes the per-customer revenue out FOUR times. The CTE version computes it once.

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

-- Part A: the refactored report. Expected: 26 rows.
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
ORDER BY revenue DESC, customer_id;

-- Part B: PROVE the rewrite is equivalent. Both queries are run, and compared with EXCEPT in both directions
-- (differences must be 0). Then count how often each version scans order_items: the nested one repeats the
-- aggregation, so it scans the table 4 times; the CTE version scans it once.
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
