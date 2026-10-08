-- Exercise 04-02: revenue per country, completed vs cancelled, using FILTER.
-- The line-revenue expression is written ONCE, in a CTE at the order-line grain.
-- Item revenue lives at that grain, so summing it over the item-level join is safe.
WITH order_lines AS (                -- grain: one row per order line
    SELECT o.status,
           c.country,
           i.quantity * p.unit_price * (1 - i.discount) AS line_revenue
    FROM orders o
    JOIN customers   c ON c.customer_id = o.customer_id
    JOIN order_items i ON i.order_id    = o.order_id
    JOIN products    p ON p.product_id  = i.product_id
)
SELECT country,
       ROUND(COALESCE(SUM(line_revenue) FILTER (WHERE status = 'completed'), 0), 2) AS completed_revenue,
       ROUND(COALESCE(SUM(line_revenue) FILTER (WHERE status = 'cancelled'), 0), 2) AS cancelled_revenue
FROM order_lines
GROUP BY country
ORDER BY completed_revenue DESC, country;
