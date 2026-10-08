-- Module 2 worked examples: CTE vs subquery vs view vs temp table vs materialized view.
-- Run:  psql -d cte_lab -f 02-cte-vs-alternatives/examples.sql
-- (pgAdmin: highlight one example at a time and press F5 to see its result.)

-- Clean slate so the file can be re-run safely
DROP VIEW IF EXISTS v_monthly_revenue;
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_revenue;
DROP TABLE IF EXISTS tmp_monthly_revenue;

-- =====================================================================
-- Part A: CTE vs subquery
-- Question: which customers placed MORE orders than the average customer
-- (average taken over customers who have ordered)?
-- =====================================================================

-- Example 1: subquery version
SELECT oc.customer_id, oc.orders_placed
FROM (SELECT customer_id, COUNT(*) AS orders_placed
      FROM orders
      GROUP BY customer_id) oc
WHERE oc.orders_placed > (SELECT AVG(orders_placed)
                          FROM (SELECT COUNT(*) AS orders_placed
                                FROM orders
                                GROUP BY customer_id) x)
ORDER BY oc.orders_placed DESC, oc.customer_id;

-- Example 2: CTE version (the per-customer count is written ONCE)
WITH order_counts AS (
    SELECT customer_id, COUNT(*) AS orders_placed
    FROM orders
    GROUP BY customer_id
),
avg_orders AS (
    SELECT AVG(orders_placed) AS avg_orders
    FROM order_counts
)
SELECT oc.customer_id, oc.orders_placed
FROM order_counts oc
CROSS JOIN avg_orders a
WHERE oc.orders_placed > a.avg_orders
ORDER BY oc.orders_placed DESC, oc.customer_id;

-- Example 3: prove the two versions return identical rows (both counts must be 0)
WITH order_counts AS (
    SELECT customer_id, COUNT(*) AS orders_placed FROM orders GROUP BY customer_id
),
cte_version AS (
    SELECT oc.customer_id, oc.orders_placed
    FROM order_counts oc
    WHERE oc.orders_placed > (SELECT AVG(orders_placed) FROM order_counts)
),
subquery_version AS (
    SELECT oc.customer_id, oc.orders_placed
    FROM (SELECT customer_id, COUNT(*) AS orders_placed FROM orders GROUP BY customer_id) oc
    WHERE oc.orders_placed > (SELECT AVG(orders_placed)
                              FROM (SELECT COUNT(*) AS orders_placed FROM orders GROUP BY customer_id) x)
)
SELECT (SELECT COUNT(*) FROM (SELECT * FROM subquery_version EXCEPT SELECT * FROM cte_version) a) AS only_in_subquery,
       (SELECT COUNT(*) FROM (SELECT * FROM cte_version EXCEPT SELECT * FROM subquery_version) b) AS only_in_cte;

-- Example 4: compare the two plans. Numbers vary by machine; the SHAPE is what matters.
EXPLAIN
SELECT oc.customer_id, oc.orders_placed
FROM (SELECT customer_id, COUNT(*) AS orders_placed FROM orders GROUP BY customer_id) oc
WHERE oc.orders_placed > (SELECT AVG(orders_placed)
                          FROM (SELECT COUNT(*) AS orders_placed FROM orders GROUP BY customer_id) x);

EXPLAIN
WITH order_counts AS (
    SELECT customer_id, COUNT(*) AS orders_placed FROM orders GROUP BY customer_id
)
SELECT oc.customer_id, oc.orders_placed
FROM order_counts oc
WHERE oc.orders_placed > (SELECT AVG(orders_placed) FROM order_counts);

-- =====================================================================
-- Part B: reuse. A CTE referenced twice is computed once (materialized)
-- =====================================================================

-- Example 5: each category's share of total completed-order revenue
WITH category_revenue AS (
    SELECT c.category_name,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM order_items i
    JOIN orders     o ON o.order_id    = i.order_id AND o.status = 'completed'
    JOIN products   p ON p.product_id  = i.product_id
    JOIN categories c ON c.category_id = p.category_id
    GROUP BY c.category_name
),
grand_total AS (
    SELECT SUM(revenue) AS total_revenue FROM category_revenue
)
SELECT cr.category_name,
       ROUND(cr.revenue, 2)                          AS revenue,
       ROUND(100 * cr.revenue / g.total_revenue, 1)  AS pct_of_total
FROM category_revenue cr
CROSS JOIN grand_total g
ORDER BY cr.revenue DESC, cr.category_name;

-- Example 6: look for "CTE Scan" in the plan: category_revenue is referenced twice,
-- so PostgreSQL computes it once and scans the stored result twice.
EXPLAIN
WITH category_revenue AS (
    SELECT p.category_id, SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM order_items i JOIN products p ON p.product_id = i.product_id
    GROUP BY p.category_id
)
SELECT category_id, revenue, revenue / (SELECT SUM(revenue) FROM category_revenue) AS share
FROM category_revenue;

-- =====================================================================
-- Part C: the persistent alternatives
-- =====================================================================

-- Example 7: VIEW = a saved query. No data is stored; it runs every time.
CREATE VIEW v_monthly_revenue AS
SELECT date_trunc('month', o.order_date)::date AS month,
       COUNT(DISTINCT o.order_id)              AS orders,
       ROUND(SUM(i.quantity * p.unit_price * (1 - i.discount)), 2) AS revenue
FROM orders o
JOIN order_items i ON i.order_id   = o.order_id
JOIN products    p ON p.product_id = i.product_id
WHERE o.status = 'completed'
GROUP BY 1;

SELECT * FROM v_monthly_revenue ORDER BY month LIMIT 3;   -- usable from ANY later statement

-- Example 8: TEMP TABLE = stored rows, private to your session, can be indexed.
CREATE TEMP TABLE tmp_monthly_revenue AS
SELECT * FROM v_monthly_revenue;

CREATE INDEX ON tmp_monthly_revenue (month);
ANALYZE tmp_monthly_revenue;      -- autovacuum does not analyze temp tables, so do it yourself

SELECT COUNT(*) AS rows_in_temp_table FROM tmp_monthly_revenue;   -- visible in a LATER statement

-- Example 9: MATERIALIZED VIEW = stored rows that persist, but go STALE until refreshed.
CREATE MATERIALIZED VIEW mv_monthly_revenue AS
SELECT * FROM v_monthly_revenue;

-- Stale-data demo. Inside a transaction we complete a pending order, then roll back.
BEGIN;
UPDATE orders SET status = 'completed' WHERE order_id = 2;   -- order 2 is 'pending'
SELECT (SELECT SUM(revenue) FROM v_monthly_revenue)  AS view_total,         -- sees the change
       (SELECT SUM(revenue) FROM mv_monthly_revenue) AS matview_total_stale; -- does NOT
ROLLBACK;

REFRESH MATERIALIZED VIEW mv_monthly_revenue;   -- how you would bring it up to date

-- Example 10: SELECT * freezes the column list inside a view at creation time
CREATE VIEW v_star AS SELECT * FROM departments;
ALTER TABLE departments ADD COLUMN budget NUMERIC;
SELECT COUNT(*) AS columns_in_view_after_alter
FROM information_schema.columns WHERE table_name = 'v_star';   -- still 3, not 4
ALTER TABLE departments DROP COLUMN budget;
DROP VIEW v_star;

-- Clean up
DROP MATERIALIZED VIEW mv_monthly_revenue;
DROP TABLE tmp_monthly_revenue;
DROP VIEW v_monthly_revenue;
