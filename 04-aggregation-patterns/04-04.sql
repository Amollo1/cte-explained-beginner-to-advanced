-- Exercise 04-04: signup-year cohorts and time to first order.
-- NOTE: the brief "within 30 days" would show 0 in every cohort in this dataset
-- (orders start in 2025, customers signed up in 2023-2024), so we use 365 days.
-- Always inspect the distribution before choosing a threshold (see examples.sql, Example 8).
WITH first_orders AS (               -- grain: one row per customer who has ordered
    SELECT customer_id, MIN(order_date) AS first_order_date
    FROM orders
    GROUP BY customer_id
),
customer_cohorts AS (                -- grain: one row per customer
    SELECT c.customer_id,
           EXTRACT(YEAR FROM c.signup_date)::int AS signup_year,
           f.first_order_date,
           f.first_order_date - c.signup_date    AS days_to_first_order
    FROM customers c
    LEFT JOIN first_orders f ON f.customer_id = c.customer_id
)
SELECT signup_year,
       COUNT(*)                                              AS customers,
       COUNT(first_order_date)                               AS ordered,
       ROUND(100.0 * COUNT(first_order_date) / COUNT(*), 1)  AS pct_ordered,
       ROUND(AVG(days_to_first_order))                       AS avg_days_to_first_order,
       COUNT(*) FILTER (WHERE days_to_first_order <= 365)    AS ordered_within_365_days
FROM customer_cohorts
GROUP BY signup_year
ORDER BY signup_year;
