-- Exercise 09-02: each employee's management chain as text, from the CEO down to the person.
-- The path is built as the recursion goes down: parent's chain || ' > ' || my first name.
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
       first_name || ' ' || last_name AS employee,
       depth,
       chain
FROM org
ORDER BY emp_id;
