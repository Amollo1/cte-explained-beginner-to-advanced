-- Exercise 02-01: customers with more orders than the average customer.
-- "Average customer" = average orders per customer who has ordered (26 customers; all statuses counted).
-- Part A: the CTE version.
WITH order_counts AS (
    SELECT customer_id, COUNT(*) AS orders_placed
    FROM orders
    GROUP BY customer_id
),
avg_orders AS (
    SELECT AVG(orders_placed) AS avg_orders
    FROM order_counts
)
SELECT c.customer_id,
       c.customer_name,
       oc.orders_placed,
       ROUND(a.avg_orders, 2) AS avg_orders
FROM order_counts oc
JOIN customers c ON c.customer_id = oc.customer_id
CROSS JOIN avg_orders a
WHERE oc.orders_placed > a.avg_orders
ORDER BY oc.orders_placed DESC, c.customer_id;

-- Part B: prove it matches the subquery version (both counts must be 0).
-- To compare plans yourself, run EXPLAIN on each version separately (see exercises.md).
WITH order_counts AS (
    SELECT customer_id, COUNT(*) AS orders_placed FROM orders GROUP BY customer_id
),
cte_version AS (
    SELECT customer_id FROM order_counts
    WHERE orders_placed > (SELECT AVG(orders_placed) FROM order_counts)
),
subquery_version AS (
    SELECT customer_id
    FROM (SELECT customer_id, COUNT(*) AS orders_placed FROM orders GROUP BY customer_id) oc
    WHERE orders_placed > (SELECT AVG(orders_placed)
                           FROM (SELECT COUNT(*) AS orders_placed FROM orders GROUP BY customer_id) x)
)
SELECT (SELECT COUNT(*) FROM (SELECT * FROM subquery_version EXCEPT SELECT * FROM cte_version) a) AS only_in_subquery,
       (SELECT COUNT(*) FROM (SELECT * FROM cte_version EXCEPT SELECT * FROM subquery_version) b) AS only_in_cte;
