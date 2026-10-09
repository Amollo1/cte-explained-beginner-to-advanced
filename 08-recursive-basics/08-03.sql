-- Exercise 08-03: the first 15 Fibonacci numbers and factorials in ONE recursive CTE.
-- Each row carries the state needed to build the next row:
--   fib / next_fib   two consecutive Fibonacci numbers
--   factorial        n!
-- numeric is used (not integer or bigint) so nothing can overflow.
WITH RECURSIVE seq(n, fib, next_fib, factorial) AS (
    SELECT 1, 1::numeric, 1::numeric, 1::numeric
    UNION ALL
    SELECT n + 1,
           next_fib,
           fib + next_fib,
           factorial * (n + 1)
    FROM seq
    WHERE n < 15
)
SELECT n, fib AS fibonacci, factorial
FROM seq
ORDER BY n;
