-- Capstone 4: ROUTE PLANNER (graph search with cycle control, benchmarks and an honest statement of its limits).
--
-- The business need: given the road network, list the possible routes between two cities, within a distance budget,
-- and know what is NOT possible.
--   routing.plan_route(from, to, max_km)   all simple routes, shortest first (a path check stops cycles)
--   routing.v_shortest                      shortest distance for every ordered pair of cities
-- Techniques: recursive path enumeration with a path check and a distance budget (Module 10), shortest path by
-- enumeration, and the exponential growth that limits it (Module 10).
-- LIMITS (read before using this on a big graph): the function enumerates EVERY simple route, so its cost grows
-- exponentially with the size of the graph. It is right for small networks like this one. For large networks use a
-- shortest-path algorithm (Dijkstra) in application code or the pgRouting extension.
-- HOW THIS FILE IS USED
--   In this course repository the file runs inside BEGIN ... ROLLBACK, so the practice data is never changed
--   and the automated tests can run it again and again.
--   To KEEP the objects in YOUR OWN project repository, copy the file, delete the BEGIN; and ROLLBACK; lines
--   (or replace ROLLBACK; with COMMIT;) and run it once against your own database.

BEGIN;

CREATE SCHEMA routing;

CREATE FUNCTION routing.plan_route(p_from text, p_to text, p_max_km int DEFAULT NULL)
RETURNS TABLE(route text, total_km int, hops int)
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE walk(city, total_km, hops, path) AS (
        SELECT p_from, 0, 0, ARRAY[p_from]                                   -- anchor: the start NODE, in the path
        UNION ALL
        SELECT r.destination, w.total_km + r.distance_km, w.hops + 1, w.path || r.destination
        FROM walk w
        JOIN routes r ON r.origin = w.city
        WHERE NOT (r.destination = ANY (w.path))                             -- never visit a city twice (cycle control)
          AND (p_max_km IS NULL OR w.total_km + r.distance_km <= p_max_km)   -- optional distance budget (pruning)
    )
    SELECT array_to_string(w.path, ' > '), w.total_km, w.hops
    FROM walk w
    WHERE w.city = p_to AND w.hops > 0
    ORDER BY w.total_km, w.hops
$$;

CREATE VIEW routing.v_shortest AS
WITH cities AS (
    SELECT origin AS city FROM routes
    UNION
    SELECT destination FROM routes
)
SELECT a.city AS origin, b.city AS destination,
       (SELECT MIN(p.total_km) FROM routing.plan_route(a.city, b.city) p) AS shortest_km
FROM cities a
CROSS JOIN cities b
WHERE a.city <> b.city;

-- Part A: routes from Nairobi to Kigali, shortest first. Expected: 1220 and 1230 km.
SELECT * FROM routing.plan_route('Nairobi', 'Kigali');

-- Part B: Nairobi to Dar es Salaam within a 1000 km budget (one route survives), and an impossible trip.
SELECT * FROM routing.plan_route('Nairobi', 'Dar es Salaam', 1000);
SELECT COUNT(*) AS routes_from_kigali_to_nairobi FROM routing.plan_route('Kigali', 'Nairobi');   -- 0: no road leaves Kigali

-- Part C: the whole network. 72 ordered pairs; Kigali has no outgoing road, so 8 pairs are unreachable.
SELECT COUNT(*)                AS ordered_pairs,
       COUNT(shortest_km)      AS reachable_pairs,
       MAX(shortest_km)        AS longest_shortest_km
FROM routing.v_shortest;
SELECT origin, destination, shortest_km
FROM routing.v_shortest
WHERE shortest_km = (SELECT MAX(shortest_km) FROM routing.v_shortest);

-- Part D: BENCHMARK. Path enumeration grows exponentially. A "ladder" graph (2 nodes per layer, every node linked
-- to both nodes of the next layer) has 2^(layers-1) paths. Counts are exact; timings would differ on every machine.
CREATE TEMP TABLE ladder_edges AS
SELECT l AS from_layer, a AS from_node, b AS to_node
FROM generate_series(1, 24) AS l, generate_series(0, 1) AS a, generate_series(0, 1) AS b;

CREATE TEMP TABLE ladder_counts AS
SELECT layers,
       (WITH RECURSIVE p(layer, node) AS (
            SELECT 1, 0
            UNION ALL
            SELECT e.from_layer + 1, e.to_node
            FROM p JOIN ladder_edges e ON e.from_layer = p.layer AND e.from_node = p.node
            WHERE p.layer < layers
        ) SELECT COUNT(*) FROM p WHERE layer = layers) AS paths
FROM (VALUES (12), (14), (16), (18)) AS t(layers);
SELECT layers, paths FROM ladder_counts ORDER BY layers;

-- Part E: SELF-CHECKS. Every row must say passed = true.
WITH checks(ord, check_name, expected, actual) AS (
    VALUES
    (1, 'Nairobi to Kigali has 2 simple routes',
        '2',
        (SELECT COUNT(*) FROM routing.plan_route('Nairobi', 'Kigali'))::text),
    (2, 'the shortest Nairobi to Kigali route is 1220 km',
        '1220',
        (SELECT MIN(total_km) FROM routing.plan_route('Nairobi', 'Kigali'))::text),
    (3, 'a 1000 km budget leaves one route to Dar es Salaam',
        '1',
        (SELECT COUNT(*) FROM routing.plan_route('Nairobi', 'Dar es Salaam', 1000))::text),
    (4, 'no road leaves Kigali, so nothing is reachable from it',
        '0',
        (SELECT COUNT(shortest_km) FROM routing.v_shortest WHERE origin = 'Kigali')::text),
    (5, 'ordered city pairs (9 cities)',
        '72',
        (SELECT COUNT(*) FROM routing.v_shortest)::text),
    (6, 'reachable ordered pairs',
        '64',
        (SELECT COUNT(shortest_km) FROM routing.v_shortest)::text),
    (7, 'the longest shortest route is 2730 km',
        '2730',
        (SELECT MAX(shortest_km) FROM routing.v_shortest)::text),
    (8, 'no route visits a city twice',
        '0',
        (SELECT COUNT(*)
         FROM routing.v_shortest s
         CROSS JOIN LATERAL routing.plan_route(s.origin, s.destination) r
         WHERE cardinality(string_to_array(r.route, ' > ')) <> (SELECT COUNT(DISTINCT x) FROM unnest(string_to_array(r.route, ' > ')) x))::text),
    (9, 'each extra 2 layers multiplies the path count by 4',
        '4',
        ((SELECT paths FROM ladder_counts WHERE layers = 18) / (SELECT paths FROM ladder_counts WHERE layers = 16))::text)
)
SELECT check_name, expected, actual, (expected = actual) AS passed
FROM checks
ORDER BY ord;

ROLLBACK;
