-- Exercise 10-04: the SEARCH clause (PostgreSQL 14 or newer): breadth-first and depth-first order.
-- SEARCH only ADDS an ordering column (ordercol). The outer query must ORDER BY it.
-- The BY column decides the order of rows at the same level. It must make every row unique,
-- so BREADTH FIRST uses the path of road ids; DEPTH FIRST can use the id of the last road.
-- Part A: BREADTH FIRST: all cities 0 hops away, then 1 hop, then 2, ... Expected: 12 rows.
WITH RECURSIVE walk(city, via, hops, path, path_ids) AS (
    SELECT 'Nairobi'::text, 0, 0, ARRAY['Nairobi'::text], ARRAY[0]    -- via = id of the road used to get here
    UNION ALL
    SELECT r.destination, r.route_id, w.hops + 1, w.path || r.destination, w.path_ids || r.route_id
    FROM walk w
    JOIN routes r ON r.origin = w.city
    WHERE NOT (r.destination = ANY (w.path))
)
SEARCH BREADTH FIRST BY path_ids SET ordercol
SELECT ROW_NUMBER() OVER (ORDER BY ordercol) AS step,
       hops,
       array_to_string(path, ' > ') AS route
FROM walk
ORDER BY ordercol;

-- Part B: DEPTH FIRST: follow one branch to the end before starting the next. Expected: 12 rows.
WITH RECURSIVE walk(city, via, hops, path, path_ids) AS (
    SELECT 'Nairobi'::text, 0, 0, ARRAY['Nairobi'::text], ARRAY[0]    -- via = id of the road used to get here
    UNION ALL
    SELECT r.destination, r.route_id, w.hops + 1, w.path || r.destination, w.path_ids || r.route_id
    FROM walk w
    JOIN routes r ON r.origin = w.city
    WHERE NOT (r.destination = ANY (w.path))
)
SEARCH DEPTH FIRST BY via SET ordercol
SELECT ROW_NUMBER() OVER (ORDER BY ordercol) AS step,
       hops,
       array_to_string(path, ' > ') AS route
FROM walk
ORDER BY ordercol;

-- Part C: SEARCH is shorthand for tricks from Module 9. Both checks must be true.
--   DEPTH FIRST   = ORDER BY the path of road ids (outline order)
--   BREADTH FIRST = ORDER BY hops, then the path of road ids
-- NOTE: breadth-first order only sorts by depth and the BY column. If two rows tie, their order is NOT
-- guaranteed, so the BY column must make every row unique. (Ordering by just "via" would tie the two
-- routes that end with the same last road, Kampala > Kigali.) A path of ids is unique per row.
WITH RECURSIVE bf(city, via, hops, path, path_ids) AS (
    SELECT 'Nairobi'::text, 0, 0, ARRAY['Nairobi'::text], ARRAY[0]
    UNION ALL
    SELECT r.destination, r.route_id, b.hops + 1, b.path || r.destination, b.path_ids || r.route_id
    FROM bf b JOIN routes r ON r.origin = b.city
    WHERE NOT (r.destination = ANY (b.path))
)
SEARCH BREADTH FIRST BY path_ids SET ordercol,
df(city, via, hops, path, path_ids) AS (
    SELECT 'Nairobi'::text, 0, 0, ARRAY['Nairobi'::text], ARRAY[0]
    UNION ALL
    SELECT r.destination, r.route_id, d.hops + 1, d.path || r.destination, d.path_ids || r.route_id
    FROM df d JOIN routes r ON r.origin = d.city
    WHERE NOT (r.destination = ANY (d.path))
)
SEARCH DEPTH FIRST BY via SET ordercol
SELECT (SELECT array_agg(array_to_string(path, ' > ') ORDER BY ordercol) FROM bf)
     = (SELECT array_agg(array_to_string(path, ' > ') ORDER BY hops, path_ids) FROM bf) AS breadth_first_is_hops_then_path,
       (SELECT array_agg(array_to_string(path, ' > ') ORDER BY ordercol) FROM df)
     = (SELECT array_agg(array_to_string(path, ' > ') ORDER BY path_ids) FROM df)       AS depth_first_is_path_of_ids;
