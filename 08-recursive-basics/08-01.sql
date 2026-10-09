-- Exercise 08-01: numbers 1 to 10 by recursion, and a check against generate_series.
-- Part A: the recursive version (with the square of each number, to show a calculated column).
WITH RECURSIVE counter(n) AS (
    SELECT 1                               -- anchor member
    UNION ALL
    SELECT n + 1                           -- recursive member
    FROM counter
    WHERE n < 10                           -- stop condition
)
SELECT n, n * n AS square
FROM counter
ORDER BY n;

-- Part B: generate_series produces the same numbers. Prove it (differences must be 0).
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
