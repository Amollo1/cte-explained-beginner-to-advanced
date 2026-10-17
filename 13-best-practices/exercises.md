# Module 13 Exercises

> **Needs the `ltree` extension for 13-04** (included with standard PostgreSQL installs). All data changes in 13-03 and 13-04 run inside `BEGIN ... ROLLBACK`, so the practice data is left untouched.
>
> **13-02 measures what the planner chooses.** Its numbers are the same on PostgreSQL 14, 16, 17 and 18 with default settings. If you change planner settings (for example `SET enable_hashjoin = off` or `SET enable_indexscan = off`) the numbers will legitimately change: that is the point of the exercise, not a mistake.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 13-01 | **Refactor** the nested customer-value report into named, commented CTEs. (A) Write the CTE version. (B) **Prove** it equals the nested version (`EXCEPT` both ways) and count how often each version scans `order_items`. | `orders`, `order_items`, `products`, `customers` | A: 26 rows (Dennis Okeke first, `33505.35`). B: `26, 26, 0`, then scans `4, 1` | [`13-01.sql`](13-01.sql) |
| 13-02 | **Index a recursive query.** Generate a 111,111-person org chart. Traverse (1) the whole organisation and (2) one team of 11, first with no index on `manager_id`, then with one. Report from the plan how many **whole-table scans** and how many **index lookups** each traversal made. | generated `big_org` | `6, 0` and `2, 0` without the index; `0, 111111` and `0, 11` with it | [`13-02.sql`](13-02.sql) |
| 13-03 | **Fix three anti-patterns, with evidence.** (A) A single-use wrapper CTE. (B) `SELECT *` in a CTE when a column is added. (C) A recursion with no stop condition. | `orders`, `departments`, `routes` | A: `0, f, f, 1, 1`. B: `ok, 42601, ok`. C: `t, 12` | [`13-03.sql`](13-03.sql) |
| 13-04 | **Compare four hierarchy models.** Build the category tree as an adjacency list, a materialized path, a closure table and an `ltree`. (A) Read the Electronics subtree in each. (B) Move the Phones subtree under Office and count the rows each model changes. (C) Check every model is still correct. (D) Count stored rows. Then write a short recommendation. | `categories` | A: `7` rows, `0` differences each. B: `1, 2, 4, 2`. C: all `true`. D: `12, 12, 27, 12` | [`13-04.sql`](13-04.sql) |

## Hints

<details>
<summary>13-01</summary>

Three steps, each with a stated grain: `order_totals` (one row per completed order), `customer_totals` (one row per customer, `COUNT(*)` for the orders so no `DISTINCT` is needed), and a step that adds country-level **window functions**: `SUM(revenue) OVER (PARTITION BY country)`, `RANK() OVER (PARTITION BY country ORDER BY revenue DESC)` and `AVG(revenue) OVER (PARTITION BY country)`. For the proof, run both queries through a helper that returns their rows, compare with `EXCEPT` both ways, and count scan nodes on `order_items` in each plan (the solution file shows the helpers).
</details>

<details>
<summary>13-02</summary>

Build the table with `generate_series(1, 111111)` and a manager of `(g - 2) / 10 + 1` for everyone except the root. Add the primary key and run `ANALYZE`. Read the plan with `EXPLAIN (ANALYZE, COSTS OFF)`: with no index look for `Seq Scan on big_org e ... loops=N` (N = number of rounds), with an index look for `Index Scan using idx_big_org_manager ... loops=N` (N = number of people expanded). The solution turns those `loops` values into numbers so the result does not depend on timing.
</details>

<details>
<summary>13-03</summary>

(A) Run the wrapper version and the direct version, compare results with `EXCEPT`, and check the plan text for `CTE Scan`. (B) Inside `BEGIN`, run the `SELECT *` query, `ALTER TABLE departments ADD COLUMN budget numeric`, run it again, and `ROLLBACK`; use an error-catching helper and return `LEFT(result, 5)` to get the error code. (C) Use a 300 ms `statement_timeout` for the unguarded recursion; the fix is `WHERE NOT (r.destination = ANY (w.path))`.
</details>

<details>
<summary>13-04</summary>

Materialized path: carry `path || id || '/'` down a recursive CTE. Closure table: anchor on every node paired with itself at depth 0, extend one level at a time. `ltree`: `CREATE EXTENSION ltree`, and turn `'1/5/6/'` into `'1.5.6'::ltree`. Reads: `path LIKE '1/%'`, `ancestor_id = 1`, `path <@ '1'::ltree`. For the move, count rows with `UPDATE ... RETURNING` / `DELETE ... RETURNING` in CTEs. For the `ltree` move, the moved node has nothing left to append, so handle it with a `CASE` on `nlevel(path)`.
</details>

## Written task for 13-04: your recommendation

In 4 to 6 sentences, say which model you would choose for **(a)** a 12-category product catalogue that changes monthly, and **(b)** a 5-million-row parts hierarchy queried thousands of times per hour and rarely edited. Use the evidence from Parts A to D.

<details>
<summary>Model answer</summary>

**(a)** Adjacency list with recursive CTEs: the tree is tiny, edits are cheap (one row), and there is nothing to keep in sync. **(b)** A closure table or `ltree`: the workload is read-heavy and rarely edited, so paying more on writes (rewriting a subtree's paths or links) buys fast indexed subtree reads. Whichever is chosen, add an audit query so the redundant data cannot drift from the parent pointers, and measure on realistic data before committing. The evidence: all four models read the same 7 rows, a move costs 1 row in the adjacency list but 2 to 4 elsewhere (growing with subtree size), and the closure table stores 27 rows for 12 nodes.
</details>

## Stretch goals

1. **Scale it up.** Change `111111` to `1111111` (7 levels) in 13-02 and predict, before running, whether the whole-organisation speed-up grows or shrinks, and by how much for one team. Then measure (use `EXPLAIN ANALYZE` timings, repeated a few times) and explain what you see.
2. **Which index does the where-used query need?** In Module 11 the BOM primary key is `(assembly_id, component_id)`. Explain why that index serves the downward explosion but not the where-used query, and which index you would add. (Answer: an index on `component_id`, since the primary key's leading column is `assembly_id`.)
3. **Audit a stored path.** Inside a transaction, corrupt one row of the materialized path (for example set Smartphones to `8/6/`), then write a query that finds every row whose path is not "the parent's path plus its own id". (Answer: exactly one row, Smartphones.) Finish with `ROLLBACK;`.
4. **Compare timings, not just counts.** Run `EXPLAIN (ANALYZE, BUFFERS)` on the one-team traversal with and without the index, and compare the **buffers** each node touched. Why are buffers steadier than milliseconds?
5. **Refactor your own query.** Take a query you wrote earlier in this course and apply the 13.9 checklist. Write down each item you had to change.
