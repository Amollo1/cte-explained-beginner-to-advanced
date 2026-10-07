-- Exercise 01-01: employees earning more than the company average.
-- The average is computed once, in a CTE. A one-row CTE can be CROSS JOINed.
WITH avg_salary AS (
    SELECT AVG(salary) AS company_avg
    FROM employees
)
SELECT e.emp_id,
       e.first_name || ' ' || e.last_name AS employee,
       e.salary,
       ROUND(a.company_avg, 2)            AS company_avg
FROM employees e
CROSS JOIN avg_salary a
WHERE e.salary > a.company_avg
ORDER BY e.salary DESC, e.emp_id;
