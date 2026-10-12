-- Exercise 11-03: WHERE-USED. Every assembly that directly or indirectly uses the Bolt (part 17).
-- The recursion runs UPWARDS: start at the Bolt, join to the assemblies that contain it, then to the
-- assemblies that contain those. Quantities are multiplied on the way up.
-- Part A: every route up from the Bolt, with the number of bolts consumed. Expected: 5 rows.
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
SELECT levels_up,
       route,
       bolts
FROM used_in
ORDER BY levels_up, assembly_id, bolts;

-- Part B: per assembly, the total number of bolts in ONE unit (the Bicycle is reached by two routes).
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
SELECT a.part_id,
       a.part_name,
       SUM(u.bolts) AS bolts_per_unit,
       COUNT(*)     AS routes
FROM used_in u
JOIN parts a ON a.part_id = u.assembly_id
GROUP BY a.part_id, a.part_name
ORDER BY a.part_id;

-- Part C: cross-check. Walking UP from the Bolt and exploding DOWN from the Bicycle must agree on 13.
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
),
exploded_down(part_id, total_qty) AS (
    SELECT part_id, 1 FROM parts WHERE part_id = 1
    UNION ALL
    SELECT b.component_id, d.total_qty * b.qty FROM exploded_down d JOIN bom b ON b.assembly_id = d.part_id
)
SELECT (SELECT SUM(bolts) FROM used_in WHERE assembly_id = 1)               AS bolts_found_going_up,
       (SELECT SUM(total_qty) FROM exploded_down WHERE part_id = 17)        AS bolts_found_going_down,
       (SELECT SUM(bolts) FROM used_in WHERE assembly_id = 1)
     = (SELECT SUM(total_qty) FROM exploded_down WHERE part_id = 17)        AS they_agree;
