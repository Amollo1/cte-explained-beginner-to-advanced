-- Exercise 01-03: a CTE exists for ONE statement only.
-- Part A: the CTE works inside its own statement.
WITH high_earners AS (
    SELECT emp_id, salary
    FROM employees
    WHERE salary > 100000
)
SELECT COUNT(*) AS high_earner_count
FROM high_earners;

-- Part B: a second statement cannot see it. The DO block catches the error so
-- this file still runs cleanly in CI. In psql you would see:
--   ERROR:  relation "high_earners" does not exist
DO $$
BEGIN
    PERFORM 1 FROM high_earners;
EXCEPTION WHEN undefined_table THEN
    RAISE NOTICE 'Expected error caught: %', SQLERRM;
END $$;
