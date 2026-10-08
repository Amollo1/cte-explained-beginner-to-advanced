-- Exercise 02-02: each category's share of total revenue (completed orders only).
-- category_revenue is referenced twice (by grand_total and by the final query),
-- so the expensive join + aggregation is written once and computed once.
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
    SELECT SUM(revenue) AS total_revenue
    FROM category_revenue
)
SELECT cr.category_name,
       ROUND(cr.revenue, 2)                         AS revenue,
       ROUND(100 * cr.revenue / g.total_revenue, 1) AS pct_of_total
FROM category_revenue cr
CROSS JOIN grand_total g
ORDER BY cr.revenue DESC, cr.category_name;
