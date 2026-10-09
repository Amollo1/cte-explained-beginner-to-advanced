-- Exercise 08-02: gap-filling with a recursive calendar.
-- The calendar runs from the FIRST to the LAST order date, taken from the data, so that days
-- outside the data are never reported as fake zeros (see examples.sql, Example 7).
-- Part A: one row per month: days, days with orders, days without orders, orders.
WITH RECURSIVE bounds AS (
    SELECT MIN(order_date) AS first_day, MAX(order_date) AS last_day
    FROM orders
),
calendar(day) AS (                   -- grain: one row per calendar day
    SELECT first_day FROM bounds
    UNION ALL
    SELECT c.day + 1
    FROM calendar c
    CROSS JOIN bounds b
    WHERE c.day < b.last_day
),
daily_orders AS (                    -- grain: one row per day that HAS orders
    SELECT order_date AS day, COUNT(*) AS orders
    FROM orders
    GROUP BY order_date
),
filled AS (                          -- grain: one row per calendar day, zeros filled in
    SELECT c.day, COALESCE(d.orders, 0) AS orders
    FROM calendar c
    LEFT JOIN daily_orders d ON d.day = c.day
)
SELECT date_trunc('month', day)::date                  AS month,
       COUNT(*)                                        AS days,
       COUNT(*) FILTER (WHERE orders > 0)              AS days_with_orders,
       COUNT(*) FILTER (WHERE orders = 0)              AS days_without_orders,
       SUM(orders)                                     AS orders
FROM filled
GROUP BY 1
ORDER BY 1;

-- Part B: reconcile. The calendar must cover every day and account for every order.
WITH RECURSIVE bounds AS (
    SELECT MIN(order_date) AS first_day, MAX(order_date) AS last_day
    FROM orders
),
calendar(day) AS (                   -- grain: one row per calendar day
    SELECT first_day FROM bounds
    UNION ALL
    SELECT c.day + 1
    FROM calendar c
    CROSS JOIN bounds b
    WHERE c.day < b.last_day
),
daily_orders AS (                    -- grain: one row per day that HAS orders
    SELECT order_date AS day, COUNT(*) AS orders
    FROM orders
    GROUP BY order_date
),
filled AS (                          -- grain: one row per calendar day, zeros filled in
    SELECT c.day, COALESCE(d.orders, 0) AS orders
    FROM calendar c
    LEFT JOIN daily_orders d ON d.day = c.day
)
SELECT (SELECT COUNT(*) FROM calendar)               AS calendar_days,
       (SELECT last_day - first_day + 1 FROM bounds) AS expected_days,
       (SELECT SUM(orders) FROM filled)              AS orders_via_calendar,
       (SELECT COUNT(*) FROM orders)                 AS orders_total,
       (SELECT COUNT(*) FROM filled WHERE orders = 0) AS days_with_no_orders;
