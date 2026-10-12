-- Module 11 worked examples: bill of materials with recursive CTEs.
-- Run:  psql -d cte_lab -f 11-bill-of-materials/examples.sql
-- The CYCLE clause used in Examples 11 and 12 needs PostgreSQL 14 or newer.

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
-- Part A: the BOM and its explosion
-- =====================================================================

-- Example 1: the BOM, with names. qty = how many of the component go into ONE of the assembly.
-- Bolt appears twice (under Frame and under Crankset): a shared component.
SELECT b.assembly_id, a.part_name AS assembly, b.component_id, c.part_name AS component, b.qty, c.unit_cost
FROM bom b
JOIN parts a ON a.part_id = b.assembly_id
JOIN parts c ON c.part_id = b.component_id
ORDER BY b.assembly_id, b.component_id;

-- Example 2: the EXPLOSION of the Bicycle. Every row, with its level and the quantity MULTIPLIED down.
WITH RECURSIVE exploded(part_id, level, total_qty, path) AS (
    SELECT part_id, 0, 1, ARRAY[part_id]                    -- anchor: ONE unit of the top-level part
    FROM parts
    WHERE part_id = 1                                       -- 1 = Bicycle (change to explode another assembly)
    UNION ALL
    SELECT b.component_id,
           e.level + 1,
           e.total_qty * b.qty,                             -- MULTIPLY the quantity down the levels
           e.path || b.component_id
    FROM exploded e
    JOIN bom b ON b.assembly_id = e.part_id
    WHERE NOT (b.component_id = ANY (e.path))               -- safety net: a part cannot contain itself
)
SELECT e.level, p.part_name, e.total_qty, p.unit_cost
FROM exploded e
JOIN parts p ON p.part_id = e.part_id
ORDER BY e.path;

-- Example 3: the INDENTED BOM (outline order, as in Module 9), with the quantity per parent and in total.
WITH RECURSIVE ex(part_id, level, qty_per, total_qty, path) AS (
    SELECT part_id, 0, 1, 1, ARRAY[part_id] FROM parts WHERE part_id = 1
    UNION ALL
    SELECT b.component_id, e.level + 1, b.qty, e.total_qty * b.qty, e.path || b.component_id
    FROM ex e
    JOIN bom b ON b.assembly_id = e.part_id
    WHERE NOT (b.component_id = ANY (e.path))
)
SELECT repeat('    ', e.level) || p.part_name AS indented_bom, e.qty_per, e.total_qty
FROM ex e
JOIN parts p ON p.part_id = e.part_id
ORDER BY e.path;

-- Example 4: the PURCHASE LIST. Keep only raw parts (nothing is built from them), then SUM per part,
-- because the same part can be reached by several branches (Bolt: 8 + 5 = 13).
WITH RECURSIVE exploded(part_id, level, total_qty, path) AS (
    SELECT part_id, 0, 1, ARRAY[part_id]                    -- anchor: ONE unit of the top-level part
    FROM parts
    WHERE part_id = 1                                       -- 1 = Bicycle (change to explode another assembly)
    UNION ALL
    SELECT b.component_id,
           e.level + 1,
           e.total_qty * b.qty,                             -- MULTIPLY the quantity down the levels
           e.path || b.component_id
    FROM exploded e
    JOIN bom b ON b.assembly_id = e.part_id
    WHERE NOT (b.component_id = ANY (e.path))               -- safety net: a part cannot contain itself
)
SELECT p.part_id, p.part_name, SUM(e.total_qty) AS total_qty, p.unit_cost,
       SUM(e.total_qty * p.unit_cost) AS line_cost
FROM exploded e
JOIN parts p ON p.part_id = e.part_id
WHERE NOT EXISTS (SELECT 1 FROM bom x WHERE x.assembly_id = e.part_id)
GROUP BY p.part_id, p.part_name, p.unit_cost
ORDER BY p.part_id;

-- =====================================================================
-- Part B: two classic traps
-- =====================================================================

-- Example 5: FORGETTING TO MULTIPLY. The naive version keeps only each line's own qty.
-- The Wheel Assembly is used TWICE, but its 32 spokes are counted once.
WITH RECURSIVE good(part_id, total_qty) AS (
    SELECT part_id, 1 FROM parts WHERE part_id = 1
    UNION ALL
    SELECT b.component_id, g.total_qty * b.qty FROM good g JOIN bom b ON b.assembly_id = g.part_id
),
naive(part_id, total_qty) AS (
    SELECT part_id, 1 FROM parts WHERE part_id = 1
    UNION ALL
    SELECT b.component_id, b.qty FROM naive n JOIN bom b ON b.assembly_id = n.part_id
)
SELECT (SELECT ROUND(SUM(g.total_qty * p.unit_cost), 2) FROM good  g JOIN parts p USING (part_id)) AS correct_cost,
       (SELECT ROUND(SUM(n.total_qty * p.unit_cost), 2) FROM naive n JOIN parts p USING (part_id)) AS cost_if_you_forget_to_multiply,
       (SELECT SUM(total_qty) FROM good  WHERE part_id = 8) AS spokes_correct,
       (SELECT SUM(total_qty) FROM naive WHERE part_id = 8) AS spokes_if_you_forget_to_multiply;

-- Example 6: THE UNION TRAP (everything is rolled back). Suppose the Drivetrain ALSO used 8 bolts.
-- Two branches now produce the IDENTICAL row (Bolt, 8). UNION treats them as duplicates and drops one.
BEGIN;
INSERT INTO bom VALUES (4, 17, 8);
WITH RECURSIVE with_union_all(part_id, total_qty) AS (
    SELECT part_id, 1 FROM parts WHERE part_id = 1
    UNION ALL
    SELECT b.component_id, e.total_qty * b.qty FROM with_union_all e JOIN bom b ON b.assembly_id = e.part_id
),
with_union(part_id, total_qty) AS (
    SELECT part_id, 1 FROM parts WHERE part_id = 1
    UNION
    SELECT b.component_id, e.total_qty * b.qty FROM with_union e JOIN bom b ON b.assembly_id = e.part_id
)
SELECT (SELECT SUM(total_qty) FROM with_union_all WHERE part_id = 17) AS bolts_with_union_all,
       (SELECT SUM(total_qty) FROM with_union     WHERE part_id = 17) AS bolts_with_union;
ROLLBACK;

-- =====================================================================
-- Part C: costing
-- =====================================================================

-- Example 7: the cost of ONE Bicycle: quantity needed x unit cost, over the raw parts.
WITH RECURSIVE exploded(part_id, level, total_qty, path) AS (
    SELECT part_id, 0, 1, ARRAY[part_id]                    -- anchor: ONE unit of the top-level part
    FROM parts
    WHERE part_id = 1                                       -- 1 = Bicycle (change to explode another assembly)
    UNION ALL
    SELECT b.component_id,
           e.level + 1,
           e.total_qty * b.qty,                             -- MULTIPLY the quantity down the levels
           e.path || b.component_id
    FROM exploded e
    JOIN bom b ON b.assembly_id = e.part_id
    WHERE NOT (b.component_id = ANY (e.path))               -- safety net: a part cannot contain itself
)
SELECT ROUND(SUM(e.total_qty * p.unit_cost), 2) AS bicycle_unit_cost
FROM exploded e
JOIN parts p ON p.part_id = e.part_id
WHERE NOT EXISTS (SELECT 1 FROM bom x WHERE x.assembly_id = e.part_id);

-- Example 8: the rolled-up cost of EVERY assembly at once. The CLOSURE pairs each assembly (root) with all
-- of its raw parts and their multiplied quantities (as in Module 9, but with quantities).
WITH RECURSIVE
closure(root_id, part_id, total_qty) AS (          -- every assembly as its own root
    SELECT assembly_id, component_id, qty
    FROM bom                                                -- anchor: every direct component line
    UNION ALL
    SELECT c.root_id, b.component_id, c.total_qty * b.qty   -- multiply down, keeping the root
    FROM closure c
    JOIN bom b ON b.assembly_id = c.part_id
),
rolled_up AS (                                              -- grain: one row per assembly
    SELECT r.part_id, r.part_name,
           SUM(c.total_qty * p.unit_cost) AS unit_cost
    FROM closure c
    JOIN parts r ON r.part_id = c.root_id
    JOIN parts p ON p.part_id = c.part_id
    GROUP BY r.part_id, r.part_name
)
SELECT part_id, part_name, ROUND(unit_cost, 2) AS rolled_up_unit_cost
FROM rolled_up
ORDER BY part_id;

-- Example 9: data quality BEFORE trusting a cost. These four counts should be 0, 0, 1 and 0.
SELECT (SELECT COUNT(*) FROM parts p
        WHERE EXISTS (SELECT 1 FROM bom b WHERE b.assembly_id = p.part_id) AND p.unit_cost IS NOT NULL)  AS assemblies_with_a_price,
       (SELECT COUNT(*) FROM parts p
        WHERE NOT EXISTS (SELECT 1 FROM bom b WHERE b.assembly_id = p.part_id) AND p.unit_cost IS NULL) AS raw_parts_without_price,
       (SELECT COUNT(*) FROM parts p
        WHERE NOT EXISTS (SELECT 1 FROM bom b WHERE b.component_id = p.part_id))                        AS top_level_parts,
       (SELECT COUNT(*) FROM parts p
        WHERE NOT EXISTS (SELECT 1 FROM bom b WHERE b.component_id = p.part_id OR b.assembly_id = p.part_id)) AS parts_in_no_bom;

-- Example 10: A MISSING PRICE LOWERS THE TOTAL SILENTLY (rolled back). SUM ignores NULL, so no error appears.
BEGIN;
UPDATE parts SET unit_cost = NULL WHERE part_id = 9;                     -- the Hub loses its price
WITH RECURSIVE exploded(part_id, level, total_qty, path) AS (
    SELECT part_id, 0, 1, ARRAY[part_id]                    -- anchor: ONE unit of the top-level part
    FROM parts
    WHERE part_id = 1                                       -- 1 = Bicycle (change to explode another assembly)
    UNION ALL
    SELECT b.component_id,
           e.level + 1,
           e.total_qty * b.qty,                             -- MULTIPLY the quantity down the levels
           e.path || b.component_id
    FROM exploded e
    JOIN bom b ON b.assembly_id = e.part_id
    WHERE NOT (b.component_id = ANY (e.path))               -- safety net: a part cannot contain itself
)
SELECT ROUND(SUM(e.total_qty * p.unit_cost), 2) AS total_cost_that_looks_fine,
       COUNT(*) FILTER (WHERE p.unit_cost IS NULL AND NOT EXISTS (SELECT 1 FROM bom x WHERE x.assembly_id = e.part_id)) AS raw_parts_without_price
FROM exploded e
JOIN parts p ON p.part_id = e.part_id;
ROLLBACK;

-- =====================================================================
-- Part D: where-used (upwards), and cycles
-- =====================================================================

-- Example 11: WHERE-USED. Start at one part and walk UP through the parents, multiplying as you go.
-- Where is the Bolt used, and how many bolts does one unit of each assembly consume?
WITH RECURSIVE used_in(assembly_id, levels_up, bolts, route, path) AS (
    SELECT b.assembly_id, 1, b.qty, 'Bolt < ' || a.part_name, ARRAY[b.component_id, b.assembly_id]
    FROM bom b
    JOIN parts a ON a.part_id = b.assembly_id
    WHERE b.component_id = 17                               -- 17 = Bolt: the part we are tracing upwards
    UNION ALL
    SELECT b.assembly_id,
           u.levels_up + 1,
           u.bolts * b.qty,                                 -- multiply UP as well: bolts per one unit of the parent
           u.route || ' < ' || a.part_name,
           u.path || b.assembly_id
    FROM used_in u
    JOIN bom   b ON b.component_id = u.assembly_id          -- the join runs the other way
    JOIN parts a ON a.part_id      = b.assembly_id
    WHERE NOT (b.assembly_id = ANY (u.path))
)
SELECT levels_up, route, bolts
FROM used_in
ORDER BY levels_up, assembly_id, bolts;

WITH RECURSIVE used_in(assembly_id, levels_up, bolts, route, path) AS (
    SELECT b.assembly_id, 1, b.qty, 'Bolt < ' || a.part_name, ARRAY[b.component_id, b.assembly_id]
    FROM bom b
    JOIN parts a ON a.part_id = b.assembly_id
    WHERE b.component_id = 17                               -- 17 = Bolt: the part we are tracing upwards
    UNION ALL
    SELECT b.assembly_id,
           u.levels_up + 1,
           u.bolts * b.qty,                                 -- multiply UP as well: bolts per one unit of the parent
           u.route || ' < ' || a.part_name,
           u.path || b.assembly_id
    FROM used_in u
    JOIN bom   b ON b.component_id = u.assembly_id          -- the join runs the other way
    JOIN parts a ON a.part_id      = b.assembly_id
    WHERE NOT (b.assembly_id = ANY (u.path))
)
SELECT a.part_id, a.part_name, SUM(u.bolts) AS bolts_per_unit, COUNT(*) AS routes
FROM used_in u
JOIN parts a ON a.part_id = u.assembly_id
GROUP BY a.part_id, a.part_name
ORDER BY a.part_id;

-- Example 12: A CYCLE IN THE BOM (everything is rolled back). We make the Bolt "contain" the Bicycle.
-- The explosion does not hang: quantities multiply on every trip round the loop and overflow an integer,
-- so you get "integer out of range", an error message that does NOT mention the real cause.
BEGIN;
INSERT INTO bom VALUES (17, 1, 1);
SET statement_timeout = '2s';
SELECT pg_temp.try_sql($q$
    WITH RECURSIVE ex(part_id, total_qty) AS (
        SELECT part_id, 1 FROM parts WHERE part_id = 1
        UNION ALL
        SELECT b.component_id, e.total_qty * b.qty FROM ex e JOIN bom b ON b.assembly_id = e.part_id
    ) SELECT COUNT(*) FROM ex $q$) AS unguarded_explosion_with_a_cycle;
RESET statement_timeout;

-- The BOM AUDIT: pair every part with everything below it, and let CYCLE flag any part that reappears
-- on its own path. On clean data this returns 0.
WITH RECURSIVE reach(root_id, part_id) AS (
    SELECT part_id, part_id FROM parts
    UNION ALL
    SELECT r.root_id, b.component_id FROM reach r JOIN bom b ON b.assembly_id = r.part_id
)
CYCLE part_id SET is_cycle USING path
SELECT COUNT(*) FILTER (WHERE is_cycle) AS cycle_rows_found FROM reach;
ROLLBACK;

-- The same audit on the real, clean BOM:
WITH RECURSIVE reach(root_id, part_id) AS (
    SELECT part_id, part_id FROM parts
    UNION ALL
    SELECT r.root_id, b.component_id FROM reach r JOIN bom b ON b.assembly_id = r.part_id
)
CYCLE part_id SET is_cycle USING path
SELECT COUNT(*) FILTER (WHERE is_cycle) AS cycle_rows_found FROM reach;
