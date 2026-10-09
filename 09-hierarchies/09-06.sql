-- Exercise 09-06: the org chart in outline order, with indentation.
-- ORDER BY depth would list level by level. Sorting on the PATH of ids (an integer array) puts each
-- person directly before their own team. Siblings come out in emp_id order.
WITH RECURSIVE org(emp_id, first_name, last_name, job_title, depth, path_ids, chain) AS (
    SELECT emp_id, first_name, last_name, job_title,
           1,                              -- the root is level 1
           ARRAY[emp_id],                  -- path of ids from the root, used for ordering
           first_name::text                -- path of names from the root, used for display
    FROM employees
    WHERE manager_id IS NULL               -- anchor: the root (nobody above them)
    UNION ALL
    SELECT e.emp_id, e.first_name, e.last_name, e.job_title,
           o.depth + 1,
           o.path_ids || e.emp_id,
           o.chain || ' > ' || e.first_name
    FROM employees e
    JOIN org o ON e.manager_id = o.emp_id  -- recursive member: the people who report to the previous round
)
SELECT emp_id,
       repeat('    ', depth - 1) || first_name || ' ' || last_name || ' (' || job_title || ')' AS org_chart
FROM org
ORDER BY path_ids;
