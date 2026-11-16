# Route planner: graph search in SQL, with its limits stated

> **This README is a model.** Rewrite it in your own words, and keep only the claims that are true of **your** project.

## The problem

Given a road network, list the possible routes between two cities (shortest first), optionally within a distance budget, and **know what is impossible**. The network has cycles, so a naive recursion never finishes.

## What this project demonstrates

- **Recursive path enumeration** with a **path check** for cycle control and an optional **distance budget** for pruning.
- A reusable SQL **function** and an all-pairs view.
- A **benchmark** that shows exponential growth, with exact counts instead of timings.
- Stating the **limits** of an approach and naming the right tool beyond them.

## Design

| Object | Purpose |
|---|---|
| `routing.plan_route(from, to, max_km)` | every **simple** route (no city twice), shortest first, with an optional budget |
| `routing.v_shortest` | the shortest distance for every ordered pair of cities |

**Decisions.** The recursion starts from the **start node** (not an edge), and puts it in the path array, so a return to it is caught. The path check (`NOT (destination = ANY (path))`) guarantees every row is a genuine simple route and that the recursion ends. The budget is added to the same `WHERE` and prunes branches early.

## How to run it

```bash
psql -d your_database -f 14-capstones/14-04.sql
```

To keep the `routing` schema, delete the `BEGIN;` and `ROLLBACK;` lines in your copy.

## Results

```
                     route                     | total_km | hops
-----------------------------------------------+----------+------
 Nairobi > Nakuru > Eldoret > Kampala > Kigali |     1220 |    4
 Nairobi > Nakuru > Kisumu > Kampala > Kigali  |     1230 |    4
```

The whole network: **72** ordered pairs of cities, **64 reachable** (no road leaves Kigali, so 8 pairs are impossible), and the longest shortest route is **2,730 km** (Arusha to Kigali).

## How it is tested

Nine self-checks, all `t`: the number of routes and the shortest distance for a known trip; the budget leaves exactly one route; nothing is reachable from Kigali; the pair counts; the longest shortest route; **no route visits a city twice** (checked over every route between every pair); and the benchmark growth factor.

## Limits (the most important section)

The function builds **every** simple route, so its cost grows **exponentially**. A "ladder" graph (2 nodes per layer, every node linked to both nodes of the next layer) shows it with exact path counts:

```
 layers |  paths
--------+--------
     12 |   2048
     14 |   8192
     16 |  32768
     18 | 131072
```

Every 2 extra layers multiplies the work by **4**. That is fine for 9 cities and 12 roads, and **wrong for a real road network**. A good shortest-path algorithm (Dijkstra) keeps only the best known distance per node; a recursive CTE cannot, because aggregates are not allowed in its recursive term. For large networks use a shortest-path algorithm in application code, or the **pgRouting** extension.

## What I would do next

- Compare against **pgRouting** on a larger generated graph, with timings.
- Add a `max_hops` parameter and a distance matrix pivoted by city.
- Handle **two-way roads** and **road closures** (a status column).

## Skills used

Graphs, cycles and the cost of enumeration ([Module 10](../../../10-graphs-and-cycles/lesson.md)), recursion ([8](../../../08-recursive-basics/lesson.md)), knowing a tool's limits ([13](../../../13-best-practices/lesson.md)). Reference solution: [`14-04.sql`](../../14-04.sql).
