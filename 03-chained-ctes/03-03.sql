-- Exercise 03-03: customers who never placed an order (anti-join).
-- Part A: the answer, using a CTE and LEFT JOIN ... IS NULL.
WITH ordering_customers AS (
    SELECT DISTINCT customer_id
    FROM orders
)
SELECT c.customer_id, c.customer_name, c.signup_date
FROM customers c
LEFT JOIN ordering_customers oc ON oc.customer_id = c.customer_id
WHERE oc.customer_id IS NULL
ORDER BY c.customer_id;

-- Part B: all three techniques must agree (orders.customer_id has no NULLs, so NOT IN is safe here).
SELECT
  (SELECT COUNT(*) FROM customers c
   LEFT JOIN (SELECT DISTINCT customer_id FROM orders) oc ON oc.customer_id = c.customer_id
   WHERE oc.customer_id IS NULL)                                                       AS left_join_count,
  (SELECT COUNT(*) FROM customers c
   WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id))      AS not_exists_count,
  (SELECT COUNT(*) FROM customers c
   WHERE c.customer_id NOT IN (SELECT customer_id FROM orders))                        AS not_in_count;
