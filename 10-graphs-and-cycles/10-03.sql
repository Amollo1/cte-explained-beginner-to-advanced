-- Exercise 10-03: the same task with the CYCLE clause (PostgreSQL 14 or newer).
-- CYCLE city SET is_cycle USING path: PostgreSQL remembers the cities visited. A row that would revisit one
-- is flagged is_cycle = true and is not expanded any further.
-- Part A: the routes to Kigali. Filter out flagged rows with NOT is_cycle. Expected: 2 rows.
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

-- Part B: the flagged rows are exactly the places where a walk came back to a visited city. Expected: 4 rows.
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

-- Part C: CYCLE and the manual path check must give the same routes (differences must be 0).
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

-- Part D: why NOT is_cycle matters. Kigali is a dead end (no road leaves it), so no flagged row ever arrives
-- there and the filter changes nothing for Kigali. A city ON a loop is different: Nairobi is reached once
-- as the start, plus once for every loop that closes on it. Expected: 5, 1, 2, 2.
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
SELECT COUNT(*) FILTER (WHERE city = 'Nairobi')                      AS nairobi_rows_without_filter,
       COUNT(*) FILTER (WHERE city = 'Nairobi' AND NOT is_cycle)     AS nairobi_rows_with_filter,
       COUNT(*) FILTER (WHERE city = 'Kigali')                       AS kigali_rows_without_filter,
       COUNT(*) FILTER (WHERE city = 'Kigali'  AND NOT is_cycle)     AS kigali_rows_with_filter
FROM walk;
