-- Exercise 10-01: enumerate routes WITHOUT cycle protection, and see why that goes wrong.
-- The routes graph has cycles (for example Nairobi > ... > Kampala > Nairobi).

CREATE OR REPLACE FUNCTION pg_temp.try_sql(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE q;
    RETURN 'ok';
EXCEPTION
    WHEN query_canceled THEN RETURN 'CANCELED: ' || SQLERRM;   -- OTHERS does not catch query_canceled
    WHEN OTHERS         THEN RETURN SQLSTATE || ': ' || SQLERRM;
END $$;

-- Part A: no protection at all. The query never ends, so a 300 ms timeout cancels it.
SET statement_timeout = '300ms';
SELECT pg_temp.try_sql($q$
    WITH RECURSIVE walk(city, total_km, hops) AS (
        SELECT 'Nairobi'::text, 0, 0
        UNION ALL
        SELECT r.destination, w.total_km + r.distance_km, w.hops + 1
        FROM walk w JOIN routes r ON r.origin = w.city
    ) SELECT COUNT(*) FROM walk WHERE city = 'Kigali' $q$) LIKE 'CANCELED:%' AS unprotected_search_cancelled;
RESET statement_timeout;

-- Part B: a depth guard alone. It ends the query, but every trip around a cycle counts as a new "route".
-- Only 2 genuine routes exist, yet the number of "routes" explodes as the allowed depth grows.
WITH RECURSIVE walk(city, total_km, hops) AS (
    SELECT 'Nairobi'::text, 0, 0
    UNION ALL
    SELECT r.destination, w.total_km + r.distance_km, w.hops + 1
    FROM walk w
    JOIN routes r ON r.origin = w.city
    WHERE w.hops < 16
)
SELECT g                                                                AS max_hops,
       (SELECT COUNT(*) FROM walk WHERE city = 'Kigali' AND hops <= g)  AS walks_to_kigali,
       (SELECT COUNT(*) FROM walk WHERE hops <= g)                      AS all_walks
FROM generate_series(4, 16, 4) AS g
ORDER BY g;

-- Part C: the path check finds exactly the genuine routes.
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
SELECT COUNT(*) AS real_routes_to_kigali
FROM walk
WHERE city = 'Kigali';
