# Module 10 Exercises

> Requires **PostgreSQL 14 or newer** for 10-03 and 10-04 (`CYCLE` and `SEARCH`). Set a `statement_timeout` before running any recursion on `routes` that has no guard.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 10-01 | **No protection.** (A) Enumerate walks from Nairobi with no cycle guard under a `statement_timeout` and show the query is cancelled. (B) Use only a depth limit and count the "routes" to Kigali for limits 4, 8, 12 and 16. (C) Count the genuine routes with a path check. | `routes` | A: `t`. B: walks to Kigali `2, 10, 42, 202` (all walks `22, 128, 644, 3180`). C: `2` | [`10-01.sql`](10-01.sql) |
| 10-02 | **Manual cycle guard.** (A) List every route from Nairobi to Kigali with distance and hops, using a path array and `NOT (destination = ANY (path))`. (B) For every other city reachable from Nairobi, count the simple paths and give the shortest and longest distance. | `routes` | A: 2 rows (`1220` and `1230`). B: 8 rows; Kampala `2, 710, 720`; Dar es Salaam `2, 900, 1010` | [`10-02.sql`](10-02.sql) |
| 10-03 | **The `CYCLE` clause.** (A) Routes to Kigali with `CYCLE`, filtering `NOT is_cycle`. (B) List the flagged rows (the places where a walk returned to a visited city). (C) Prove `CYCLE` and the manual check give the same routes. (D) Show when `NOT is_cycle` matters: count the rows that arrive in Nairobi and in Kigali, with and without the filter. | `routes` | A: 2 rows. B: 4 rows (`1780`, `1890`, `1360`, `1370` km). C: `2, 2, 0`. D: `5, 1, 2, 2` | [`10-03.sql`](10-03.sql) |
| 10-04 | **The `SEARCH` clause.** (A) List all simple paths from Nairobi in **breadth-first** order. (B) The same in **depth-first** order. (C) Prove breadth-first equals `ORDER BY hops, path_ids` and depth-first equals `ORDER BY path_ids`. | `routes` | A and B: 12 rows each; A starts Nairobi, Nakuru, Mombasa, Arusha; B step 5 is `... > Kampala > Kigali`. C: `t, t` | [`10-04.sql`](10-04.sql) |
| 10-05 | **Shortest path.** (A) The shortest route from Nairobi to Kigali. (B) The shortest distance to every other city. (C) How many paths did the query have to build to answer? | `routes` | A: `1220` km via Eldoret. B: 8 cities, from Nakuru `160` to Kigali `1220`. C: `12, 9, 12` | [`10-05.sql`](10-05.sql) |

## Hints

<details>
<summary>10-01</summary>

Anchor on the **start city** (`SELECT 'Nairobi'::text, 0, 0`), not on an edge. For Part A, wrap the query in a small function that catches `query_canceled` (note that `WHEN OTHERS` does **not** catch it), and `SET statement_timeout = '300ms'` first. For Part B add `WHERE w.hops < 16` and count with `COUNT(*) FILTER`-style subqueries against `generate_series(4, 16, 4)`.
</details>

<details>
<summary>10-02</summary>

Carry `path` as `text[]`: anchor `ARRAY['Nairobi'::text]`, recursive step `w.path || r.destination`, guard `WHERE NOT (r.destination = ANY (w.path))`. `array_to_string(path, ' > ')` makes the route readable. Part B: `GROUP BY city` over the same CTE, leaving out Nairobi itself.
</details>

<details>
<summary>10-03</summary>

Keep a text `route` column yourself. Add the clause **after** the closing parenthesis of the CTE: `CYCLE city SET is_cycle USING path`. Filter with `WHERE city = 'Kigali' AND NOT is_cycle` for the routes, and `WHERE is_cycle` for the loops. For Part D, use `COUNT(*) FILTER (WHERE city = '...')` with and without `AND NOT is_cycle`; ask yourself why Kigali is unaffected. For Part C, define both versions in one `WITH RECURSIVE` list (the `CYCLE` clause attaches to its own CTE) and compare with `EXCEPT` in both directions. Use a different name for the `USING` column in the second CTE.
</details>

<details>
<summary>10-04</summary>

Carry `via` (the `route_id` of the road used to arrive) and `path_ids` (an integer array of those ids, starting with `ARRAY[0]`). Use `SEARCH BREADTH FIRST BY path_ids SET ordercol` and `SEARCH DEPTH FIRST BY via SET ordercol`, and always `ORDER BY ordercol` in the outer query. Why would `BREADTH FIRST BY via` be a mistake? Look at the last two rows.
</details>

<details>
<summary>10-05</summary>

Reuse the path-check CTE. Part A: `ORDER BY total_km LIMIT 1`. Part B: `DISTINCT ON (city)` with `ORDER BY city, total_km` inside a subquery, then sort that subquery's result by `total_km`. Part C: `COUNT(*)` of the CTE, `COUNT(DISTINCT city)`, and `COUNT(*)` of `routes`.
</details>

## Stretch goals

1. **A different start.** Change the start city to Dar es Salaam and rerun the reachability query from the lesson. How many cities can you reach (answer: `9` again, because every city can reach every other)? Which loop closes first?
2. **Add a road.** Inside a transaction, add a return road `INSERT INTO routes VALUES (13, 'Kigali', 'Kampala', 510);` and rerun the `CYCLE` query. The number of flagged rows goes from `4` to `6`, while the number of simple paths stays `12`. Explain why, then `ROLLBACK;`.
3. **Prune with a budget.** Combine the path check with a distance limit of 1000 km: `WHERE NOT (r.destination = ANY (w.path)) AND w.total_km + r.distance_km <= 1000`. You should get `9` routes covering `8` cities. Which city on the 1220 km route disappears, and which route to Dar es Salaam survives?
4. **Feel the exponential.** Build the ladder graph from `examples.sql` (Example 15) and run it with 16, 18, 20 and 22 layers. Record the time for each. By what factor does the time grow per extra layer, and what does that tell you about enumerating paths on a real road network?
