-- Exercise 09-01: the org chart with depth, from the CEO down.
-- Anchor = the person with no manager. Each round adds the people who report to the previous round.
-- Part A: everyone with their level. Expected: 30 rows (levels: 1, 5, 7, 16, 1 people).
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
SELECT depth,
       emp_id,
       first_name || ' ' || last_name AS employee,
       job_title
FROM org
ORDER BY depth, emp_id;

-- Part B: reconcile. The traversal must reach every employee (a detached cycle would not be reached).
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
SELECT (SELECT COUNT(*) FROM org)       AS employees_reached,
       (SELECT COUNT(*) FROM employees) AS employees_total,
       (SELECT MAX(depth) FROM org)     AS max_depth;
