-- Exercise 05-05: the two highest-paid employees in each department.
-- Part A uses RANK() so that a tie for 2nd place would include BOTH people.
-- (There are no salary ties in the real data, so this returns exactly 2 per department.)
WITH ranked AS (
    SELECT d.dept_name,
           e.first_name || ' ' || e.last_name AS employee,
           e.salary,
           RANK() OVER (PARTITION BY e.dept_id ORDER BY e.salary DESC) AS salary_rank
    FROM employees e
    JOIN departments d ON d.dept_id = e.dept_id
)
SELECT dept_name, salary_rank, employee, salary
FROM ranked
WHERE salary_rank <= 2
ORDER BY dept_name, salary_rank, employee;

-- Part B: SIMULATE a tie for 2nd place inside a transaction (rolled back afterwards).
-- Hassan Ali is set to Grace Wanjiru's salary (105000). Compare the three ranking functions.
BEGIN;
UPDATE employees SET salary = 105000 WHERE emp_id = 8;

WITH engineering AS (
    SELECT first_name, salary,
           ROW_NUMBER() OVER (ORDER BY salary DESC, emp_id) AS row_num,
           RANK()       OVER (ORDER BY salary DESC)         AS rnk,
           DENSE_RANK() OVER (ORDER BY salary DESC)         AS dense_rnk
    FROM employees
    WHERE dept_id = 2
)
SELECT first_name, salary, row_num, rnk, dense_rnk
FROM engineering
WHERE row_num <= 4
ORDER BY row_num;

ROLLBACK;
