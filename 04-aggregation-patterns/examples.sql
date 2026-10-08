-- Module 4 worked examples: aggregation and joins without double counting.
-- Run:  psql -d cte_lab -f 04-aggregation-patterns/examples.sql

-- =====================================================================
-- Part A: the fan-out trap
-- orders has ONE row per order (shipping_fee lives here).
-- order_items has MANY rows per order. Joining them repeats each order row.
-- =====================================================================

-- Example 1: compare the control total with the total after the join
SELECT (SELECT SUM(shipping_fee) FROM orders)                                   AS true_shipping_total,
       (SELECT SUM(o.shipping_fee)
        FROM orders o JOIN order_items i ON i.order_id = o.order_id)            AS shipping_after_join,
       (SELECT COUNT(*) FROM orders)                                            AS order_rows,
       (SELECT COUNT(*)
        FROM orders o JOIN order_items i ON i.order_id = o.order_id)            AS joined_rows;

-- Example 2: the tempting wrong fix. SUM(DISTINCT) adds up distinct VALUES (0+5+10+15)
SELECT SUM(DISTINCT o.shipping_fee) AS sum_distinct_is_not_a_fix
FROM orders o JOIN order_items i ON i.order_id = o.order_id;

-- Example 3: the right fix. Aggregate items to the ORDER grain first, then join.
WITH order_item_totals AS (          -- grain: one row per order
    SELECT i.order_id,
           SUM(i.quantity)                                    AS units,
           SUM(i.quantity * p.unit_price * (1 - i.discount))  AS items_revenue
    FROM order_items i
    JOIN products p ON p.product_id = i.product_id
    GROUP BY i.order_id
)
SELECT COUNT(*)                          AS orders,
       SUM(o.shipping_fee)               AS shipping_total,     -- correct: 870
       SUM(t.units)                      AS units,
       ROUND(SUM(t.items_revenue), 2)    AS items_revenue
FROM orders o
LEFT JOIN order_item_totals t ON t.order_id = o.order_id;

-- Example 4: a measure is safe to SUM at the grain where it LIVES.
-- Item revenue lives on order_items, so summing it over an item-level join is correct.
-- Compute the expression ONCE, at the item grain, in a CTE.
WITH order_lines AS (                -- grain: one row per order line
    SELECT o.order_id, o.status, c.country,
           i.quantity * p.unit_price * (1 - i.discount) AS line_revenue
    FROM orders o
    JOIN customers   c ON c.customer_id = o.customer_id
    JOIN order_items i ON i.order_id    = o.order_id
    JOIN products    p ON p.product_id  = i.product_id
)
SELECT country,
       ROUND(SUM(line_revenue) FILTER (WHERE status = 'completed'), 2)               AS completed_filter,
       ROUND(SUM(CASE WHEN status = 'completed' THEN line_revenue END), 2)           AS completed_case,
       ROUND(COALESCE(SUM(line_revenue) FILTER (WHERE status = 'cancelled'), 0), 2)  AS cancelled
FROM order_lines
GROUP BY country
ORDER BY country;

-- Example 5: RECONCILE. The breakdown must add up to an independent control total.
WITH order_lines AS (
    SELECT o.status, c.country,
           i.quantity * p.unit_price * (1 - i.discount) AS line_revenue
    FROM orders o
    JOIN customers   c ON c.customer_id = o.customer_id
    JOIN order_items i ON i.order_id    = o.order_id
    JOIN products    p ON p.product_id  = i.product_id
),
by_country AS (
    SELECT country, SUM(line_revenue) AS completed
    FROM order_lines
    WHERE status = 'completed'
    GROUP BY country
)
SELECT ROUND((SELECT SUM(completed) FROM by_country), 2) AS sum_of_countries,
       ROUND((SELECT SUM(i.quantity * p.unit_price * (1 - i.discount))
              FROM orders o
              JOIN order_items i ON i.order_id   = o.order_id
              JOIN products    p ON p.product_id = i.product_id
              WHERE o.status = 'completed'), 2)               AS control_total;

-- =====================================================================
-- Part B: two different grains in one report (category report)
-- =====================================================================

-- Example 6: the naive version. COUNT(*) counts joined ROWS, not products.
SELECT c.category_name,
       COUNT(*)                    AS products_wrong,
       COUNT(DISTINCT p.product_id) AS products_distinct_band_aid
FROM categories c
JOIN products    p ON p.category_id = c.category_id
JOIN order_items i ON i.product_id  = p.product_id
JOIN orders      o ON o.order_id    = i.order_id AND o.status = 'completed'
GROUP BY c.category_name
ORDER BY c.category_name;

-- Example 7: the robust version. Summarise sales to the PRODUCT grain, then join.
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
       COUNT(*)                                AS products,       -- one row per product: correct
       COALESCE(SUM(ps.units_sold), 0)         AS units_sold,
       ROUND(COALESCE(SUM(ps.revenue), 0), 2)  AS revenue
FROM products p
JOIN categories c ON c.category_id = p.category_id
LEFT JOIN product_sales ps ON ps.product_id = p.product_id       -- keeps unsold products
GROUP BY c.category_name
ORDER BY revenue DESC, c.category_name;

-- =====================================================================
-- Part C: cohorts, and averages at the right grain
-- =====================================================================

-- Example 8: look at the DISTRIBUTION before choosing a threshold.
-- (A "within 30 days" cutoff would show 0 everywhere in this dataset.)
WITH first_orders AS (
    SELECT customer_id, MIN(order_date) AS first_order_date
    FROM orders GROUP BY customer_id
)
SELECT MIN(f.first_order_date - c.signup_date)                               AS min_days,
       ROUND(AVG(f.first_order_date - c.signup_date))                        AS avg_days,
       MAX(f.first_order_date - c.signup_date)                               AS max_days,
       COUNT(*) FILTER (WHERE f.first_order_date - c.signup_date <= 30)      AS within_30_days,
       COUNT(*) FILTER (WHERE f.first_order_date - c.signup_date <= 365)     AS within_365_days
FROM customers c
JOIN first_orders f ON f.customer_id = c.customer_id;

-- Example 9: the cohort report. LEFT JOIN keeps customers who never ordered.
WITH first_orders AS (               -- grain: one row per customer who has ordered
    SELECT customer_id, MIN(order_date) AS first_order_date
    FROM orders GROUP BY customer_id
),
customer_cohorts AS (                -- grain: one row per customer
    SELECT c.customer_id,
           EXTRACT(YEAR FROM c.signup_date)::int      AS signup_year,
           f.first_order_date,
           f.first_order_date - c.signup_date         AS days_to_first_order
    FROM customers c
    LEFT JOIN first_orders f ON f.customer_id = c.customer_id
)
SELECT signup_year,
       COUNT(*)                                          AS customers,
       COUNT(first_order_date)                           AS ordered,
       ROUND(100.0 * COUNT(first_order_date) / COUNT(*), 1) AS pct_ordered,
       ROUND(AVG(days_to_first_order))                   AS avg_days_to_first_order,
       COUNT(*) FILTER (WHERE days_to_first_order <= 365) AS ordered_within_365_days
FROM customer_cohorts
GROUP BY signup_year
ORDER BY signup_year;

-- Example 10: averages at the wrong grain. "Average order value" is revenue per ORDER.
-- AVG over line items gives the average LINE value instead.
SELECT (SELECT ROUND(AVG(i.quantity * p.unit_price * (1 - i.discount)), 2)
        FROM orders o
        JOIN order_items i ON i.order_id   = o.order_id
        JOIN products    p ON p.product_id = i.product_id
        WHERE o.status = 'completed')                                           AS avg_line_value_wrong,
       (SELECT ROUND(SUM(i.quantity * p.unit_price * (1 - i.discount))
                     / COUNT(DISTINCT o.order_id), 2)
        FROM orders o
        JOIN order_items i ON i.order_id   = o.order_id
        JOIN products    p ON p.product_id = i.product_id
        WHERE o.status = 'completed')                                           AS avg_order_value_right;
