-- Exercise 00-02: every employee with department name and manager name.
-- Expected: 30 rows (the CEO has no manager, so a LEFT JOIN is required).
SELECT e.emp_id,
       e.first_name || ' ' || e.last_name                     AS employee,
       d.dept_name,
       COALESCE(m.first_name || ' ' || m.last_name, '(none)') AS manager
FROM employees e
LEFT JOIN departments d ON d.dept_id = e.dept_id
LEFT JOIN employees   m ON m.emp_id  = e.manager_id
ORDER BY e.emp_id;
