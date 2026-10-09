-- Exercise 08-04: termination. What happens with no stop condition, and what ends a cycle?
-- Part A: a recursion with NO stop condition, stopped safely by statement_timeout.
--         The helper returns the error text instead of failing the script.
CREATE OR REPLACE FUNCTION pg_temp.try_sql(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION
    WHEN query_canceled THEN RETURN 'CANCELED: ' || SQLERRM;   -- OTHERS does not catch query_canceled
    WHEN OTHERS         THEN RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

SET statement_timeout = '300ms';
SELECT pg_temp.try_sql($q$
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n)
    SELECT COUNT(*) FROM n $q$) LIKE 'CANCELED:%' AS runaway_stopped_by_timeout;
RESET statement_timeout;

-- Part B: a CYCLE (1 -> 2 -> 3 -> 1 -> ...).
--   UNION     discards rows it has already produced, so the recursion ends on its own
--   UNION ALL keeps every row, so only the depth guard stops it
SELECT (SELECT COUNT(*) FROM (
            WITH RECURSIVE c(n) AS (
                SELECT 1
                UNION
                SELECT (n % 3) + 1 FROM c
            )
            SELECT n FROM c) u)                           AS rows_with_union,
       (SELECT COUNT(*) FROM (
            WITH RECURSIVE c(n, depth) AS (
                SELECT 1, 1
                UNION ALL
                SELECT (n % 3) + 1, depth + 1 FROM c WHERE depth < 10
            )
            SELECT n FROM c) g)                           AS rows_with_union_all_and_guard;
