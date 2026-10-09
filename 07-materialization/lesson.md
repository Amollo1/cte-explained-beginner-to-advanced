# Module 7: Materialization & the Optimizer

**Level:** Advanced  |  **Time:** about 2 hours  |  **Files:** [`examples.sql`](examples.sql) · [`exercises.md`](exercises.md)

## Learning objectives

By the end of this module you can:

- state what PostgreSQL does with a CTE by default, and why,
- use `MATERIALIZED` and `NOT MATERIALIZED` (PostgreSQL 12 and later),
- read an `EXPLAIN ANALYZE` plan well enough to see *predicate pushdown* and *duplicate work*,
- explain why a hint can make a query thousands of times faster or twice as slow, depending on the situation,
- decide whether to override the default, and justify it with measurements.

This module is different from the earlier ones: instead of changing **what** a query returns, you control **how** it runs. The result is identical either way.

---

## 7.1 Where we left off

You already know two facts:

- Module 1: a CTE referenced **once** is *inlined*: treated like a subquery.
- Module 2: a CTE referenced **twice or more** is computed **once** and stored.

Those are the **defaults**. This module shows how to override them, and, more importantly, when you should not.

## 7.2 Syntax and history

```sql
WITH orders_2025 AS MATERIALIZED     (SELECT ... ) SELECT ...;   -- compute once, store the result
WITH orders_2025 AS NOT MATERIALIZED (SELECT ... ) SELECT ...;   -- merge into the outer query
WITH orders_2025 AS                  (SELECT ... ) SELECT ...;   -- let PostgreSQL decide (the default)
```

Before PostgreSQL 12 there was no choice: every CTE was always stored first, which made it an **optimization fence**, a wall the planner could not see through. Many "CTEs are slow" stories date from that era. In version 12 and later the planner can see through simple CTEs, and the two keywords above let you take control.

## 7.3 What PostgreSQL does by default

| The CTE... | Default behaviour |
|---|---|
| is non-recursive, has no side effects, and is referenced **once** | **inlined** (no `CTE Scan` in the plan) |
| is referenced **more than once** | **materialized**: computed once, read by every reference |
| contains a **volatile** function such as `random()` | never inlined |
| is **recursive** or **data-modifying** (`INSERT`/`UPDATE`/`DELETE`) | never inlined (Modules 8 and 12) |

`MATERIALIZED` forces the stored behaviour. `NOT MATERIALIZED` asks for inlining, but only where inlining is possible (it cannot override the last two rows).

## 7.4 Reading the evidence

Never decide by intuition. Look at the plan.

| Command | What it does |
|---|---|
| `EXPLAIN query` | shows the plan **without running** the query (estimates only) |
| `EXPLAIN ANALYZE query` | **runs** the query and shows what really happened |
| `EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF) query` | the same, minus the noisy numbers, leaving stable counts |

Words you will see:

| In the plan | Meaning |
|---|---|
| `CTE Scan on x` | reading the stored result of CTE `x` (so it **was materialized**) |
| `CTE x` | where that stored result is built |
| `Seq Scan` / `Index Scan` | reading a whole table, or looking rows up through an index |
| `actual rows=N` | how many rows that step really produced |
| `Rows Removed by Filter: N` | rows read and then thrown away |
| `loops=N` | how many times the step ran |

> **Warning:** `EXPLAIN ANALYZE` really executes the query. That is harmless for `SELECT`, but for `INSERT`/`UPDATE`/`DELETE` wrap it in `BEGIN; ... ROLLBACK;`.

## 7.5 Predicate pushdown

A *predicate* is a filter condition. **Pushdown** means the planner applies it as early as possible, ideally inside the table scan. Question: which orders were placed on 12 March 2025? (There are 3.)

**Forced `MATERIALIZED`:**

```sql
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF, SUMMARY OFF)
WITH o AS MATERIALIZED (SELECT order_id, customer_id, order_date FROM orders)
SELECT * FROM o WHERE order_date = DATE '2025-03-12';
```

```
 CTE Scan on o (actual rows=3 loops=1)
   Filter: (order_date = '2025-03-12'::date)
   Rows Removed by Filter: 117
   CTE o
     ->  Seq Scan on orders (actual rows=120 loops=1)
```

**`NOT MATERIALIZED`:**

```
 Seq Scan on orders (actual rows=3 loops=1)
   Filter: (order_date = '2025-03-12'::date)
   Rows Removed by Filter: 117
```

Read the numbers. With `MATERIALIZED`, the scan on `orders` produced **120 rows**, all stored, and the filter then discarded 117. With inlining, the filter ran inside the scan, which produced **3**. Same answer, very different work.

### The same facts as stable numbers

Plans are text and timings vary, so the practice files in this module convert a plan into numbers using three small helpers (`plan_of`, `scans_of`, `rows_from`, defined at the top of each solution file). Run on this example:

```
 rows_scanned_materialized | rows_scanned_not_materialized
---------------------------+-------------------------------
                       120 |                             3
```

These counts are the same on every machine, which is what lets this repo test them automatically.

## 7.6 Duplicate work

Question: *which months earned more than the average month?* The monthly revenue CTE is used twice: for the rows, and inside `AVG(...)`.

```sql
WITH monthly AS MATERIALIZED (            -- or NOT MATERIALIZED
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
)
SELECT month, revenue FROM monthly WHERE revenue > (SELECT AVG(revenue) FROM monthly);
```

Trimmed plan, `MATERIALIZED`:

```
 CTE Scan on monthly (actual rows=7 loops=1)
   Filter: (revenue > $2)
   CTE monthly
     ->  HashAggregate (actual rows=18 loops=1)
           ->  ... Seq Scan on order_items i (actual rows=286 loops=1) ...
   InitPlan 2 (returns $2)
     ->  Aggregate
           ->  CTE Scan on monthly monthly_1        <-- reuses the stored result
```

Trimmed plan, `NOT MATERIALIZED`:

```
 HashAggregate (actual rows=7 loops=1)
   Filter: (sum(...) > $1)
   InitPlan 1 (returns $1)
     ->  Aggregate
           ->  HashAggregate
                 ->  ... Seq Scan on order_items i_1 (actual rows=286 loops=1) ...   <-- computed AGAIN
   ->  ... Seq Scan on order_items i (actual rows=286 loops=1) ...
```

Counting scans of `order_items`:

```
 order_items_scans_materialized | order_items_scans_not_materialized
--------------------------------+------------------------------------
                              1 |                                  2
```

`NOT MATERIALIZED` pasted the whole join-and-aggregate into **both** places, so the work happened twice. On 286 rows that is nothing; on millions it doubles the cost. The answer (7 months) is identical either way.

## 7.7 Volatile functions

A function is **volatile** if it can return a different value every time, like `random()`. PostgreSQL will not inline a CTE containing one, because inlining would change how often the function is called. Test it: ask for the same `random()` value twice from a CTE, 2000 times over.

| Variant | Times both references agreed (out of 2000) |
|---|---|
| CTE, default | 2000 |
| CTE with `NOT MATERIALIZED` | **2000** (the hint did **not** override it) |
| Two separate subqueries `(SELECT random()) = (SELECT random())` | 0 |

So a CTE gives you a **single snapshot** of a volatile value, shared by every reference, while subqueries call the function again each time. Writing `MATERIALIZED` here is redundant, but it **documents your intent** for the next reader.

## 7.8 At scale, and why there is no universal rule

On 120 rows nothing is measurable. To see real effects, the examples build a **500,000-row** temporary table (`big_orders`, with an index on `order_id`) and run three scenarios, each both ways. The row counts below are exact; the timings come from one run on my test machine and **will differ on yours**:

| # | Scenario | Default / better choice | Forced the other way |
|---|---|---|---|
| A | CTE used **once**, looking up one order by its indexed id | default (inlined): index scan, **about 0.03 ms**, 1 row read | `MATERIALIZED`: scans all **500,000** rows first, **about 100 ms** |
| B | CTE used **twice**, each time looking up one indexed order | default (materialized): scans all 500,000 rows, **about 120 ms** | `NOT MATERIALIZED`: **two index lookups, about 0.05 ms** |
| C | **Expensive aggregate** (sum over 500,000 rows) used **twice** | `MATERIALIZED`: computed once, **about 130 ms** | `NOT MATERIALIZED`: computed twice, **about 250 ms** |

Look at the pattern, because it is the heart of this module:

- In **A**, the default beat the hint, because inlining let the index do its job. Forcing `MATERIALIZED` made it thousands of times slower.
- In **B**, the **default was the problem** and `NOT MATERIALIZED` fixed it: each use needed only one row, but materializing built all 500,000 first.
- In **C**, `MATERIALIZED` was right: both uses needed the whole result, so computing it twice just doubled the work.

Same two keywords, opposite verdicts. What decides it is **how much of the CTE each reference needs**, and whether the work is expensive to repeat.

## 7.9 Decision guide

| Situation | Choice | Why |
|---|---|---|
| CTE used **once** | leave the default | inlining lets the planner use indexes and filters freely |
| Used several times, and **each use needs most of the rows**, or the computation is **expensive** | default, or `MATERIALIZED` | compute it once |
| Used several times, but **each use picks out a few rows** through an index | `NOT MATERIALIZED` | cheap index lookups instead of building the full result |
| You want **one snapshot** of a volatile function (`random()`, `clock_timestamp()`) | `MATERIALIZED` (already enforced; say so) | every reference sees the same value |
| The planner makes a **measured** bad choice | try the opposite hint | the "fence" can stop a plan that goes wrong |

**Do not add hints out of habit.** The default is right most of the time. A hint is a promise about your data that becomes false when the data grows, so every hint you keep should have a comment saying what you measured.

## 7.10 Method: measure, do not guess

1. **Check the plan** with `EXPLAIN ANALYZE` and note `actual rows` and `loops`.
2. **Compare both versions.** Run the query with each hint and compare the row counts and scan counts. Timings need several runs, because the first run is slower while the cache warms up.
3. **Test at a realistic size.** A 120-row table hides everything. Generate data with `generate_series` if you have to.
4. **Refresh statistics** with `ANALYZE` before judging a plan, since the planner chooses from table statistics.
5. **Keep the hint only if it wins**, and write the evidence in a comment.
6. **Re-check after upgrades or big data changes.** A plan that was best last year may not be today. The planner changes between PostgreSQL versions.

Beware of these traps: `EXPLAIN` without `ANALYZE` shows only estimates; timings include noise; `EXPLAIN ANALYZE` itself adds overhead; and an index that matters at 500,000 rows may be ignored at 120.

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Adding `MATERIALIZED` "to be safe" on a CTE used once | A selective filter or index lookup becomes a full scan (A above) | Leave the default; measure first |
| Assuming "CTEs are always slow" (old advice from before v12) | Needless rewrites into subqueries | Check the plan: a single-use CTE is inlined |
| Assuming `NOT MATERIALIZED` is always faster | An expensive CTE is computed twice (C above) | Use it only when each reference needs a few rows |
| Expecting `NOT MATERIALIZED` to affect a CTE with `random()` | No change; the hint is ignored | Volatile CTEs are always computed once |
| Judging a plan on a tiny table | Index and pushdown benefits invisible | Test with realistic volumes |
| Using `EXPLAIN` instead of `EXPLAIN ANALYZE` | Estimates mistaken for facts | `ANALYZE` shows actual rows |
| Running `EXPLAIN ANALYZE` on `DELETE` or `UPDATE` unprotected | The change really happens | Wrap in `BEGIN ... ROLLBACK` |
| Leaving an uncommented hint in production code | Nobody knows if it is still needed | Comment what was measured and when |

## Key takeaways

- Default: a CTE used **once** is **inlined**; used **more than once** it is **materialized**.
- `MATERIALIZED` and `NOT MATERIALIZED` change **how** a query runs, never **what** it returns.
- **Pushdown:** inlining lets a filter reach the table (120 rows scanned became 3).
- **Duplicate work:** `NOT MATERIALIZED` repeats the CTE at each reference (1 scan became 2).
- **Volatile** functions are never inlined, so a CTE gives every reference the same value.
- The best choice depends on **how much of the CTE each reference needs**. There is no universal rule, so **measure** and document.

## Checkpoint

<details>
<summary>1. A CTE is used once, with a selective filter on an indexed column. Should you add <code>MATERIALIZED</code>?</summary>

No. By default a CTE used once is inlined, so the filter reaches the table and the index is used. Forcing `MATERIALIZED` would read the whole table first and filter afterwards, which is dramatically slower.
</details>

<details>
<summary>2. A CTE used twice computes an expensive aggregate over a huge table. Which hint, and why?</summary>

`MATERIALIZED` (also the default for two references). It computes the aggregate once and both references read the stored result. `NOT MATERIALIZED` would repeat the whole computation at each reference.
</details>

<details>
<summary>3. A CTE used twice is slow, and each reference needs only one row looked up by primary key. What is the likely fix?</summary>

`NOT MATERIALIZED`. The default materializes the entire result for both references, while inlining turns each reference into a cheap index lookup. Confirm with `EXPLAIN ANALYZE` that the full scan disappears.
</details>

<details>
<summary>4. You write <code>AS NOT MATERIALIZED</code> on a CTE that calls <code>random()</code>. What happens?</summary>

Nothing changes. A CTE with a volatile function is never inlined, so it is computed once and every reference sees the same value.
</details>

**Next:** do the [exercises](exercises.md), then continue to [Module 8: Recursive CTE Fundamentals](../08-recursive-basics/lesson.md).
