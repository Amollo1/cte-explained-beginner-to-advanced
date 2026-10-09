-- Module 9 worked examples: hierarchies with recursive CTEs.
-- Run:  psql -d cte_lab -f 09-hierarchies/examples.sql

-- Test helper (session-only): runs a statement and RETURNS its error text instead of failing.
CREATE OR REPLACE FUNCTION pg_temp.try_sql(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION
    WHEN query_canceled THEN RETURN 'CANCELED: ' || SQLERRM;   -- OTHERS does not catch query_canceled
    WHEN OTHERS         THEN RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- =====================================================================
-- Part A: top-down traversal of the org chart (employees.manager_id)
-- =====================================================================

-- Example 1: the org chart with depth. Anchor = the root; recursive member = the next level down.
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
SELECT depth, emp_id, first_name || ' ' || last_name AS employee, job_title
FROM org
ORDER BY depth, emp_id
LIMIT 8;

-- Example 2: how many people at each level, and RECONCILE: did the traversal reach everyone?
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
SELECT depth, COUNT(*) AS people
FROM org
GROUP BY depth
ORDER BY depth;

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

-- Example 3: management chains as text (root to person). Carry the path down the tree.
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
SELECT emp_id, depth, chain
FROM org
WHERE emp_id IN (3, 14, 30)
ORDER BY emp_id;

-- Example 4: a SUBTREE. Same recursion, but the anchor is one chosen manager (here Farid, emp_id 6).
WITH RECURSIVE subtree(emp_id, level_below) AS (
    SELECT emp_id, 0 FROM employees WHERE emp_id = 6        -- change 6 to any manager's emp_id
    UNION ALL
    SELECT e.emp_id, s.level_below + 1
    FROM employees e
    JOIN subtree s ON e.manager_id = s.emp_id
)
SELECT s.level_below, e.emp_id, e.first_name || ' ' || e.last_name AS employee
FROM subtree s
JOIN employees e ON e.emp_id = s.emp_id
WHERE s.level_below > 0                                      -- leave out the manager themself
ORDER BY s.level_below, e.emp_id;

-- =====================================================================
-- Part B: upward traversal, and the "closure" of a hierarchy
-- =====================================================================

-- Example 5: UPWARD. Start at one person and keep joining to their manager. Who are Daniel's managers?
WITH RECURSIVE chain_up(emp_id, manager_id, levels_above) AS (
    SELECT emp_id, manager_id, 0 FROM employees WHERE emp_id = 30       -- anchor: Daniel
    UNION ALL
    SELECT e.emp_id, e.manager_id, c.levels_above + 1
    FROM employees e
    JOIN chain_up c ON e.emp_id = c.manager_id                          -- the join runs the other way
)
SELECT c.levels_above, e.first_name || ' ' || e.last_name AS person, e.job_title
FROM chain_up c
JOIN employees e ON e.emp_id = c.emp_id
ORDER BY c.levels_above;

-- Example 6: the CLOSURE. Anchor on EVERY reporting line, so each manager is paired with all of their
-- direct AND indirect reports. Counting the pairs per manager gives headcounts in one pass.
WITH RECURSIVE reports(manager_id, emp_id, distance) AS (
    SELECT manager_id, emp_id, 1
    FROM employees
    WHERE manager_id IS NOT NULL                    -- every direct reporting line
    UNION ALL
    SELECT r.manager_id, e.emp_id, r.distance + 1
    FROM reports r
    JOIN employees e ON e.manager_id = r.emp_id     -- extend each line one level further down
)
SELECT m.first_name || ' ' || m.last_name                AS manager,
       COUNT(*) FILTER (WHERE r.distance = 1)            AS direct_reports,
       COUNT(*)                                          AS total_reports
FROM reports r
JOIN employees m ON m.emp_id = r.manager_id
GROUP BY m.emp_id, m.first_name, m.last_name
ORDER BY total_reports DESC, m.emp_id;

-- =====================================================================
-- Part C: the category tree, breadcrumbs and roll-ups
-- =====================================================================

-- Example 7: breadcrumbs for every category.
WITH RECURSIVE tree(category_id, category_name, depth, path_ids, breadcrumb) AS (
    SELECT category_id, category_name, 1, ARRAY[category_id], category_name::text
    FROM categories
    WHERE parent_id IS NULL                -- anchor: top-level categories
    UNION ALL
    SELECT c.category_id, c.category_name, t.depth + 1,
           t.path_ids || c.category_id,
           t.breadcrumb || ' > ' || c.category_name
    FROM categories c
    JOIN tree t ON c.parent_id = t.category_id
)
SELECT depth, category_id, breadcrumb
FROM tree
ORDER BY path_ids;

-- Example 8: ROLL UP revenue to the top-level categories. Carry the ROOT down the tree,
-- then add up each category's own revenue under its root.
WITH RECURSIVE tree(category_id, root_id) AS (
    SELECT category_id, category_id FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.category_id, t.root_id
    FROM categories c
    JOIN tree t ON c.parent_id = t.category_id
),
leaf_revenue AS (                   -- grain: one row per category that has sales (completed orders)
    SELECT p.category_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM order_items i
    JOIN orders   o ON o.order_id   = i.order_id AND o.status = 'completed'
    JOIN products p ON p.product_id = i.product_id
    GROUP BY p.category_id
)
SELECT r.category_name,
       ROUND(SUM(lr.revenue), 2) AS revenue
FROM tree t
JOIN categories   r  ON r.category_id  = t.root_id
JOIN leaf_revenue lr ON lr.category_id = t.category_id
GROUP BY r.category_id, r.category_name
ORDER BY revenue DESC;

-- Example 9: ROLL UP at EVERY level with a closure: each category paired with all of its descendants
-- (itself included, distance 0). Then sum the descendants' revenue per ancestor.
WITH RECURSIVE closure(ancestor_id, category_id) AS (
    SELECT category_id, category_id FROM categories             -- every node is its own descendant
    UNION ALL
    SELECT cl.ancestor_id, c.category_id
    FROM closure cl
    JOIN categories c ON c.parent_id = cl.category_id
),
leaf_revenue AS (                   -- grain: one row per category that has sales (completed orders)
    SELECT p.category_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM order_items i
    JOIN orders   o ON o.order_id   = i.order_id AND o.status = 'completed'
    JOIN products p ON p.product_id = i.product_id
    GROUP BY p.category_id
)
SELECT a.category_id, a.category_name,
       ROUND(COALESCE(SUM(lr.revenue), 0), 2) AS rolled_up_revenue
FROM closure cl
JOIN categories a ON a.category_id = cl.ancestor_id
LEFT JOIN leaf_revenue lr ON lr.category_id = cl.category_id
GROUP BY a.category_id, a.category_name
ORDER BY a.category_id;

-- =====================================================================
-- Part D: ordering a tree
-- =====================================================================

-- Example 10: ORDER BY depth lists the tree LEVEL BY LEVEL, which does not look like an org chart.
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
SELECT depth, emp_id, first_name AS person
FROM org
ORDER BY depth, emp_id
LIMIT 9;

-- Ordering by the PATH of ids gives OUTLINE order: each person is followed by their own team.
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
SELECT depth, emp_id, first_name AS person
FROM org
ORDER BY path_ids
LIMIT 9;

-- Example 11: indentation makes the outline readable.
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
ORDER BY path_ids
LIMIT 12;

-- =====================================================================
-- Part E: data quality and safety (everything below is rolled back)
-- =====================================================================

-- Example 12: corrupt the data on purpose. Two employees (14 and 15) become each other's manager,
-- a detached cycle that no one above can reach.
BEGIN;
UPDATE employees SET manager_id = 15 WHERE emp_id = 14;
UPDATE employees SET manager_id = 14 WHERE emp_id = 15;

-- Top-down from the root still FINISHES, and the reconciliation exposes the problem: 28 of 30.
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
       (SELECT array_agg(emp_id ORDER BY emp_id)
        FROM employees WHERE emp_id NOT IN (SELECT emp_id FROM org)) AS unreachable_ids;

-- UPWARD traversal from inside the cycle, and the closure, have no end: only a timeout stops them.
SET statement_timeout = '300ms';
SELECT pg_temp.try_sql($q$
    WITH RECURSIVE up(emp_id, manager_id) AS (
        SELECT emp_id, manager_id FROM employees WHERE emp_id = 14
        UNION ALL
        SELECT e.emp_id, e.manager_id FROM employees e JOIN up ON e.emp_id = up.manager_id
    ) SELECT COUNT(*) FROM up $q$) AS upward_without_guard;
SELECT pg_temp.try_sql($q$
    WITH RECURSIVE reports(manager_id, emp_id, distance) AS (
        SELECT manager_id, emp_id, 1 FROM employees WHERE manager_id IS NOT NULL
        UNION ALL
        SELECT r.manager_id, e.emp_id, r.distance + 1 FROM reports r JOIN employees e ON e.manager_id = r.emp_id
    ) SELECT COUNT(*) FROM reports $q$) AS closure_without_guard;
RESET statement_timeout;

-- A depth guard makes the same upward query safe (it simply stops after 10 levels).
WITH RECURSIVE up(emp_id, manager_id, depth) AS (
    SELECT emp_id, manager_id, 1 FROM employees WHERE emp_id = 14
    UNION ALL
    SELECT e.emp_id, e.manager_id, u.depth + 1
    FROM employees e
    JOIN up u ON e.emp_id = u.manager_id
    WHERE u.depth < 10                                   -- the guard
)
SELECT COUNT(*) AS rows_with_guard FROM up;
ROLLBACK;
