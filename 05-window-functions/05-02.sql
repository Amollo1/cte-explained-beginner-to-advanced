-- Exercise 05-02: cumulative monthly revenue (completed orders).
-- The frame is written out explicitly (ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW).
-- The last running_total must equal the overall completed revenue: 184254.90.
WITH monthly_revenue AS (            -- grain: one row per month
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
),
running AS (
    SELECT month, revenue,
           SUM(revenue) OVER (ORDER BY month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total,
           SUM(revenue) OVER ()                                                                AS grand_total
    FROM monthly_revenue
)
SELECT month,
       ROUND(revenue, 2)                          AS revenue,
       ROUND(running_total, 2)                    AS running_total,
       ROUND(100 * running_total / grand_total, 1) AS cumulative_pct
FROM running
ORDER BY month;
