-- Module 1 worked examples: what a CTE is.
-- Run:  psql -d cte_lab -f 01-what-is-a-cte/examples.sql

-- Example 1: your first CTE (name a result, then query it)
WITH dept_avg AS (
    SELECT dept_id, AVG(salary) AS avg_salary
    FROM employees
    GROUP BY dept_id
)
SELECT dept_id, ROUND(avg_salary, 2) AS avg_salary
FROM dept_avg
ORDER BY avg_salary DESC;

-- Example 2: the optional column list renames the CTE's columns
WITH dept_avg (department, average_pay) AS (
    SELECT dept_id, AVG(salary)
    FROM employees
    GROUP BY dept_id
)
SELECT department, ROUND(average_pay, 2) AS average_pay
FROM dept_avg
ORDER BY average_pay DESC
LIMIT 3;

-- Example 3: the Module 0 "inside-out" query, rewritten as named steps
WITH dept_size AS (
    SELECT d.dept_name, COUNT(*) AS headcount
    FROM employees e
    JOIN departments d ON d.dept_id = e.dept_id
    GROUP BY d.dept_name
),
avg_size AS (
    SELECT AVG(headcount) AS avg_headcount
    FROM dept_size
)
SELECT s.dept_name, s.headcount
FROM dept_size s
CROSS JOIN avg_size a
WHERE s.headcount > a.avg_headcount
ORDER BY s.headcount DESC, s.dept_name;

-- Example 4: PROVE a refactor is equivalent. Both EXCEPT directions must be 0.
-- old_version is the nested query, new_version is the CTE rewrite.
WITH dept_size AS (
    SELECT d.dept_name, COUNT(*) AS headcount
    FROM employees e
    JOIN departments d ON d.dept_id = e.dept_id
    GROUP BY d.dept_name
),
avg_size AS (
    SELECT AVG(headcount) AS avg_headcount FROM dept_size
),
new_version AS (
    SELECT s.dept_name, s.headcount
    FROM dept_size s CROSS JOIN avg_size a
    WHERE s.headcount > a.avg_headcount
),
old_version AS (
    SELECT dept_name, headcount
    FROM (SELECT d.dept_name, COUNT(*) AS headcount
          FROM employees e JOIN departments d ON d.dept_id = e.dept_id
          GROUP BY d.dept_name) dept_size_old
    WHERE headcount > (SELECT AVG(headcount)
                       FROM (SELECT COUNT(*) AS headcount
                             FROM employees GROUP BY dept_id) x)
)
SELECT (SELECT COUNT(*) FROM (SELECT * FROM old_version EXCEPT SELECT * FROM new_version) a) AS only_in_old,
       (SELECT COUNT(*) FROM (SELECT * FROM new_version EXCEPT SELECT * FROM old_version) b) AS only_in_new;

-- Example 5: a CTE used twice in one statement
WITH headcount AS (
    SELECT dept_id, COUNT(*) AS n FROM employees GROUP BY dept_id
)
SELECT (SELECT MAX(n) FROM headcount) AS largest_dept,
       (SELECT MIN(n) FROM headcount) AS smallest_dept;

-- Example 6: a CTE with the same name as a table SHADOWS the table
WITH employees AS (SELECT * FROM employees WHERE dept_id = 6)
SELECT COUNT(*) AS rows_seen_through_the_cte FROM employees;   -- 7, not 30
SELECT COUNT(*) AS rows_in_the_real_table FROM employees;       -- 30

-- Example 7: scope. A CTE lives for ONE statement only.
WITH high_earners AS (SELECT emp_id FROM employees WHERE salary > 100000)
SELECT COUNT(*) AS statement_one_works FROM high_earners;

DO $$
BEGIN
    PERFORM 1 FROM high_earners;
EXCEPTION WHEN undefined_table THEN
    RAISE NOTICE 'Statement two failed as expected: %', SQLERRM;
END $$;

-- Example 8: since PostgreSQL 12 a simple CTE is inlined, not materialized.
-- Look for the absence of a "CTE Scan" node in the plan.
EXPLAIN
WITH all_emps AS (SELECT * FROM employees)
SELECT * FROM all_emps WHERE emp_id = 5;
