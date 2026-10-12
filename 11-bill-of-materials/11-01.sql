-- Exercise 11-01: explode the Bicycle into its raw parts, with the total quantity of each.
-- The quantity is MULTIPLIED down the levels (2 wheel assemblies x 32 spokes = 64 spokes), and then
-- SUMMED per part, because a part can be reached by several branches (Bolt: 8 + 5 = 13).
-- Part A: the purchase list: raw parts only (nothing is built from them). Expected: 14 rows.
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
SELECT p.part_id,
       p.part_name,
       SUM(e.total_qty) AS total_qty
FROM exploded e
JOIN parts p ON p.part_id = e.part_id
WHERE NOT EXISTS (SELECT 1 FROM bom x WHERE x.assembly_id = e.part_id)
GROUP BY p.part_id, p.part_name
ORDER BY p.part_id;

-- Part B: reconcile. Rows in the full explosion, deepest level, raw part types, raw units and bolts.
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
SELECT (SELECT COUNT(*)     FROM exploded)                                   AS explosion_rows,
       (SELECT MAX(level)   FROM exploded)                                   AS deepest_level,
       (SELECT COUNT(DISTINCT e.part_id) FROM exploded e WHERE NOT EXISTS (SELECT 1 FROM bom x WHERE x.assembly_id = e.part_id)) AS raw_part_types,
       (SELECT SUM(e.total_qty)          FROM exploded e WHERE NOT EXISTS (SELECT 1 FROM bom x WHERE x.assembly_id = e.part_id)) AS raw_units,
       (SELECT SUM(total_qty) FROM exploded WHERE part_id = 17)              AS bolts_in_total;
