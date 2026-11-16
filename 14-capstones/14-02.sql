-- Capstone 2: ORG-CHART EXPLORER (a recursive view, a reusable function and an integrity audit).
--
-- The business need: HR wants to see the organisation, who manages whom, how big each team is and what it costs,
-- and to be warned when the reporting data is broken.
--   org.v_org_chart      every employee with depth, chain of managers, direct and total reports, team payroll
--   org.v_level_stats    headcount and salaries per level
--   org.team(manager)    function: everyone below a given manager
--   org.v_audit          integrity audit: unreachable employees, number of roots
-- Techniques: top-down recursion with paths (Module 9), a closure for headcounts and payroll (Module 9),
-- aggregate-then-join (Module 4), a depth guard on the closure (Module 9).
-- HOW THIS FILE IS USED
--   In this course repository the file runs inside BEGIN ... ROLLBACK, so the practice data is never changed
--   and the automated tests can run it again and again.
--   To KEEP the objects in YOUR OWN project repository, copy the file, delete the BEGIN; and ROLLBACK; lines
--   (or replace ROLLBACK; with COMMIT;) and run it once against your own database.

BEGIN;

CREATE SCHEMA org;
COMMENT ON SCHEMA org IS 'Organisation explorer built on employees.manager_id.';

CREATE VIEW org.v_org_chart AS
WITH RECURSIVE tree(emp_id, depth, chain, path_ids) AS (          -- top-down from the root
    SELECT emp_id, 1, first_name::text, ARRAY[emp_id]
    FROM employees
    WHERE manager_id IS NULL
    UNION ALL
    SELECT e.emp_id, t.depth + 1, t.chain || ' > ' || e.first_name, t.path_ids || e.emp_id
    FROM employees e
    JOIN tree t ON e.manager_id = t.emp_id
),
closure AS (                                                      -- every manager paired with all their reports
    SELECT manager_id AS ancestor_id, emp_id AS descendant_id, 1 AS distance
    FROM employees
    WHERE manager_id IS NOT NULL
    UNION ALL
    SELECT c.ancestor_id, e.emp_id, c.distance + 1
    FROM closure c
    JOIN employees e ON e.manager_id = c.descendant_id
    WHERE c.distance < 20                                         -- safety net against cycles in bad data
),
team_stats AS (                                                   -- grain: one row per employee
    SELECT e.emp_id,
           COUNT(c.descendant_id) FILTER (WHERE c.distance = 1) AS direct_reports,
           COUNT(c.descendant_id)                               AS total_reports,
           e.salary + COALESCE(SUM(d.salary), 0)                AS team_payroll
    FROM employees e
    LEFT JOIN closure   c ON c.ancestor_id = e.emp_id
    LEFT JOIN employees d ON d.emp_id      = c.descendant_id
    GROUP BY e.emp_id, e.salary
)
SELECT e.emp_id,
       e.first_name || ' ' || e.last_name AS employee,
       e.job_title,
       d.dept_name,
       m.first_name || ' ' || m.last_name AS manager,
       e.salary,
       t.depth,
       t.chain,
       t.path_ids,
       s.direct_reports,
       s.total_reports,
       s.team_payroll
FROM tree t
JOIN employees e       ON e.emp_id    = t.emp_id
LEFT JOIN departments d ON d.dept_id  = e.dept_id
LEFT JOIN employees m   ON m.emp_id   = e.manager_id
JOIN team_stats s       ON s.emp_id   = e.emp_id;
COMMENT ON VIEW org.v_org_chart IS 'One row per employee reachable from the CEO. team_payroll includes the employee own salary.';

CREATE VIEW org.v_level_stats AS
SELECT depth,
       COUNT(*)                   AS people,
       ROUND(AVG(salary), 2)      AS avg_salary,
       SUM(salary)                AS payroll
FROM org.v_org_chart
GROUP BY depth;

CREATE FUNCTION org.team(p_manager int)
RETURNS TABLE(emp_id int, employee text, levels_below int)
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE sub(emp_id, levels_below) AS (
        SELECT e.emp_id, 0 FROM employees e WHERE e.emp_id = p_manager
        UNION ALL
        SELECT e.emp_id, s.levels_below + 1 FROM employees e JOIN sub s ON e.manager_id = s.emp_id
    )
    SELECT s.emp_id, e.first_name || ' ' || e.last_name, s.levels_below
    FROM sub s
    JOIN employees e ON e.emp_id = s.emp_id
    WHERE s.levels_below > 0
$$;

CREATE VIEW org.v_audit AS
SELECT (SELECT COUNT(*) FROM employees)                                                     AS employees_total,
       (SELECT COUNT(*) FROM org.v_org_chart)                                               AS employees_reached,
       (SELECT COUNT(*) FROM employees WHERE manager_id IS NULL)                            AS roots,
       (SELECT COUNT(*) FROM employees e
        WHERE NOT EXISTS (SELECT 1 FROM org.v_org_chart v WHERE v.emp_id = e.emp_id))       AS unreachable_employees;

-- Part A: the managers' scorecard, in outline order. Expected: 14 managers.
SELECT repeat('    ', depth - 1) || employee AS manager,
       direct_reports, total_reports, team_payroll
FROM org.v_org_chart
WHERE direct_reports > 0
ORDER BY path_ids;

-- Part B: headcount and pay per level. Expected: levels 1 to 5 with 1, 5, 7, 16 and 1 people.
SELECT * FROM org.v_level_stats ORDER BY depth;

-- Part C: the integrity audit. Expected: 30, 30, 1, 0.
SELECT * FROM org.v_audit;

-- Part D: SELF-CHECKS. Every row must say passed = true.
WITH checks(ord, check_name, expected, actual) AS (
    VALUES
    (1, 'every employee appears in the chart',
        (SELECT COUNT(*) FROM employees)::text,
        (SELECT COUNT(*) FROM org.v_org_chart)::text),
    (2, 'the deepest level is 5',
        '5',
        (SELECT MAX(depth) FROM org.v_org_chart)::text),
    (3, 'the CEO has everyone else as a report',
        ((SELECT COUNT(*) FROM employees) - 1)::text,
        (SELECT total_reports FROM org.v_org_chart WHERE manager IS NULL)::text),
    (4, 'direct reports add up to every non-root employee',
        ((SELECT COUNT(*) FROM employees) - 1)::text,
        (SELECT SUM(direct_reports) FROM org.v_org_chart)::text),
    (5, 'the CEO team payroll equals the whole payroll',
        (SELECT SUM(salary) FROM employees)::text,
        (SELECT team_payroll FROM org.v_org_chart WHERE manager IS NULL)::text),
    (6, 'the VP Data team payroll equals the Data and Analytics department payroll (cross-check with Module 12)',
        (SELECT SUM(e.salary) FROM employees e JOIN departments d ON d.dept_id = e.dept_id WHERE d.dept_name = 'Data & Analytics')::text,
        (SELECT team_payroll FROM org.v_org_chart WHERE emp_id = 6)::text),
    (7, 'the team function returns the 6 people under the VP Data',
        '6',
        (SELECT COUNT(*) FROM org.team(6))::text),
    (8, 'there is exactly one root and no unreachable employee',
        '1 / 0',
        (SELECT roots || ' / ' || unreachable_employees FROM org.v_audit))
)
SELECT check_name, expected, actual, (expected = actual) AS passed
FROM checks
ORDER BY ord;

-- Part E: the audit catches broken data. Employees 14 and 15 are made each other's manager (a detached cycle).
UPDATE employees SET manager_id = 15 WHERE emp_id = 14;
UPDATE employees SET manager_id = 14 WHERE emp_id = 15;
SELECT employees_total, employees_reached, unreachable_employees FROM org.v_audit;   -- expected: 30, 28, 2

ROLLBACK;
