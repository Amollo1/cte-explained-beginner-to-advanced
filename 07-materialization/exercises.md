# Module 7 Exercises

These exercises are about **reading plans**. Do each one by hand first: run `EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)` on each version and read the output. The solution files then turn the same plans into **stable numbers** (using the `plan_of`, `scans_of` and `rows_from` helpers at the top of each file) so they can be tested automatically.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 07-01 | **Referenced twice.** Write the "months above the average month" query with `MATERIALIZED` and with `NOT MATERIALIZED`. Count how many times each plan scans `order_items`, and confirm both return the same rows. | `orders`, `order_items`, `products` | Scans: `1` vs `2`. `CTE Scan` present: `t` vs `f`. 7 result rows, `0` differences | [`07-01.sql`](07-01.sql) |
| 07-02 | **Predicate pushdown.** Filter orders on `order_date = '2025-03-12'` through a CTE. Report how many rows the scan on `orders` produced with `MATERIALIZED`, `NOT MATERIALIZED` and no hint. | `orders` | `120`, `3`, `3`; the result has `3` rows | [`07-02.sql`](07-02.sql) |
| 07-03 | **Choosing for yourself.** Show three situations: (A) a volatile `random()` CTE, (B) an expensive aggregate used twice, (C) two selective lookups through a CTE (the case where `NOT MATERIALIZED` wins). | `orders`, `order_items`, `products` | A: `t, t, t`. B: scans `1` vs `2`. C: rows read `120` vs `2` | [`07-03.sql`](07-03.sql) |

## Hints

<details>
<summary>07-01</summary>

The CTE is used twice: once in the `FROM`, once inside `(SELECT AVG(revenue) FROM monthly)`. In the `NOT MATERIALIZED` plan, look for `Seq Scan on order_items` appearing in **two** places (one is under an `InitPlan`). In the `MATERIALIZED` plan it appears once, under `CTE monthly`, and `CTE Scan on monthly` appears twice.
</details>

<details>
<summary>07-02</summary>

Compare the line `Seq Scan on orders (actual rows=...)` in each plan. For `MATERIALIZED` the scan feeds the whole CTE; for `NOT MATERIALIZED` the `Filter:` line sits **on the scan itself**. The no-hint version should match `NOT MATERIALIZED`, because the CTE is used only once.
</details>

<details>
<summary>07-03</summary>

Part A: ask for `(SELECT x FROM r) = (SELECT x FROM r)` where `r` is `SELECT random() AS x`. Part B: wrap the CTE in two scalar subqueries, `MAX(revenue)` and `MIN(revenue)`. Part C: use two lookups by `order_id`; each should need one row, so ask how many rows the scan on `orders` produced.
</details>

## Stretch goals

1. **See it at scale.** Create the 500,000-row `big_orders` table from `examples.sql` (Part C) and run scenarios A, B and C. Record your own timings in a small table. Which scenario shows the biggest gap on your machine, and why?
2. **A hint that does nothing.** Take the "months above average" query and use the CTE only **once** (drop the `AVG` subquery). Compare the plan with no hint against `NOT MATERIALIZED`. Predict the difference first. (Answer: none; a single-use CTE is already inlined.)
3. **Add an index.** Inside a transaction, run `CREATE INDEX ON orders (order_date); ANALYZE orders;` and repeat 07-02, then `ROLLBACK;`. The counts stay `120` and `3`. Why does PostgreSQL still choose a sequential scan on a 120-row table, and what would change if the table had millions of rows? (Scenario A in the lesson gives the answer.)
