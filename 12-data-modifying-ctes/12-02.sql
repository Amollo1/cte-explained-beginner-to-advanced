-- Exercise 12-02: a 5% raise for the Data & Analytics department, with an audit trail, in ONE statement.
-- After an UPDATE, RETURNING shows the NEW salary. To log the OLD one as well, the UPDATE joins the table
-- to itself: that second copy still holds the old values.
-- Everything runs inside BEGIN ... ROLLBACK so the practice data is left untouched.

-- Part A: the audit log. Expected: 7 rows (one per employee in the department).
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
SELECT emp_id, old_salary, new_salary
FROM salary_log
ORDER BY emp_id;

-- Part B: reconcile. Payroll before and after, the increase, and the number of rows logged.
SELECT SUM(old_salary)                   AS payroll_before,
       SUM(new_salary)                   AS payroll_after,
       SUM(new_salary) - SUM(old_salary) AS increase,
       COUNT(*)                          AS rows_logged
FROM salary_log;

-- The table itself was changed by the same statement: no other department was touched.
SELECT COUNT(*) FILTER (WHERE s.new_salary IS NOT NULL) AS employees_with_a_new_salary,
       (SELECT COUNT(*) FROM employees)                 AS employees_in_total
FROM employees e
LEFT JOIN salary_log s ON s.emp_id = e.emp_id AND s.new_salary = e.salary;
ROLLBACK;

-- Part C: rolled back. Expected: 0 log rows and the original payroll for the department (612000.00).
SELECT (SELECT COUNT(*) FROM salary_log)                          AS log_rows_after_rollback,
       (SELECT SUM(salary) FROM employees WHERE dept_id = 6)      AS dept_payroll_after_rollback;
