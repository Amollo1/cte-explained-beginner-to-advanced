-- Exercise 03-02: monthly order count and monthly completed revenue, side by side.
-- Two independent CTEs with different sources and filters, joined on month.
-- LEFT JOIN from monthly_orders + COALESCE guarantees a month is never dropped.
WITH monthly_orders AS (
    SELECT date_trunc('month', order_date)::date AS month,
           COUNT(*) AS orders_placed
    FROM orders
    GROUP BY 1
),
monthly_revenue AS (
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
)
SELECT mo.month,
       mo.orders_placed,
       ROUND(COALESCE(mr.revenue, 0), 2) AS completed_revenue
FROM monthly_orders mo
LEFT JOIN monthly_revenue mr ON mr.month = mo.month
ORDER BY mo.month;
