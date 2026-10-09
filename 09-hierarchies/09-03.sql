-- Exercise 09-03: reports under a chosen manager, and headcount per manager.
-- Part A: ALL direct and indirect reports of Farid Rahman (emp_id 6). Change the 6 to try another manager.
WITH RECURSIVE subtree(emp_id, level_below) AS (
    SELECT emp_id, 0
    FROM employees
    WHERE emp_id = 6                                  -- the chosen manager
    UNION ALL
    SELECT e.emp_id, s.level_below + 1
    FROM employees e
    JOIN subtree s ON e.manager_id = s.emp_id
)
SELECT s.level_below,
       e.emp_id,
       e.first_name || ' ' || e.last_name AS employee
FROM subtree s
JOIN employees e ON e.emp_id = s.emp_id
WHERE s.level_below > 0                               -- leave out the manager themself
ORDER BY s.level_below, e.emp_id;

-- Part B: headcount for EVERY manager at once, using a closure (manager, report, distance).
-- The anchor is every reporting line, so each manager is paired with all of their descendants.
-- The depth guard (distance < 20) is a safety net: corrupt data containing a cycle would
-- otherwise make this query run forever (see examples.sql, Example 12).
WITH RECURSIVE reports(manager_id, emp_id, distance) AS (
    SELECT manager_id, emp_id, 1
    FROM employees
    WHERE manager_id IS NOT NULL
    UNION ALL
    SELECT r.manager_id, e.emp_id, r.distance + 1
    FROM reports r
    JOIN employees e ON e.manager_id = r.emp_id
    WHERE r.distance < 20
)
SELECT m.emp_id,
       m.first_name || ' ' || m.last_name       AS manager,
       COUNT(*) FILTER (WHERE r.distance = 1)   AS direct_reports,
       COUNT(*)                                 AS total_reports
FROM reports r
JOIN employees m ON m.emp_id = r.manager_id
GROUP BY m.emp_id, m.first_name, m.last_name
ORDER BY total_reports DESC, m.emp_id;
