-- Exercise 03-01: top 5 customers by revenue (completed orders), via three chained CTEs.
--   order_totals    grain: one row per completed order
--   customer_totals grain: one row per customer
--   customer_rank   same grain, adds a rank (RANK() is explained fully in Module 5)
-- RANK() gives tied customers the same rank, so more than 5 rows are possible if there is a tie.
WITH order_totals AS (
    SELECT o.order_id,
           o.customer_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS items_revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.order_id, o.customer_id
),
customer_totals AS (
    SELECT customer_id,
           COUNT(*)           AS orders,
           SUM(items_revenue) AS revenue
    FROM order_totals
    GROUP BY customer_id
),
customer_rank AS (
    SELECT customer_id, orders, revenue,
           RANK() OVER (ORDER BY revenue DESC) AS revenue_rank
    FROM customer_totals
)
SELECT r.revenue_rank,
       c.customer_name,
       c.country,
       r.orders,
       ROUND(r.revenue, 2) AS revenue
FROM customer_rank r
JOIN customers c ON c.customer_id = r.customer_id
WHERE r.revenue_rank <= 5
ORDER BY r.revenue_rank, c.customer_id;
