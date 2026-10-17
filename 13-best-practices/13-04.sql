-- Exercise 13-04: four ways to store a hierarchy, compared with evidence.
-- The same category tree is built as: (1) the adjacency list used in this course, (2) a materialized path,
-- (3) a closure table, (4) the ltree type. Everything runs inside BEGIN ... ROLLBACK. Needs the ltree extension
-- (included with standard PostgreSQL installs).

BEGIN;
CREATE EXTENSION IF NOT EXISTS ltree;                       -- ships with PostgreSQL (contrib); the ROLLBACK below undoes it

-- Model 2: MATERIALIZED PATH. Each row stores its whole path from the root, for example '1/5/6/'.
CREATE TEMP TABLE cat_path AS
WITH RECURSIVE t(category_id, path) AS (
    SELECT category_id, category_id::text || '/' FROM categories WHERE parent_id IS NULL
    UNION ALL
    SELECT c.category_id, t.path || c.category_id || '/' FROM categories c JOIN t ON c.parent_id = t.category_id
)
SELECT category_id, path FROM t;

-- Model 3: CLOSURE TABLE. Every node paired with each of its descendants (itself included, at depth 0).
CREATE TEMP TABLE cat_closure AS
WITH RECURSIVE c(ancestor_id, descendant_id, depth) AS (
    SELECT category_id, category_id, 0 FROM categories
    UNION ALL
    SELECT c.ancestor_id, k.category_id, c.depth + 1 FROM c JOIN categories k ON k.parent_id = c.descendant_id
)
SELECT ancestor_id, descendant_id, depth FROM c;

-- Model 4: LTREE. The same path as a special indexable type, for example 1.5.6
CREATE TEMP TABLE cat_ltree AS
SELECT category_id, replace(trim(trailing '/' FROM path), '/', '.')::ltree AS path FROM cat_path;

-- Model 1 (the one used all through this course): the categories table itself, read with a recursive CTE.
CREATE OR REPLACE FUNCTION pg_temp.subtree_adjacency(root int) RETURNS SETOF int
LANGUAGE sql AS $$
    WITH RECURSIVE d(category_id) AS (
        SELECT root
        UNION ALL
        SELECT c.category_id FROM categories c JOIN d ON c.parent_id = d.category_id
    ) SELECT category_id FROM d
$$;

-- Number of ids that appear in one array but not the other (0 = identical sets).
CREATE OR REPLACE FUNCTION pg_temp.sym_diff(a int[], b int[]) RETURNS bigint
LANGUAGE sql AS $$
    SELECT (SELECT COUNT(*) FROM (SELECT unnest(a) EXCEPT SELECT unnest(b)) x)
         + (SELECT COUNT(*) FROM (SELECT unnest(b) EXCEPT SELECT unnest(a)) y)
$$;

-- Part A: READ the subtree of Electronics (category 1: itself and everything below). Every model must return
-- the same 7 categories. Expected: 7 rows in every model, 0 differences.
WITH expected AS (SELECT array_agg(x ORDER BY x) AS ids FROM pg_temp.subtree_adjacency(1) AS x)
SELECT model, rows_found, differences_from_adjacency
FROM (
    SELECT 1 AS ord, 'adjacency list + recursive CTE' AS model, cardinality(ids) AS rows_found, 0::bigint AS differences_from_adjacency
    FROM expected
    UNION ALL
    SELECT 2, 'materialized path',
           (SELECT COUNT(*) FROM cat_path WHERE path LIKE '1/%'),
           pg_temp.sym_diff((SELECT array_agg(category_id) FROM cat_path WHERE path LIKE '1/%'), (SELECT ids FROM expected))
    UNION ALL
    SELECT 3, 'closure table',
           (SELECT COUNT(*) FROM cat_closure WHERE ancestor_id = 1),
           pg_temp.sym_diff((SELECT array_agg(descendant_id) FROM cat_closure WHERE ancestor_id = 1), (SELECT ids FROM expected))
    UNION ALL
    SELECT 4, 'ltree',
           (SELECT COUNT(*) FROM cat_ltree WHERE path <@ '1'::ltree),
           pg_temp.sym_diff((SELECT array_agg(category_id) FROM cat_ltree WHERE path <@ '1'::ltree), (SELECT ids FROM expected))
) q
ORDER BY ord;

-- Part B: WRITE. Move the Phones subtree (Phones 5 and Smartphones 6) from Electronics under Office (8).
-- How many stored rows does each model have to change? Expected: 1, 2, 4, 2.
CREATE TEMP TABLE move_costs(ord int, model text, rows_changed bigint);

-- 1. adjacency list: just repoint the parent of Phones (5) to Office (8)
WITH m AS (UPDATE categories SET parent_id = 8 WHERE category_id = 5 RETURNING 1)
INSERT INTO move_costs SELECT 1, 'adjacency list + recursive CTE', COUNT(*) FROM m;

-- 2. materialized path: rewrite the path of the moved node and of everything below it
WITH m AS (UPDATE cat_path SET path = '8/5/' || substr(path, length('1/5/') + 1) WHERE path LIKE '1/5/%' RETURNING 1)
INSERT INTO move_costs SELECT 2, 'materialized path', COUNT(*) FROM m;

-- 3. closure table: remove the links from the OLD ancestors, add links from the NEW ones
WITH moved AS (SELECT descendant_id, depth FROM cat_closure WHERE ancestor_id = 5),
del AS (DELETE FROM cat_closure
        WHERE descendant_id IN (SELECT descendant_id FROM moved)
          AND ancestor_id NOT IN (SELECT descendant_id FROM moved)
        RETURNING 1),
ins AS (INSERT INTO cat_closure
        SELECT a.ancestor_id, m.descendant_id, a.depth + 1 + m.depth
        FROM cat_closure a CROSS JOIN moved m
        WHERE a.descendant_id = 8
        RETURNING 1)
INSERT INTO move_costs SELECT 3, 'closure table', (SELECT COUNT(*) FROM del) + (SELECT COUNT(*) FROM ins);

-- 4. ltree: the same rewrite as the materialized path (the moved node itself has nothing left to append)
WITH m AS (UPDATE cat_ltree
           SET path = CASE WHEN nlevel(path) = nlevel('1.5'::ltree) THEN '8.5'::ltree
                           ELSE '8.5'::ltree || subpath(path, nlevel('1.5'::ltree)) END
           WHERE path <@ '1.5'::ltree
           RETURNING 1)
INSERT INTO move_costs SELECT 4, 'ltree', COUNT(*) FROM m;

SELECT model, rows_changed FROM move_costs ORDER BY ord;

-- Part C: after the move every model must still answer correctly, for Office (now 7 categories) and for
-- Electronics (now 5). Expected: true everywhere.
SELECT m.model,
       (m.office_diff = 0)      AS office_subtree_correct,
       (m.electronics_diff = 0) AS electronics_subtree_correct
FROM (
    SELECT 1 AS ord, 'adjacency list + recursive CTE' AS model, 0::bigint AS office_diff, 0::bigint AS electronics_diff
    UNION ALL
    SELECT 2, 'materialized path',
           pg_temp.sym_diff((SELECT array_agg(category_id) FROM cat_path WHERE path LIKE '8/%'), (SELECT array_agg(x) FROM pg_temp.subtree_adjacency(8) x)),
           pg_temp.sym_diff((SELECT array_agg(category_id) FROM cat_path WHERE path LIKE '1/%'), (SELECT array_agg(x) FROM pg_temp.subtree_adjacency(1) x))
    UNION ALL
    SELECT 3, 'closure table',
           pg_temp.sym_diff((SELECT array_agg(descendant_id) FROM cat_closure WHERE ancestor_id = 8), (SELECT array_agg(x) FROM pg_temp.subtree_adjacency(8) x)),
           pg_temp.sym_diff((SELECT array_agg(descendant_id) FROM cat_closure WHERE ancestor_id = 1), (SELECT array_agg(x) FROM pg_temp.subtree_adjacency(1) x))
    UNION ALL
    SELECT 4, 'ltree',
           pg_temp.sym_diff((SELECT array_agg(category_id) FROM cat_ltree WHERE path <@ '8'::ltree), (SELECT array_agg(x) FROM pg_temp.subtree_adjacency(8) x)),
           pg_temp.sym_diff((SELECT array_agg(category_id) FROM cat_ltree WHERE path <@ '1'::ltree), (SELECT array_agg(x) FROM pg_temp.subtree_adjacency(1) x))
) m
ORDER BY m.ord;

-- Part D: STORAGE. How many rows does each model keep for these 12 categories? Expected: 12, 12, 27, 12.
SELECT model, stored_rows
FROM (
    SELECT 1 AS ord, 'adjacency list + recursive CTE' AS model, (SELECT COUNT(*) FROM categories)  AS stored_rows
    UNION ALL SELECT 2, 'materialized path', (SELECT COUNT(*) FROM cat_path)
    UNION ALL SELECT 3, 'closure table',     (SELECT COUNT(*) FROM cat_closure)
    UNION ALL SELECT 4, 'ltree',             (SELECT COUNT(*) FROM cat_ltree)
) s
ORDER BY ord;
ROLLBACK;
