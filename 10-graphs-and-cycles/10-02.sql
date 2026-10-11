-- Exercise 10-02: a manual cycle guard, using a path array and NOT (destination = ANY (path)).
-- Part A: every route from Nairobi to Kigali, with its distance. Expected: 2 rows.
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
ORDER BY total_km;

-- Part B: unlike a tree, a city can be reached in several ways. For every city reachable from Nairobi:
-- how many different routes lead there, and how long are the shortest and the longest?
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
