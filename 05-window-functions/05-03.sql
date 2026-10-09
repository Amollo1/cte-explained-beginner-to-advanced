-- Exercise 05-03: month-over-month revenue growth (completed orders).
-- LAG looks at the previous ROW. That is the previous MONTH only because the months are
-- contiguous (examples.sql, Example 9 checks this). NULLIF protects against divide-by-zero.
WITH monthly_revenue AS (            -- grain: one row per month
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
),
with_prev AS (
    SELECT month, revenue,
           LAG(revenue) OVER (ORDER BY month) AS prev_revenue
    FROM monthly_revenue
)
SELECT month,
       ROUND(revenue, 2)      AS revenue,
       ROUND(prev_revenue, 2) AS prev_revenue,
       ROUND(100 * (revenue - prev_revenue) / NULLIF(prev_revenue, 0), 1) AS growth_pct
FROM with_prev
ORDER BY month;
