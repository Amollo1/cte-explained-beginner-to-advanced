-- Module 8 worked examples: recursive CTE fundamentals.
-- Run:  psql -d cte_lab -f 08-recursive-basics/examples.sql

-- Test helper (session-only): runs a statement and RETURNS its error message instead of failing,
-- so this file can show errors on purpose and keep running.
CREATE OR REPLACE FUNCTION pg_temp.try_sql(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION
    WHEN query_canceled THEN RETURN 'CANCELED: ' || SQLERRM;   -- OTHERS does not catch query_canceled
    WHEN OTHERS         THEN RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- =====================================================================
-- Part A: how a recursive CTE runs
-- =====================================================================

-- Example 1: anchor + recursive term. The iteration column makes each round visible.
-- Round 0 is the anchor; each later round is built from the rows of the round before it.
WITH RECURSIVE powers(n, iteration) AS (
    SELECT 1, 0                              -- anchor member: the starting row
    UNION ALL
    SELECT n * 2, iteration + 1              -- recursive member: next row from the previous row
    FROM powers
    WHERE iteration < 5                      -- stop condition
)
SELECT iteration, n FROM powers ORDER BY iteration;

-- Example 2: numbers 1..10 by recursion. generate_series produces the same rows.
WITH RECURSIVE counter(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM counter WHERE n < 10
),
recursive_version AS (SELECT n FROM counter),
series_version    AS (SELECT g AS n FROM generate_series(1, 10) AS g)
SELECT (SELECT COUNT(*) FROM recursive_version) AS recursive_rows,
       (SELECT COUNT(*) FROM series_version)    AS series_rows,
       (SELECT COUNT(*) FROM (SELECT * FROM recursive_version EXCEPT SELECT * FROM series_version) a)
     + (SELECT COUNT(*) FROM (SELECT * FROM series_version EXCEPT SELECT * FROM recursive_version) b) AS differences;

-- Example 3: a LIMIT on the OUTER query stops even an infinite recursion, because rows are produced lazily.
-- Handy for exploring; do not rely on it in production (an ORDER BY or aggregate would hang).
WITH RECURSIVE forever(i) AS (
    SELECT 1
    UNION ALL
    SELECT i + 1 FROM forever            -- no stop condition!
)
SELECT i FROM forever LIMIT 5;

-- =====================================================================
-- Part B: series and gap-filling
-- =====================================================================

-- Example 4: every day in January 2026, by recursion (date + 1 adds one day). Compare with generate_series.
WITH RECURSIVE days(day) AS (
    SELECT DATE '2026-01-01'
    UNION ALL
    SELECT day + 1 FROM days WHERE day < DATE '2026-01-31'
),
recursive_version AS (SELECT day FROM days),
series_version    AS (SELECT g::date AS day FROM generate_series(DATE '2026-01-01', DATE '2026-01-31', INTERVAL '1 day') AS g)
SELECT (SELECT COUNT(*) FROM recursive_version) AS recursive_rows,
       (SELECT COUNT(*) FROM series_version)    AS series_rows,
       (SELECT COUNT(*) FROM (SELECT * FROM recursive_version EXCEPT SELECT * FROM series_version) a)
     + (SELECT COUNT(*) FROM (SELECT * FROM series_version EXCEPT SELECT * FROM recursive_version) b) AS differences;

-- Example 5: GAP-FILLING. A calendar with one row per day, built between the first and last order,
-- LEFT JOINed to the daily order counts so days with NO orders appear as zeros.
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
ORDER BY 1
LIMIT 4;

-- Example 6: reconcile. The calendar must account for every order, and cover every day.
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
       (SELECT COUNT(*) FROM orders)                 AS orders_total;

-- Example 7: the bounds trap. A calendar for ALL of 2026 reports July to December as "no orders",
-- but the data simply ends on 30 June. Those zeros are not real. Bounds must come from the data.
WITH RECURSIVE calendar_2026(day) AS (
    SELECT DATE '2026-01-01'
    UNION ALL
    SELECT day + 1 FROM calendar_2026 WHERE day < DATE '2026-12-31'
),
by_month AS (
    SELECT date_trunc('month', c.day)::date AS month,
           COUNT(o.order_id)                AS orders
    FROM calendar_2026 c
    LEFT JOIN orders o ON o.order_date = c.day
    GROUP BY 1
)
SELECT COUNT(*) FILTER (WHERE orders = 0) AS months_reported_as_zero_in_2026,
       (SELECT MAX(order_date) FROM orders) AS last_order_date
FROM by_month;

-- Example 8: gap-filling FIXES the LAG problem from Module 5. Inside a transaction we remove one
-- month of data. LAG on the data alone compares October with August; a month calendar compares it with September (0).
BEGIN;
UPDATE orders SET status = 'cancelled'
WHERE status = 'completed' AND date_trunc('month', order_date) = DATE '2025-09-01';

WITH RECURSIVE months(month) AS (
    SELECT date_trunc('month', MIN(order_date))::date FROM orders
    UNION ALL
    SELECT (month + INTERVAL '1 month')::date
    FROM months
    WHERE month < (SELECT date_trunc('month', MAX(order_date))::date FROM orders)
),
monthly_revenue AS (
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
),
naive AS (
    SELECT month, revenue,
           LAG(month)   OVER (ORDER BY month) AS prev_month,
           LAG(revenue) OVER (ORDER BY month) AS prev_revenue
    FROM monthly_revenue
),
filled AS (
    SELECT m.month, COALESCE(r.revenue, 0) AS revenue
    FROM months m
    LEFT JOIN monthly_revenue r ON r.month = m.month
),
filled_lag AS (
    SELECT month, revenue, LAG(revenue) OVER (ORDER BY month) AS prev_revenue
    FROM filled
)
SELECT (SELECT COUNT(*) FROM months)                                   AS calendar_months,
       (SELECT COUNT(*) FROM monthly_revenue)                          AS months_with_data,
       (SELECT prev_month FROM naive WHERE month = DATE '2025-10-01')  AS naive_compares_oct_with,
       (SELECT ROUND(100 * (revenue - prev_revenue) / NULLIF(prev_revenue, 0), 1)
        FROM naive WHERE month = DATE '2025-10-01')                    AS naive_growth_pct,
       (SELECT prev_revenue FROM filled_lag WHERE month = DATE '2025-10-01') AS calendar_prev_revenue,
       (SELECT ROUND(100 * (revenue - prev_revenue) / NULLIF(prev_revenue, 0), 1)
        FROM filled_lag WHERE month = DATE '2025-10-01')               AS calendar_growth_pct;
ROLLBACK;

-- =====================================================================
-- Part C: carrying several columns of state
-- =====================================================================

-- Example 9: Fibonacci and factorial together. Each row carries the state needed to build the next one.
-- numeric (not integer) so the factorial cannot overflow.
WITH RECURSIVE seq(n, fib, next_fib, factorial) AS (
    SELECT 1, 1::numeric, 1::numeric, 1::numeric
    UNION ALL
    SELECT n + 1, next_fib, fib + next_fib, factorial * (n + 1)
    FROM seq
    WHERE n < 8
)
SELECT n, fib, factorial FROM seq ORDER BY n;

-- Example 10: with bigint, factorial overflows at 21! (the error is returned, not raised).
SELECT pg_temp.try_sql($q$
    WITH RECURSIVE f(n, fact) AS (
        SELECT 1, 1::bigint
        UNION ALL
        SELECT n + 1, fact * (n + 1) FROM f WHERE n < 25
    ) SELECT * FROM f $q$) AS bigint_factorial_to_25;

-- =====================================================================
-- Part D: termination and safety
-- =====================================================================

-- Example 11: UNION removes rows already seen, so a cycle ends by itself. UNION ALL needs a guard.
WITH RECURSIVE c(n) AS (
    SELECT 1
    UNION                                  -- de-duplicates across iterations
    SELECT (n % 3) + 1 FROM c
)
SELECT array_agg(n ORDER BY n) AS union_ends_by_itself FROM c;

WITH RECURSIVE c(n, depth) AS (
    SELECT 1, 1
    UNION ALL
    SELECT (n % 3) + 1, depth + 1 FROM c WHERE depth < 10     -- the guard
)
SELECT COUNT(*) AS union_all_rows_until_guard FROM c;

-- Example 12: the rules of the recursive term. Each statement below is a mistake; the error comes back as text.
SELECT pg_temp.try_sql($q$ WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT MAX(i) + 1 FROM n WHERE i < 5) SELECT * FROM n $q$)
       AS aggregate_in_recursive_term;
SELECT pg_temp.try_sql($q$ WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT a.i + 1 FROM n a JOIN n b ON true WHERE a.i < 5) SELECT * FROM n $q$)
       AS referenced_twice;
SELECT pg_temp.try_sql($q$ WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < (SELECT MAX(i) + 3 FROM n)) SELECT * FROM n $q$)
       AS inside_expression_subquery;
SELECT pg_temp.try_sql($q$ WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 5 ORDER BY 1 LIMIT 2) SELECT * FROM n $q$)
       AS order_by_in_recursive_term;

-- Example 13: the TYPE trap. The anchor decides each column's type. Here 1 is integer but the
-- recursive term produces bigint (because of the 1::bigint), so PostgreSQL refuses.
SELECT pg_temp.try_sql($q$ WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1::bigint FROM n WHERE i < 5) SELECT * FROM n $q$)
       AS integer_anchor_bigint_term;
SELECT pg_temp.try_sql($q$ WITH RECURSIVE n(i) AS (SELECT 1::bigint UNION ALL SELECT i + 1::bigint FROM n WHERE i < 5) SELECT * FROM n $q$)
       AS fixed_by_casting_the_anchor;

-- Example 14: a runaway recursion, stopped safely. statement_timeout cancels it after 300 ms.
-- (Always set a timeout before experimenting with a query that might not stop.)
SET statement_timeout = '300ms';
SELECT pg_temp.try_sql($q$
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n)    -- no stop condition
    SELECT COUNT(*) FROM n $q$) AS runaway_result;
RESET statement_timeout;
