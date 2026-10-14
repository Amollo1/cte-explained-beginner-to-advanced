-- Module 12 worked examples: data-modifying CTEs (INSERT / UPDATE / DELETE ... RETURNING inside WITH).
-- Run:  psql -d cte_lab -f 12-data-modifying-ctes/examples.sql
-- EVERY change below happens inside BEGIN ... ROLLBACK, so the practice data is left exactly as it was.
-- (In pgAdmin: if a statement fails inside BEGIN, run ROLLBACK before continuing.)

-- Test helper (session-only): runs a statement and RETURNS its error text instead of failing.
CREATE OR REPLACE FUNCTION pg_temp.try_sql(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION
    WHEN query_canceled THEN RETURN 'CANCELED: ' || SQLERRM;
    WHEN OTHERS         THEN RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- =====================================================================
-- Part A: RETURNING, the bridge between a change and the rest of the query
-- =====================================================================

-- Example 1: INSERT ... RETURNING hands back the rows that were inserted.
BEGIN;
INSERT INTO customers_clean (full_name, email, loaded_at)
VALUES ('Test Person', 'test.person@example.com', now())
RETURNING email, full_name;
ROLLBACK;

-- Example 2: UPDATE ... RETURNING hands back the NEW values of the changed rows.
BEGIN;
UPDATE employees
SET salary = ROUND(salary * 1.05, 2)
WHERE emp_id = 30
RETURNING emp_id, salary AS new_salary;
ROLLBACK;

-- Example 3: DELETE ... RETURNING hands back the rows that were removed (customer 27 never ordered).
BEGIN;
DELETE FROM customers
WHERE customer_id = 27
RETURNING customer_id, customer_name;
ROLLBACK;

-- Example 4: the same idea INSIDE a CTE: change data, then use the result in the main query.
BEGIN;
WITH raised AS (
    UPDATE employees
    SET salary = ROUND(salary * 1.05, 2)
    WHERE dept_id = 6
    RETURNING emp_id, salary AS new_salary
)
SELECT r.emp_id, e.first_name, r.new_salary
FROM raised r
JOIN employees e ON e.emp_id = r.emp_id
ORDER BY r.emp_id
LIMIT 3;
ROLLBACK;

-- =====================================================================
-- Part B: moving rows between tables (the archive pattern)
-- =====================================================================

-- Example 5: archive the cancelled orders AND their line items in ONE statement.
-- order_items has a foreign key to orders, so the items must go too. Constraints are checked at the
-- END of the statement, so deleting parents and children together is fine.
BEGIN;
WITH cancelled AS (                                        -- the orders to move
    SELECT order_id FROM orders WHERE status = 'cancelled'
),
del_items AS (                                              -- 1. remove their line items...
    DELETE FROM order_items
    WHERE order_id IN (SELECT order_id FROM cancelled)
    RETURNING item_id, order_id, product_id, quantity, discount
),
arch_items AS (                                             -- 2. ...and file them in the archive
    INSERT INTO order_items_archive (item_id, order_id, product_id, quantity, discount)
    SELECT item_id, order_id, product_id, quantity, discount FROM del_items
),
del_orders AS (                                             -- 3. remove the orders themselves...
    DELETE FROM orders
    WHERE order_id IN (SELECT order_id FROM cancelled)
    RETURNING order_id, customer_id, order_date, status, shipping_fee
)
INSERT INTO orders_archive (order_id, customer_id, order_date, status, shipping_fee)   -- 4. ...and archive them
SELECT order_id, customer_id, order_date, status, shipping_fee FROM del_orders;
SELECT (SELECT COUNT(*) FROM orders)                                AS orders_left,
       (SELECT COUNT(*) FROM orders_archive)                        AS orders_archived,
       (SELECT COUNT(*) FROM order_items)                           AS items_left,
       (SELECT COUNT(*) FROM order_items_archive)                   AS items_archived,
       (SELECT COUNT(*) FROM orders WHERE status = 'cancelled')     AS cancelled_left;
ROLLBACK;

-- Example 6: ATOMICITY. Put a clashing row in the archive first. The final INSERT then fails on the
-- primary key, and because everything is ONE statement, the DELETEs are undone too: nothing is lost.
BEGIN;
INSERT INTO orders_archive (order_id, customer_id, order_date, status, shipping_fee)
SELECT order_id, customer_id, order_date, status, shipping_fee
FROM orders
WHERE order_id = (SELECT MIN(order_id) FROM orders WHERE status = 'cancelled');

SELECT LEFT(pg_temp.try_sql($q$
WITH cancelled AS (                                        -- the orders to move
    SELECT order_id FROM orders WHERE status = 'cancelled'
),
del_items AS (                                              -- 1. remove their line items...
    DELETE FROM order_items
    WHERE order_id IN (SELECT order_id FROM cancelled)
    RETURNING item_id, order_id, product_id, quantity, discount
),
arch_items AS (                                             -- 2. ...and file them in the archive
    INSERT INTO order_items_archive (item_id, order_id, product_id, quantity, discount)
    SELECT item_id, order_id, product_id, quantity, discount FROM del_items
),
del_orders AS (                                             -- 3. remove the orders themselves...
    DELETE FROM orders
    WHERE order_id IN (SELECT order_id FROM cancelled)
    RETURNING order_id, customer_id, order_date, status, shipping_fee
)
INSERT INTO orders_archive (order_id, customer_id, order_date, status, shipping_fee)   -- 4. ...and archive them
SELECT order_id, customer_id, order_date, status, shipping_fee FROM del_orders $q$), 5) AS sqlstate_of_failed_archive;           -- 23505 = unique_violation

SELECT (SELECT COUNT(*) FROM orders)              AS orders_still_there,
       (SELECT COUNT(*) FROM order_items)         AS items_still_there,
       (SELECT COUNT(*) FROM order_items_archive) AS items_archived;
ROLLBACK;

-- Example 7: a data-modifying CTE runs EXACTLY ONCE, even if nothing ever reads it.
BEGIN;
WITH ghost AS (
    DELETE FROM customers WHERE customer_id = 27 RETURNING customer_id
)
SELECT 'the main query never mentions ghost' AS note;

SELECT COUNT(*) AS customers_after_the_ghost_delete FROM customers;      -- 29, not 30
ROLLBACK;

-- =====================================================================
-- Part C: audit trails and idempotent loads
-- =====================================================================

-- Example 8: a raise with an AUDIT TRAIL. The problem: after an UPDATE, RETURNING shows the NEW salary.
-- The trick: join the table to itself; that second copy still shows the OLD salary.
BEGIN;
WITH raised AS (
    UPDATE employees e
    SET salary = ROUND(old.salary * 1.05, 2)                -- 5% raise
    FROM employees old                                      -- a second reference to the table...
    JOIN departments d ON d.dept_id = old.dept_id
    WHERE old.emp_id = e.emp_id
      AND d.dept_name = 'Data & Analytics'
    RETURNING e.emp_id,
              old.salary AS old_salary,                     -- ...whose rows still hold the OLD salary
              e.salary   AS new_salary
)
INSERT INTO salary_log (emp_id, old_salary, new_salary)
SELECT emp_id, old_salary, new_salary FROM raised;
SELECT emp_id, old_salary, new_salary FROM salary_log ORDER BY emp_id;
SELECT SUM(old_salary) AS payroll_before, SUM(new_salary) AS payroll_after, COUNT(*) AS rows_logged FROM salary_log;
ROLLBACK;

-- Example 9: another way to get the old values. Every statement in a WITH list sees the SAME snapshot,
-- so a plain SELECT CTE shows the salaries as they were BEFORE the update.
BEGIN;
WITH before AS (
    SELECT emp_id, salary FROM employees WHERE dept_id = 6
),
raised AS (
    UPDATE employees
    SET salary = ROUND(salary * 1.05, 2)
    WHERE dept_id = 6
    RETURNING emp_id, salary AS new_salary
)
INSERT INTO salary_log (emp_id, old_salary, new_salary)
SELECT r.emp_id, b.salary, r.new_salary
FROM raised r
JOIN before b ON b.emp_id = r.emp_id;

SELECT COUNT(*) AS rows_logged, SUM(old_salary) AS payroll_before, SUM(new_salary) AS payroll_after FROM salary_log;
ROLLBACK;

-- Example 10: an UPSERT with a cleaned CTE as the source (the pipeline from Module 6).
-- Run it twice: the first run inserts 12 rows, the second inserts none (it is idempotent).
BEGIN;
WITH cleaned AS (                                               -- grain: one row per raw row
    SELECT raw_id,
           INITCAP(NULLIF(regexp_replace(trim(full_name), '\s+', ' ', 'g'), '')) AS full_name,
           NULLIF(lower(trim(email)), '')                                         AS email,
           loaded_at
    FROM customers_raw
),
valid AS (                                                  -- rows with a usable email
    SELECT raw_id, full_name, email, loaded_at
    FROM cleaned
    WHERE email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
),
latest AS (                                                 -- the newest record per email
    SELECT full_name, email, loaded_at,
           ROW_NUMBER() OVER (PARTITION BY email ORDER BY loaded_at DESC, raw_id DESC) AS rn
    FROM valid
),
inserted AS (
    INSERT INTO customers_clean (full_name, email, loaded_at)
    SELECT full_name, email, loaded_at FROM latest WHERE rn = 1
    ON CONFLICT (email) DO NOTHING                          -- already there? skip it
    RETURNING email
)
SELECT COUNT(*) AS inserted_rows FROM inserted;
WITH cleaned AS (                                               -- grain: one row per raw row
    SELECT raw_id,
           INITCAP(NULLIF(regexp_replace(trim(full_name), '\s+', ' ', 'g'), '')) AS full_name,
           NULLIF(lower(trim(email)), '')                                         AS email,
           loaded_at
    FROM customers_raw
),
valid AS (                                                  -- rows with a usable email
    SELECT raw_id, full_name, email, loaded_at
    FROM cleaned
    WHERE email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
),
latest AS (                                                 -- the newest record per email
    SELECT full_name, email, loaded_at,
           ROW_NUMBER() OVER (PARTITION BY email ORDER BY loaded_at DESC, raw_id DESC) AS rn
    FROM valid
),
inserted AS (
    INSERT INTO customers_clean (full_name, email, loaded_at)
    SELECT full_name, email, loaded_at FROM latest WHERE rn = 1
    ON CONFLICT (email) DO NOTHING                          -- already there? skip it
    RETURNING email
)
SELECT COUNT(*) AS inserted_rows FROM inserted;
SELECT email, full_name, loaded_at::date AS loaded_on FROM customers_clean ORDER BY email;

-- A NEWER record for an existing email arrives. DO UPDATE ... WHERE changes the row only if it is newer.
INSERT INTO customers_raw (raw_id, full_name, email, loaded_at)
VALUES (21, 'Alice  Mwangi-Otieno', 'ALICE.MWANGI@example.com', '2026-05-01 10:00');

WITH cleaned AS (                                               -- grain: one row per raw row
    SELECT raw_id,
           INITCAP(NULLIF(regexp_replace(trim(full_name), '\s+', ' ', 'g'), '')) AS full_name,
           NULLIF(lower(trim(email)), '')                                         AS email,
           loaded_at
    FROM customers_raw
),
valid AS (                                                  -- rows with a usable email
    SELECT raw_id, full_name, email, loaded_at
    FROM cleaned
    WHERE email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
),
latest AS (                                                 -- the newest record per email
    SELECT full_name, email, loaded_at,
           ROW_NUMBER() OVER (PARTITION BY email ORDER BY loaded_at DESC, raw_id DESC) AS rn
    FROM valid
),
upserted AS (
    INSERT INTO customers_clean (full_name, email, loaded_at)
    SELECT full_name, email, loaded_at FROM latest WHERE rn = 1
    ON CONFLICT (email) DO UPDATE                           -- already there? update it, but only if newer
        SET full_name = EXCLUDED.full_name,
            loaded_at = EXCLUDED.loaded_at
        WHERE customers_clean.loaded_at < EXCLUDED.loaded_at
    RETURNING email, full_name
)
SELECT email, full_name FROM upserted;
ROLLBACK;

-- =====================================================================
-- Part D: snapshot rules, limits and hazards
-- =====================================================================

-- Example 11: the main query sees the data AS IT WAS BEFORE the statement. The change reaches the main
-- query only through RETURNING. Employee 30 earns 42000; we double it.
BEGIN;
WITH bumped AS (
    UPDATE employees SET salary = salary * 2 WHERE emp_id = 30
    RETURNING emp_id, salary AS new_salary
)
SELECT (SELECT salary FROM employees WHERE emp_id = 30) AS salary_seen_by_main_query,
       (SELECT new_salary FROM bumped)                  AS salary_from_returning;

SELECT salary AS salary_seen_by_the_NEXT_statement FROM employees WHERE emp_id = 30;
ROLLBACK;

-- Example 12: the same for an INSERT. The new row is invisible to a SELECT in the same statement.
BEGIN;
WITH added AS (
    INSERT INTO customers_clean (full_name, email, loaded_at)
    VALUES ('Test Person', 'test.person@example.com', now())
    RETURNING email
)
SELECT (SELECT COUNT(*) FROM customers_clean) AS rows_seen_in_the_table,
       (SELECT COUNT(*) FROM added)           AS rows_returned;
ROLLBACK;

-- Example 13: data-modifying statements are allowed ONLY in the top-level WITH list.
SELECT LEFT(pg_temp.try_sql($q$
    SELECT * FROM (WITH d AS (DELETE FROM customers_clean RETURNING 1) SELECT * FROM d) x $q$), 5) AS sqlstate,
       pg_temp.try_sql($q$
    SELECT * FROM (WITH d AS (DELETE FROM customers_clean RETURNING 1) SELECT * FROM d) x $q$) AS message;

-- Example 14: SEQUENCES ARE NOT ROLLED BACK. An undone insert still uses up an id, leaving a gap.
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
SELECT jump AS sequence_jump_after_an_undone_insert FROM gap_result;     -- 2, not 1
SELECT COUNT(*) AS rows_left_in_customers_clean FROM customers_clean;    -- 0

-- Example 15: two sibling statements changing the SAME row. Only ONE of them takes effect, and
-- PostgreSQL does not promise which. Never rely on this: it is shown only so you recognise the problem.
BEGIN;
WITH a AS (UPDATE employees SET salary = 1 WHERE emp_id = 30 RETURNING 1),
     b AS (UPDATE employees SET salary = 2 WHERE emp_id = 30 RETURNING 1)
SELECT (SELECT COUNT(*) FROM a) AS rows_changed_by_a, (SELECT COUNT(*) FROM b) AS rows_changed_by_b;
ROLLBACK;
