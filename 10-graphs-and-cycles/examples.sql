-- Module 10 worked examples: graphs, cycles, CYCLE and SEARCH.
-- Run:  psql -d cte_lab -f 10-graphs-and-cycles/examples.sql
-- Needs PostgreSQL 14 or newer (the CYCLE and SEARCH clauses were added in version 14).

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
-- Part A: the graph, and plain reachability
-- =====================================================================

-- Example 1: the roads. Each row is a ONE-WAY edge from origin to destination.
SELECT route_id, origin, destination, distance_km
FROM routes
ORDER BY route_id;

-- Example 2: REACHABILITY. Which cities can be reached from Nairobi? Each round carries only a city,
-- so rows repeat exactly, and UNION (which discards repeats) ends the recursion by itself, cycles and all.
WITH RECURSIVE reach(city) AS (
    SELECT 'Nairobi'::text
    UNION
    SELECT r.destination
    FROM reach c
    JOIN routes r ON r.origin = c.city
)
SELECT COUNT(*) AS reachable_cities FROM reach;

-- =====================================================================
-- Part B: enumerating routes, and three ways to stop the loops
-- =====================================================================

-- Example 3: enumerate every walk from Nairobi with NO protection. It never ends; a timeout cancels it.
SET statement_timeout = '300ms';
SELECT pg_temp.try_sql($q$
    WITH RECURSIVE walk(city, total_km, hops) AS (
        SELECT 'Nairobi'::text, 0, 0
        UNION ALL
        SELECT r.destination, w.total_km + r.distance_km, w.hops + 1
        FROM walk w JOIN routes r ON r.origin = w.city
    ) SELECT COUNT(*) FROM walk WHERE city = 'Kigali' $q$) AS unprotected_result;
RESET statement_timeout;

-- Example 4: GUARD 1, a depth limit. It stops the query, but it counts every LOOP as a new "route".
-- There are only 2 real routes to Kigali.
WITH RECURSIVE walk(city, total_km, hops) AS (
    SELECT 'Nairobi'::text, 0, 0
    UNION ALL
    SELECT r.destination, w.total_km + r.distance_km, w.hops + 1
    FROM walk w
    JOIN routes r ON r.origin = w.city
    WHERE w.hops < 16
)
SELECT g                                                         AS max_hops,
       (SELECT COUNT(*) FROM walk WHERE city = 'Kigali' AND hops <= g) AS walks_to_kigali,
       (SELECT COUNT(*) FROM walk WHERE hops <= g)                      AS all_walks
FROM generate_series(4, 16, 4) AS g
ORDER BY g;

-- Example 5: GUARD 2, a distance budget. Every road has a positive length, so total distance only grows
-- and the query must end. But loops that fit in the budget are still counted as routes.
SELECT b.budget,
       (SELECT COUNT(*) FROM (
            WITH RECURSIVE walk(city, total_km) AS (
                SELECT 'Nairobi'::text, 0
                UNION ALL
                SELECT r.destination, w.total_km + r.distance_km
                FROM walk w
                JOIN routes r ON r.origin = w.city
                WHERE w.total_km + r.distance_km <= b.budget
            )
            SELECT 1 FROM walk WHERE city = 'Kigali') k) AS walks_to_kigali
FROM (VALUES (1300), (2000), (3000), (4000)) AS b(budget)
ORDER BY b.budget;

-- Example 6: GUARD 3, the PATH CHECK (the standard technique). Carry the cities visited so far in an array
-- and refuse to enter a city that is already in it. Every row is now a genuine simple path.
WITH RECURSIVE walk(city, total_km, hops, path) AS (
    SELECT 'Nairobi'::text, 0, 0, ARRAY['Nairobi'::text]     -- anchor: the start city
    UNION ALL
    SELECT r.destination,
           w.total_km + r.distance_km,
           w.hops + 1,
           w.path || r.destination
    FROM walk w
    JOIN routes r ON r.origin = w.city                       -- follow every road leaving the current city
    WHERE NOT (r.destination = ANY (w.path))                 -- never visit a city twice on one route
)
SELECT hops, array_to_string(path, ' > ') AS route, total_km
FROM walk
ORDER BY hops, total_km;

-- Example 7: the routes from Nairobi to Kigali.
WITH RECURSIVE walk(city, total_km, hops, path) AS (
    SELECT 'Nairobi'::text, 0, 0, ARRAY['Nairobi'::text]     -- anchor: the start city
    UNION ALL
    SELECT r.destination,
           w.total_km + r.distance_km,
           w.hops + 1,
           w.path || r.destination
    FROM walk w
    JOIN routes r ON r.origin = w.city                       -- follow every road leaving the current city
    WHERE NOT (r.destination = ANY (w.path))                 -- never visit a city twice on one route
)
SELECT array_to_string(path, ' > ') AS route, total_km, hops
FROM walk
WHERE city = 'Kigali'
ORDER BY total_km;

-- Example 8: unlike a tree, a graph node can be reached in SEVERAL ways. Count the routes to each city.
WITH RECURSIVE walk(city, total_km, hops, path) AS (
    SELECT 'Nairobi'::text, 0, 0, ARRAY['Nairobi'::text]     -- anchor: the start city
    UNION ALL
    SELECT r.destination,
           w.total_km + r.distance_km,
           w.hops + 1,
           w.path || r.destination
    FROM walk w
    JOIN routes r ON r.origin = w.city                       -- follow every road leaving the current city
    WHERE NOT (r.destination = ANY (w.path))                 -- never visit a city twice on one route
)
SELECT city,
       COUNT(*)      AS simple_paths,
       MIN(total_km) AS shortest_km,
       MAX(total_km) AS longest_km
FROM walk
WHERE city <> 'Nairobi'
GROUP BY city
ORDER BY shortest_km;

-- =====================================================================
-- Part C: the CYCLE clause (PostgreSQL 14+)
-- =====================================================================

-- Example 9: CYCLE city SET is_cycle USING path. PostgreSQL tracks the cities visited, and when a row would
-- revisit one it FLAGS that row (is_cycle = true) and does not expand it further. These are the 4 places
-- where a walk from Nairobi came back to a city it had already visited.
WITH RECURSIVE walk(city, route, total_km, hops) AS (
    SELECT 'Nairobi'::text, 'Nairobi'::text, 0, 0
    UNION ALL
    SELECT r.destination,
           w.route || ' > ' || r.destination,
           w.total_km + r.distance_km,
           w.hops + 1
    FROM walk w
    JOIN routes r ON r.origin = w.city
)
CYCLE city SET is_cycle USING path
SELECT route, hops, total_km
FROM walk
WHERE is_cycle
ORDER BY hops, total_km;

-- What the "path" column looks like: an array with one record per visited city.
WITH RECURSIVE walk(city, route, total_km, hops) AS (
    SELECT 'Nairobi'::text, 'Nairobi'::text, 0, 0
    UNION ALL
    SELECT r.destination,
           w.route || ' > ' || r.destination,
           w.total_km + r.distance_km,
           w.hops + 1
    FROM walk w
    JOIN routes r ON r.origin = w.city
)
CYCLE city SET is_cycle USING path
SELECT path
FROM walk
WHERE is_cycle
ORDER BY hops, total_km
LIMIT 1;

-- Example 10: the routes to Kigali with CYCLE. Filter out the flagged rows, and compare with the manual guard.
WITH RECURSIVE walk(city, route, total_km, hops) AS (
    SELECT 'Nairobi'::text, 'Nairobi'::text, 0, 0
    UNION ALL
    SELECT r.destination,
           w.route || ' > ' || r.destination,
           w.total_km + r.distance_km,
           w.hops + 1
    FROM walk w
    JOIN routes r ON r.origin = w.city
)
CYCLE city SET is_cycle USING path
SELECT route, total_km, hops
FROM walk
WHERE city = 'Kigali' AND NOT is_cycle
ORDER BY total_km;

WITH RECURSIVE cycle_walk(city, route, total_km, hops) AS (
    SELECT 'Nairobi'::text, 'Nairobi'::text, 0, 0
    UNION ALL
    SELECT r.destination, w.route || ' > ' || r.destination, w.total_km + r.distance_km, w.hops + 1
    FROM cycle_walk w JOIN routes r ON r.origin = w.city
)
CYCLE city SET is_cycle USING cycle_path,
manual_walk(city, route, total_km, path) AS (
    SELECT 'Nairobi'::text, 'Nairobi'::text, 0, ARRAY['Nairobi'::text]
    UNION ALL
    SELECT r.destination, w.route || ' > ' || r.destination, w.total_km + r.distance_km, w.path || r.destination
    FROM manual_walk w JOIN routes r ON r.origin = w.city
    WHERE NOT (r.destination = ANY (w.path))
),
cycle_version  AS (SELECT route, total_km FROM cycle_walk  WHERE city = 'Kigali' AND NOT is_cycle),
manual_version AS (SELECT route, total_km FROM manual_walk WHERE city = 'Kigali')
SELECT (SELECT COUNT(*) FROM cycle_version)  AS cycle_rows,
       (SELECT COUNT(*) FROM manual_version) AS manual_rows,
       (SELECT COUNT(*) FROM (SELECT * FROM cycle_version EXCEPT SELECT * FROM manual_version) a)
     + (SELECT COUNT(*) FROM (SELECT * FROM manual_version EXCEPT SELECT * FROM cycle_version) b) AS differences;

-- Example 11: choose your own marker values with TO ... DEFAULT ...
WITH RECURSIVE walk(city, total_km, hops) AS (
    SELECT 'Nairobi'::text, 0, 0
    UNION ALL
    SELECT r.destination, w.total_km + r.distance_km, w.hops + 1
    FROM walk w JOIN routes r ON r.origin = w.city
)
CYCLE city SET looped TO 'Y' DEFAULT 'N' USING path
SELECT looped, COUNT(*) AS rows
FROM walk
GROUP BY looped
ORDER BY looped;

-- =====================================================================
-- Part D: the SEARCH clause (PostgreSQL 14+)
-- =====================================================================

-- Example 12: SEARCH BREADTH FIRST lists everything 0 hops away, then 1 hop, then 2, ...
-- SEARCH only ADDS the ordering column (ordercol); you still ORDER BY it yourself.
WITH RECURSIVE walk(city, via, hops, path, path_ids) AS (
    SELECT 'Nairobi'::text, 0, 0, ARRAY['Nairobi'::text], ARRAY[0]    -- via = id of the road used to get here
    UNION ALL
    SELECT r.destination, r.route_id, w.hops + 1, w.path || r.destination, w.path_ids || r.route_id
    FROM walk w
    JOIN routes r ON r.origin = w.city
    WHERE NOT (r.destination = ANY (w.path))
)
SEARCH BREADTH FIRST BY path_ids SET ordercol
SELECT ROW_NUMBER() OVER (ORDER BY ordercol) AS step, hops, array_to_string(path, ' > ') AS route
FROM walk
ORDER BY ordercol;

-- SEARCH DEPTH FIRST follows one branch all the way down before trying the next.
WITH RECURSIVE walk(city, via, hops, path, path_ids) AS (
    SELECT 'Nairobi'::text, 0, 0, ARRAY['Nairobi'::text], ARRAY[0]    -- via = id of the road used to get here
    UNION ALL
    SELECT r.destination, r.route_id, w.hops + 1, w.path || r.destination, w.path_ids || r.route_id
    FROM walk w
    JOIN routes r ON r.origin = w.city
    WHERE NOT (r.destination = ANY (w.path))
)
SEARCH DEPTH FIRST BY via SET ordercol
SELECT ROW_NUMBER() OVER (ORDER BY ordercol) AS step, hops, array_to_string(path, ' > ') AS route
FROM walk
ORDER BY ordercol;

-- Example 13: SEARCH is shorthand for tricks you already know from Module 9.
--   DEPTH FIRST   = ORDER BY the path of road ids (outline order)
--   BREADTH FIRST = ORDER BY hops, then the path of road ids
-- Breadth-first order sorts only by depth and the BY column, so the BY column must be UNIQUE per row.
-- (BY via alone would tie the two routes whose last road is Kampala > Kigali, leaving their order undefined.)
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

-- =====================================================================
-- Part E: shortest paths, and where recursive SQL runs out
-- =====================================================================

-- Example 14: the shortest route to Kigali: enumerate every simple path, sort, keep one.
WITH RECURSIVE walk(city, total_km, hops, path) AS (
    SELECT 'Nairobi'::text, 0, 0, ARRAY['Nairobi'::text]     -- anchor: the start city
    UNION ALL
    SELECT r.destination,
           w.total_km + r.distance_km,
           w.hops + 1,
           w.path || r.destination
    FROM walk w
    JOIN routes r ON r.origin = w.city                       -- follow every road leaving the current city
    WHERE NOT (r.destination = ANY (w.path))                 -- never visit a city twice on one route
)
SELECT array_to_string(path, ' > ') AS route, total_km, hops
FROM walk
WHERE city = 'Kigali'
ORDER BY total_km
LIMIT 1;

-- The shortest distance to EVERY city (DISTINCT ON keeps the first row per city after sorting).
WITH RECURSIVE walk(city, total_km, hops, path) AS (
    SELECT 'Nairobi'::text, 0, 0, ARRAY['Nairobi'::text]     -- anchor: the start city
    UNION ALL
    SELECT r.destination,
           w.total_km + r.distance_km,
           w.hops + 1,
           w.path || r.destination
    FROM walk w
    JOIN routes r ON r.origin = w.city                       -- follow every road leaving the current city
    WHERE NOT (r.destination = ANY (w.path))                 -- never visit a city twice on one route
)
SELECT city, total_km, route
FROM (
    SELECT DISTINCT ON (city) city, total_km, array_to_string(path, ' > ') AS route
    FROM walk
    WHERE city <> 'Nairobi'
    ORDER BY city, total_km
) best
ORDER BY total_km;

-- Example 15: THE LIMIT. Enumerating every path grows EXPONENTIALLY. A "ladder" graph has 2 nodes per
-- layer and every node connects to both nodes of the next layer, so n layers give 2^(n-1) paths.
CREATE TEMP TABLE ladder_edges AS
SELECT l AS from_layer, a AS from_node, b AS to_node
FROM generate_series(1, 24) AS l, generate_series(0, 1) AS a, generate_series(0, 1) AS b;

WITH RECURSIVE p(layer, node) AS (
    SELECT 1, 0
    UNION ALL
    SELECT e.from_layer + 1, e.to_node
    FROM p
    JOIN ladder_edges e ON e.from_layer = p.layer AND e.from_node = p.node
    WHERE p.layer < 16
)
SELECT COUNT(*) AS paths_16_layers FROM p WHERE layer = 16;

WITH RECURSIVE p(layer, node) AS (
    SELECT 1, 0
    UNION ALL
    SELECT e.from_layer + 1, e.to_node
    FROM p
    JOIN ladder_edges e ON e.from_layer = p.layer AND e.from_node = p.node
    WHERE p.layer < 20
)
SELECT COUNT(*) AS paths_20_layers FROM p WHERE layer = 20;
