-- Module 3 worked examples: multiple and chained CTEs.
-- Run:  psql -d cte_lab -f 03-chained-ctes/examples.sql

-- Example 1: a three-step pipeline. Each CTE has ONE job and a stated GRAIN.
-- Question: who are the top 5 customers by revenue (completed orders)?
WITH order_totals AS (            -- grain: one row per completed order
    SELECT o.order_id,
           o.customer_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS items_revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.order_id, o.customer_id
),
customer_totals AS (              -- grain: one row per customer
    SELECT customer_id,
           COUNT(*)           AS orders,
           SUM(items_revenue) AS revenue
    FROM order_totals
    GROUP BY customer_id
),
customer_rank AS (                -- same grain, plus a rank column
    SELECT customer_id, orders, revenue,
           RANK() OVER (ORDER BY revenue DESC) AS revenue_rank
    FROM customer_totals
)
SELECT r.revenue_rank, c.customer_name, c.country, r.orders, ROUND(r.revenue, 2) AS revenue
FROM customer_rank r
JOIN customers c ON c.customer_id = r.customer_id
WHERE r.revenue_rank <= 5
ORDER BY r.revenue_rank, c.customer_id;

-- Example 2: check the GRAIN of a step. Rows must equal distinct keys.
WITH order_totals AS (
    SELECT o.order_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS items_revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.order_id
)
SELECT COUNT(*)                 AS row_count,
       COUNT(DISTINCT order_id) AS distinct_orders,
       COUNT(*) = COUNT(DISTINCT order_id) AS grain_is_one_row_per_order
FROM order_totals;

-- Example 3: debug a chain by swapping the FINAL select to inspect any step.
WITH order_totals AS (
    SELECT o.order_id, o.customer_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS items_revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.order_id, o.customer_id
),
customer_totals AS (
    SELECT customer_id, COUNT(*) AS orders, SUM(items_revenue) AS revenue
    FROM order_totals
    GROUP BY customer_id
)
-- SELECT * FROM order_totals LIMIT 5;       -- <- inspect step 1 instead
SELECT customer_id, orders, ROUND(revenue, 2) AS revenue
FROM customer_totals                           -- <- inspect step 2
ORDER BY revenue DESC
LIMIT 3;

-- Example 4: two INDEPENDENT CTEs joined on a shared key (month).
WITH monthly_orders AS (          -- grain: one row per month, ALL orders
    SELECT date_trunc('month', order_date)::date AS month,
           COUNT(*) AS orders_placed
    FROM orders
    GROUP BY 1
),
monthly_revenue AS (              -- grain: one row per month, completed revenue only
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
)
SELECT mo.month, mo.orders_placed, ROUND(COALESCE(mr.revenue, 0), 2) AS completed_revenue
FROM monthly_orders mo
LEFT JOIN monthly_revenue mr ON mr.month = mo.month
ORDER BY mo.month
LIMIT 4;

-- Example 5: the join-type pitfall. Orders vs cancellations per month.
-- Many months have NO cancellations, so an INNER JOIN silently drops them.
WITH monthly_orders AS (
    SELECT date_trunc('month', order_date)::date AS month, COUNT(*) AS orders_placed
    FROM orders GROUP BY 1
),
monthly_cancelled AS (
    SELECT date_trunc('month', order_date)::date AS month, COUNT(*) AS cancelled
    FROM orders WHERE status = 'cancelled' GROUP BY 1
)
SELECT (SELECT COUNT(*) FROM monthly_orders)                                       AS months_total,
       (SELECT COUNT(*) FROM monthly_orders mo JOIN monthly_cancelled mc
                             ON mc.month = mo.month)                               AS months_with_inner_join,
       (SELECT COUNT(*) FROM monthly_orders mo LEFT JOIN monthly_cancelled mc
                             ON mc.month = mo.month)                               AS months_with_left_join;

-- Example 6: anti-join, three ways. Customers who have never ordered.
WITH ordering_customers AS (
    SELECT DISTINCT customer_id FROM orders
)
SELECT c.customer_id, c.customer_name
FROM customers c
LEFT JOIN ordering_customers oc ON oc.customer_id = c.customer_id
WHERE oc.customer_id IS NULL
ORDER BY c.customer_id;                                    -- (a) LEFT JOIN ... IS NULL

SELECT c.customer_id, c.customer_name
FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id)
ORDER BY c.customer_id;                                    -- (b) NOT EXISTS

SELECT c.customer_id, c.customer_name
FROM customers c
WHERE c.customer_id NOT IN (SELECT customer_id FROM orders)
ORDER BY c.customer_id;                                    -- (c) NOT IN (safe only if no NULLs)

-- Example 7: the NOT IN trap. One NULL in the list makes NOT IN return NOTHING.
SELECT COUNT(*) AS not_exists_result
FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM (SELECT customer_id FROM orders UNION ALL SELECT NULL) o
                  WHERE o.customer_id = c.customer_id);                  -- 4 (correct)

SELECT COUNT(*) AS not_in_result
FROM customers c
WHERE c.customer_id NOT IN (SELECT customer_id FROM orders UNION ALL SELECT NULL);  -- 0 (wrong!)
