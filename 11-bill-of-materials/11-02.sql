-- Exercise 11-02: the cost of one Bicycle, and the rolled-up cost of every assembly.
-- Only raw parts carry a price (assemblies have NULL), so cost = SUM(total quantity x unit cost) over raw parts.
-- Part A: the unit cost of one Bicycle. Expected: 259.30.
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

-- Part B: the rolled-up cost of EVERY assembly, using a closure (each assembly paired with all its raw parts).
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

-- Part C: cross-check two independent ways, plus the data-quality counts that make the cost trustworthy.
--   cost_from_explosion   raw parts of the whole bicycle
--   cost_from_components  the Bicycle's own components, each at its rolled-up cost
WITH RECURSIVE
exploded(part_id, level, total_qty, path) AS (
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
),
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
SELECT ROUND((SELECT SUM(e.total_qty * p.unit_cost)
              FROM exploded e JOIN parts p ON p.part_id = e.part_id
              WHERE NOT EXISTS (SELECT 1 FROM bom x WHERE x.assembly_id = e.part_id)), 2)                                           AS cost_from_explosion,
       ROUND((SELECT SUM(b.qty * COALESCE(p.unit_cost, r.unit_cost))
              FROM bom b
              JOIN parts p ON p.part_id = b.component_id
              LEFT JOIN rolled_up r ON r.part_id = b.component_id
              WHERE b.assembly_id = 1), 2)                                          AS cost_from_components,
       (SELECT COUNT(*) FROM parts p
        WHERE EXISTS (SELECT 1 FROM bom b WHERE b.assembly_id = p.part_id)
          AND p.unit_cost IS NOT NULL)                                              AS assemblies_with_a_price,
       (SELECT COUNT(*) FROM parts p
        WHERE NOT EXISTS (SELECT 1 FROM bom b WHERE b.assembly_id = p.part_id)
          AND p.unit_cost IS NULL)                                                  AS raw_parts_without_price;
