-- Exercise 12-04: snapshot semantics. Every statement in a WITH list sees the SAME snapshot of the data,
-- taken before the statement began. A change reaches the rest of the statement ONLY through RETURNING.

CREATE OR REPLACE FUNCTION pg_temp.try_sql(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION
    WHEN query_canceled THEN RETURN 'CANCELED: ' || SQLERRM;
    WHEN OTHERS         THEN RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- Part A: the main query sees the OLD salary; RETURNING gives the NEW one; the NEXT statement sees the new one.
-- Employee 30 earns 42000.00 and the salary is doubled. Expected: 42000.00, 84000.00, 84000.00.
BEGIN;
WITH bumped AS (
    UPDATE employees SET salary = salary * 2 WHERE emp_id = 30
    RETURNING emp_id, salary AS new_salary
)
SELECT (SELECT salary FROM employees WHERE emp_id = 30) AS salary_seen_by_main_query,
       (SELECT new_salary FROM bumped)                  AS salary_from_returning;

SELECT salary AS salary_seen_by_the_next_statement FROM employees WHERE emp_id = 30;
ROLLBACK;

-- Part B: an INSERT is invisible to a SELECT in the same statement. Expected: 0, 1.
BEGIN;
WITH added AS (
    INSERT INTO customers_clean (full_name, email, loaded_at)
    VALUES ('Test Person', 'test.person@example.com', now())
    RETURNING email
)
SELECT (SELECT COUNT(*) FROM customers_clean) AS rows_seen_in_the_table,
       (SELECT COUNT(*) FROM added)           AS rows_returned;
ROLLBACK;

-- Part C: data-modifying statements are allowed only in the TOP-LEVEL WITH list. 0A000 = feature_not_supported.
SELECT LEFT(pg_temp.try_sql($q$
    SELECT * FROM (WITH d AS (DELETE FROM customers_clean RETURNING 1) SELECT * FROM d) x $q$), 5) AS sqlstate_when_nested;

-- Part D: sequences are NOT rolled back. An undone insert still consumes an id. Expected: 2 (not 1), 0 rows.
CREATE TEMP TABLE gap_result(jump bigint);
DO $$
DECLARE a bigint; b bigint;
BEGIN
    a := nextval('customers_clean_customer_id_seq');
    BEGIN
        INSERT INTO customers_clean (full_name, email, loaded_at) VALUES ('Gap', 'gap@example.com', now());
        RAISE EXCEPTION 'undo the insert';
    EXCEPTION WHEN raise_exception THEN NULL;
    END;
    b := nextval('customers_clean_customer_id_seq');
    INSERT INTO gap_result VALUES (b - a);
END $$;
SELECT jump AS sequence_jump_after_an_undone_insert,
       (SELECT COUNT(*) FROM customers_clean) AS rows_left_in_customers_clean
FROM gap_result;

-- Part E: the practice data is untouched. Expected: 42000.00 and 0.
SELECT (SELECT salary FROM employees WHERE emp_id = 30) AS salary_of_employee_30,
       (SELECT COUNT(*) FROM customers_clean)           AS customers_clean_rows;
