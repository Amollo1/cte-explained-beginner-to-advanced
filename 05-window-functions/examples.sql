-- Module 5 worked examples: CTEs + window functions.
-- Run:  psql -d cte_lab -f 05-window-functions/examples.sql

-- =====================================================================
-- Part A: what a window function is, and why a CTE is needed to filter it
-- =====================================================================

-- Example 1: GROUP BY collapses rows; a window function keeps them.
SELECT (SELECT COUNT(*) FROM (SELECT dept_id, AVG(salary) FROM employees GROUP BY dept_id) g) AS group_by_rows,
       (SELECT COUNT(*) FROM (SELECT AVG(salary) OVER (PARTITION BY dept_id) FROM employees) w) AS window_rows;

SELECT emp_id, first_name, dept_id, salary,
       ROUND(AVG(salary) OVER (PARTITION BY dept_id), 2) AS dept_avg
FROM employees
WHERE dept_id IN (2, 6)
ORDER BY dept_id, salary DESC
LIMIT 5;

-- Example 2: window functions are evaluated AFTER WHERE, so they cannot be used in it.
-- The DO block catches the error (SQLSTATE 42P20) so the file keeps running.
DO $$
BEGIN
    PERFORM 1 FROM employees WHERE ROW_NUMBER() OVER (ORDER BY salary) = 1;
EXCEPTION WHEN windowing_error THEN
    RAISE NOTICE 'Caught as expected: %', SQLERRM;
END $$;

-- Example 3: the fix is a CTE. Compute the window in the CTE, filter in the next step.
-- (This replaces the correlated subquery from Module 0, Example 6c, and must agree with it.)
WITH with_avg AS (
    SELECT emp_id, dept_id, salary,
           AVG(salary) OVER (PARTITION BY dept_id) AS dept_avg
    FROM employees
),
window_version AS (
    SELECT emp_id FROM with_avg WHERE salary > dept_avg
),
correlated_version AS (
    SELECT e.emp_id
    FROM employees e
    WHERE e.salary > (SELECT AVG(x.salary) FROM employees x WHERE x.dept_id = e.dept_id)
)
SELECT (SELECT COUNT(*) FROM window_version)     AS window_rows,
       (SELECT COUNT(*) FROM correlated_version) AS correlated_rows,
       (SELECT COUNT(*) FROM (SELECT * FROM window_version EXCEPT SELECT * FROM correlated_version) a)
     + (SELECT COUNT(*) FROM (SELECT * FROM correlated_version EXCEPT SELECT * FROM window_version) b) AS differences;

-- =====================================================================
-- Part B: ranking, ties, and top-N per group
-- =====================================================================

-- Example 4: ROW_NUMBER vs RANK vs DENSE_RANK when there are ties.
-- Many customers share the same order count, which makes the differences visible.
WITH order_counts AS (
    SELECT customer_id, COUNT(*) AS orders_placed
    FROM orders
    GROUP BY customer_id
)
SELECT customer_id,
       orders_placed,
       ROW_NUMBER() OVER (ORDER BY orders_placed DESC, customer_id) AS row_num,
       RANK()       OVER (ORDER BY orders_placed DESC)              AS rnk,
       DENSE_RANK() OVER (ORDER BY orders_placed DESC)              AS dense_rnk
FROM order_counts
ORDER BY orders_placed DESC, customer_id
LIMIT 8;

-- Example 5: top 3 products by revenue within each category.
-- The window is computed in one CTE; the filter (rn <= 3) happens in the final query.
WITH product_revenue AS (            -- grain: one row per product (completed orders)
    SELECT p.product_id, p.product_name, p.category_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM order_items i
    JOIN orders   o ON o.order_id   = i.order_id AND o.status = 'completed'
    JOIN products p ON p.product_id = i.product_id
    GROUP BY p.product_id, p.product_name, p.category_id
),
ranked AS (                          -- same grain, plus rank and share-of-category
    SELECT product_id, product_name, category_id, revenue,
           ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY revenue DESC, product_id) AS rn,
           ROUND(100 * revenue / SUM(revenue) OVER (PARTITION BY category_id), 1)        AS pct_of_category
    FROM product_revenue
)
SELECT c.category_name, r.rn AS rank_in_category, r.product_name,
       ROUND(r.revenue, 2) AS revenue, r.pct_of_category
FROM ranked r
JOIN categories c ON c.category_id = r.category_id
WHERE r.rn <= 3
ORDER BY c.category_name, r.rn;

-- Example 6: for the single top row per group, PostgreSQL also offers DISTINCT ON.
-- Both techniques must return the same top product per category.
WITH product_revenue AS (
    SELECT p.product_id, p.category_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM order_items i
    JOIN orders   o ON o.order_id   = i.order_id AND o.status = 'completed'
    JOIN products p ON p.product_id = i.product_id
    GROUP BY p.product_id, p.category_id
),
window_top1 AS (
    SELECT category_id, product_id
    FROM (SELECT category_id, product_id,
                 ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY revenue DESC, product_id) AS rn
          FROM product_revenue) t
    WHERE rn = 1
),
distinct_on_top1 AS (
    SELECT DISTINCT ON (category_id) category_id, product_id
    FROM product_revenue
    ORDER BY category_id, revenue DESC, product_id
)
SELECT (SELECT COUNT(*) FROM window_top1)      AS window_rows,
       (SELECT COUNT(*) FROM distinct_on_top1) AS distinct_on_rows,
       (SELECT COUNT(*) FROM (SELECT * FROM window_top1 EXCEPT SELECT * FROM distinct_on_top1) a)
     + (SELECT COUNT(*) FROM (SELECT * FROM distinct_on_top1 EXCEPT SELECT * FROM window_top1) b) AS differences;

-- =====================================================================
-- Part C: running totals and frames
-- =====================================================================

-- Example 7: running total and a 3-month moving average, with an explicit frame.
WITH monthly_revenue AS (            -- grain: one row per month (completed orders)
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
)
SELECT month,
       ROUND(revenue, 2) AS revenue,
       ROUND(SUM(revenue) OVER (ORDER BY month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS running_total,
       ROUND(AVG(revenue) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)         AS moving_avg_3m
FROM monthly_revenue
ORDER BY month
LIMIT 5;

-- Example 8: the default-frame gotcha. With ORDER BY and no frame, rows that tie on the
-- ORDER BY value are "peers" and ALL get the same running value. Orders share dates here.
WITH running AS (
    SELECT order_id, order_date,
           COUNT(*) OVER (ORDER BY order_date)                                                  AS running_default,
           COUNT(*) OVER (ORDER BY order_date, order_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_rows
    FROM orders
)
SELECT order_id, order_date, running_default, running_rows
FROM running
WHERE order_date BETWEEN '2025-03-10' AND '2025-03-14'
ORDER BY order_date, order_id;

-- =====================================================================
-- Part D: LAG / LEAD
-- =====================================================================

-- Example 9: month-over-month growth with LAG, plus the check that months are contiguous.
-- LAG looks at the previous ROW, not the previous MONTH, so gaps would corrupt the result.
WITH monthly_revenue AS (
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
),
with_prev AS (
    SELECT month, revenue, LAG(revenue) OVER (ORDER BY month) AS prev_revenue
    FROM monthly_revenue
)
SELECT month,
       ROUND(revenue, 2)      AS revenue,
       ROUND(prev_revenue, 2) AS prev_revenue,
       ROUND(100 * (revenue - prev_revenue) / NULLIF(prev_revenue, 0), 1) AS growth_pct
FROM with_prev
ORDER BY month
LIMIT 4;

SELECT (SELECT COUNT(DISTINCT date_trunc('month', order_date)) FROM orders WHERE status = 'completed') AS months_with_data,
       (SELECT COUNT(*) FROM generate_series(
            (SELECT date_trunc('month', MIN(order_date)) FROM orders WHERE status = 'completed'),
            (SELECT date_trunc('month', MAX(order_date)) FROM orders WHERE status = 'completed'),
            interval '1 month'))                                                                    AS months_expected;

-- Example 10: days since the same customer's previous order (PARTITION BY + LAG).
SELECT customer_id, order_id, order_date,
       LAG(order_date) OVER w                AS prev_order_date,
       order_date - LAG(order_date) OVER w   AS days_since_prev
FROM orders
WHERE customer_id = 4
WINDOW w AS (PARTITION BY customer_id ORDER BY order_date, order_id)    -- a NAMED window, reused twice
ORDER BY order_date, order_id
LIMIT 5;
