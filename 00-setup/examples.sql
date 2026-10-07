-- Module 0 worked examples: SQL refresher on the practice dataset.
-- Run:  psql -d cte_lab -f 00-setup/examples.sql

-- Example 1: SELECT, WHERE, ORDER BY
SELECT emp_id, first_name, last_name, salary
FROM employees
WHERE dept_id = 6 AND salary > 70000
ORDER BY salary DESC;

-- Example 2: INNER JOIN (employees that have a department)
SELECT e.first_name, e.last_name, d.dept_name
FROM employees e
JOIN departments d ON d.dept_id = e.dept_id
ORDER BY e.emp_id
LIMIT 5;

-- Example 3: LEFT JOIN keeps rows with no match (Marketing has no employees)
SELECT d.dept_name, COUNT(e.emp_id) AS headcount
FROM departments d
LEFT JOIN employees e ON e.dept_id = d.dept_id
GROUP BY d.dept_name
ORDER BY headcount, d.dept_name;

-- Example 4: Self join (an employee and their manager)
SELECT e.first_name AS employee, m.first_name AS manager
FROM employees e
LEFT JOIN employees m ON m.emp_id = e.manager_id
WHERE e.emp_id IN (1, 14, 30)
ORDER BY e.emp_id;

-- Example 5: GROUP BY + HAVING (HAVING filters groups, WHERE filters rows)
SELECT dept_id, COUNT(*) AS headcount, ROUND(AVG(salary), 2) AS avg_salary
FROM employees
GROUP BY dept_id
HAVING COUNT(*) > 3
ORDER BY dept_id;

-- Example 6a: Scalar subquery (returns one value)
SELECT first_name, salary
FROM employees
WHERE salary > (SELECT AVG(salary) FROM employees)
ORDER BY salary DESC
LIMIT 3;

-- Example 6b: IN subquery (returns a list)
SELECT customer_id, customer_name
FROM customers
WHERE customer_id IN (SELECT customer_id FROM orders)
ORDER BY customer_id
LIMIT 3;

-- Example 6c: Correlated subquery (re-evaluated per outer row)
SELECT e.first_name, e.dept_id, e.salary
FROM employees e
WHERE e.salary > (SELECT AVG(x.salary) FROM employees x WHERE x.dept_id = e.dept_id)
ORDER BY e.dept_id, e.salary DESC;

-- Example 6d: Derived table (subquery in FROM)
SELECT d.dept_name, ROUND(s.avg_salary, 2) AS avg_salary
FROM (SELECT dept_id, AVG(salary) AS avg_salary
      FROM employees
      GROUP BY dept_id) s
JOIN departments d ON d.dept_id = s.dept_id
ORDER BY s.avg_salary DESC;

-- Example 7: The readability problem. Which departments are larger than the
-- AVERAGE department? It works, but you have to read it inside-out...
SELECT dept_name, headcount
FROM (SELECT d.dept_name, COUNT(*) AS headcount
      FROM employees e
      JOIN departments d ON d.dept_id = e.dept_id
      GROUP BY d.dept_name) dept_size
WHERE headcount > (SELECT AVG(headcount)
                   FROM (SELECT COUNT(*) AS headcount
                         FROM employees
                         GROUP BY dept_id) x)
ORDER BY headcount DESC, dept_name;
