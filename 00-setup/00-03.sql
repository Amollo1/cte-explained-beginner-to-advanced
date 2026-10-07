-- Exercise 00-03: revenue per product category, completed orders only.
-- revenue = quantity * unit_price * (1 - discount)
-- Note: products point to LEAF categories, so this is revenue per leaf category.
-- (Module 9 rolls revenue up to top-level categories with a recursive CTE.)
SELECT c.category_name,
       ROUND(SUM(i.quantity * p.unit_price * (1 - i.discount)), 2) AS revenue
FROM order_items i
JOIN orders     o ON o.order_id    = i.order_id AND o.status = 'completed'
JOIN products   p ON p.product_id  = i.product_id
JOIN categories c ON c.category_id = p.category_id
GROUP BY c.category_name
ORDER BY revenue DESC, c.category_name;
