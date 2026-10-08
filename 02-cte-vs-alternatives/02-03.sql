-- Exercise 02-03: build the SAME monthly revenue report four ways and prove they match.
-- The four containers: CTE, view, temp table, materialized view.
-- (The written decision note is your own markdown; see exercises.md for a model answer.)

-- Clean slate so the file is re-runnable
DROP VIEW IF EXISTS v_monthly_revenue;
DROP MATERIALIZED VIEW IF EXISTS mv_monthly_revenue;
DROP TABLE IF EXISTS tmp_monthly_revenue;

-- 1) VIEW
CREATE VIEW v_monthly_revenue AS
SELECT date_trunc('month', o.order_date)::date AS month,
       COUNT(DISTINCT o.order_id)              AS orders,
       ROUND(SUM(i.quantity * p.unit_price * (1 - i.discount)), 2) AS revenue
FROM orders o
JOIN order_items i ON i.order_id   = o.order_id
JOIN products    p ON p.product_id = i.product_id
WHERE o.status = 'completed'
GROUP BY 1;

-- 2) TEMP TABLE (session-scoped copy of the data)
CREATE TEMP TABLE tmp_monthly_revenue AS
SELECT * FROM v_monthly_revenue;

-- 3) MATERIALIZED VIEW (persistent copy, refreshed on demand)
CREATE MATERIALIZED VIEW mv_monthly_revenue AS
SELECT * FROM v_monthly_revenue;

-- 4) CTE, compared against the other three (every diff must be 0)
WITH cte_version AS (
    SELECT date_trunc('month', o.order_date)::date AS month,
           COUNT(DISTINCT o.order_id)              AS orders,
           ROUND(SUM(i.quantity * p.unit_price * (1 - i.discount)), 2) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
)
SELECT (SELECT COUNT(*) FROM cte_version) AS months,
       (SELECT COUNT(*) FROM (SELECT * FROM cte_version EXCEPT SELECT * FROM v_monthly_revenue) a)
     + (SELECT COUNT(*) FROM (SELECT * FROM v_monthly_revenue EXCEPT SELECT * FROM cte_version) b)  AS view_diff,
       (SELECT COUNT(*) FROM (SELECT * FROM cte_version EXCEPT SELECT * FROM tmp_monthly_revenue) c)
     + (SELECT COUNT(*) FROM (SELECT * FROM tmp_monthly_revenue EXCEPT SELECT * FROM cte_version) d) AS temp_diff,
       (SELECT COUNT(*) FROM (SELECT * FROM cte_version EXCEPT SELECT * FROM mv_monthly_revenue) e)
     + (SELECT COUNT(*) FROM (SELECT * FROM mv_monthly_revenue EXCEPT SELECT * FROM cte_version) f) AS matview_diff;

-- Clean up
DROP MATERIALIZED VIEW mv_monthly_revenue;
DROP TABLE tmp_monthly_revenue;
DROP VIEW v_monthly_revenue;
