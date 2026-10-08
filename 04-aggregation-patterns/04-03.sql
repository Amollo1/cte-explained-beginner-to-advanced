-- Exercise 04-03: category report with revenue, units sold and number of products.
-- Sales are summarised to the PRODUCT grain first. The join to products then has one
-- row per product, so COUNT(*) really is the number of products (no DISTINCT needed).
-- LEFT JOIN keeps products that have no completed sales.
WITH product_sales AS (              -- grain: one row per product (completed orders only)
    SELECT i.product_id,
           SUM(i.quantity)                                    AS units_sold,
           SUM(i.quantity * p.unit_price * (1 - i.discount))  AS revenue
    FROM order_items i
    JOIN orders   o ON o.order_id   = i.order_id AND o.status = 'completed'
    JOIN products p ON p.product_id = i.product_id
    GROUP BY i.product_id
)
SELECT c.category_name,
       COUNT(*)                                AS products,
       COALESCE(SUM(ps.units_sold), 0)         AS units_sold,
       ROUND(COALESCE(SUM(ps.revenue), 0), 2)  AS revenue
FROM products p
JOIN categories c ON c.category_id = p.category_id
LEFT JOIN product_sales ps ON ps.product_id = p.product_id
GROUP BY c.category_name
ORDER BY revenue DESC, c.category_name;
