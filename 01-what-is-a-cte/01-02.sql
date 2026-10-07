-- Exercise 01-02: departments with more than 3 employees, as a CTE.
-- Original (nested) version, for comparison:
--   SELECT d.dept_name
--   FROM departments d
--   WHERE d.dept_id IN (SELECT dept_id FROM employees
--                       GROUP BY dept_id HAVING COUNT(*) > 3);
-- Edge cases: HR has exactly 3 (excluded); Marketing has 0 (excluded).
WITH dept_headcount AS (
    SELECT dept_id, COUNT(*) AS headcount
    FROM employees
    GROUP BY dept_id
)
SELECT d.dept_name, h.headcount
FROM departments d
JOIN dept_headcount h ON h.dept_id = d.dept_id
WHERE h.headcount > 3
ORDER BY h.headcount DESC, d.dept_name;
