-- Exercise 05-04: days between each customer's consecutive orders (all statuses),
-- summarised per customer. Customers with a single order have no gap and are excluded.
--   order_gaps       grain: one row per order (the first order of each customer has NULL gap)
--   customer_gaps    grain: one row per customer with at least 2 orders
-- order_id is part of the window ORDER BY so same-day orders have a stable sequence.
WITH order_gaps AS (
    SELECT customer_id, order_id, order_date,
           order_date - LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date, order_id) AS days_since_prev
    FROM orders
),
customer_gaps AS (
    SELECT customer_id,
           COUNT(*)                        AS orders,
           ROUND(AVG(days_since_prev), 1)  AS avg_gap_days,
           MAX(days_since_prev)            AS max_gap_days
    FROM order_gaps
    GROUP BY customer_id
    HAVING COUNT(*) >= 2
)
SELECT c.customer_id, c.customer_name, g.orders, g.avg_gap_days, g.max_gap_days
FROM customer_gaps g
JOIN customers c ON c.customer_id = g.customer_id
ORDER BY g.avg_gap_days, c.customer_id;
