-- Exercise 10-05: the shortest route from Nairobi to Kigali, and the limits of this approach.
-- Method: enumerate every simple path, sort by distance, keep one. Fine for 9 cities and 12 roads.
-- Part A: the shortest route to Kigali.
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
SELECT array_to_string(path, ' > ') AS route,
       total_km,
       hops
FROM walk
WHERE city = 'Kigali'
ORDER BY total_km
LIMIT 1;

-- Part B: the shortest distance from Nairobi to every other city (DISTINCT ON keeps the best row per city).
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

-- Part C: the cost. To answer, the query had to build EVERY simple path, not just the best ones.
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
SELECT (SELECT COUNT(*) FROM walk)                  AS paths_enumerated,
       (SELECT COUNT(DISTINCT city) FROM walk)      AS cities_reached,
       (SELECT COUNT(*) FROM routes)                AS roads_in_graph;
