# Module 13: Performance, Best Practices & Anti-Patterns

**Level:** Advanced  |  **Time:** about 3 hours  |  **Files:** [`examples.sql`](examples.sql) · [`exercises.md`](exercises.md)

> The hierarchy comparison in 13.8 uses PostgreSQL's **`ltree`** extension, which ships with standard PostgreSQL installs (the `contrib` modules, included in the official Docker images, the Windows installer and Debian/Ubuntu packages). It needs PostgreSQL 14 or newer for the rest of the course anyway.

## Learning objectives

By the end of this module you can:

- refactor a tangled nested query into named CTEs and **prove** the rewrite is equivalent,
- explain when an index on the join column of a recursive query matters a lot, and when it barely matters,
- recognise and fix the most common CTE anti-patterns,
- compare four ways to store a hierarchy using evidence (reads, writes, storage),
- apply a short review checklist to any CTE-based query.

---

## 13.1 The order of priorities

When you write or review SQL, ask three questions **in this order**:

1. **Is it correct?** (right grain, right joins, totals that reconcile)
2. **Is it clear?** (a stranger can read it top to bottom and say what each step is for)
3. **Is it fast enough?** (measured, not guessed)

Most "performance" problems in analytical SQL turn out to be correctness or clarity problems in disguise: a join that multiplies rows (Module 4), the same aggregation computed four times (13.2), a missing index on a join column (13.4). The tools of this course (grain comments, `EXCEPT` proofs, reconciliation, `EXPLAIN ANALYZE`) are how you answer all three questions with **evidence**.

Two rules run through everything that follows:

- **Never optimise without measuring.** A change that "should" help may do nothing, or make things worse (Module 7 showed `MATERIALIZED` running 4,000 times slower in one case and faster in another).
- **Never refactor without proving equivalence.** Rewrite, then compare old and new results in both directions.

## 13.2 Refactoring nested SQL into CTEs

Here is a realistic report request: *for every customer with completed orders, show orders, revenue, average order value, their share of their country's revenue, their rank within the country, and whether they beat the country's average.*

The nested version (shortened here; the full text is in `examples.sql`) writes the per-customer revenue aggregation **four times**: once for the main rows, and once inside each of three correlated subqueries (country total, rank, country average):

```sql
SELECT t.customer_id, t.customer_name, ...,
       ROUND(100 * t.revenue / (SELECT SUM(x.revenue)
                                FROM (SELECT o2.customer_id, SUM(...) AS revenue
                                      FROM orders o2 JOIN order_items i2 ON ... JOIN products p2 ON ...
                                      WHERE o2.status = 'completed' GROUP BY o2.customer_id) x
                                JOIN customers c2 ON ... WHERE c2.country = t.country), 1) AS pct_of_country,
       (SELECT COUNT(*) + 1 FROM (SELECT o3.customer_id, SUM(...) ... ) y JOIN customers c3 ON ...
        WHERE c3.country = t.country AND y.revenue > t.revenue)                              AS country_rank,
       CASE WHEN t.revenue > (SELECT AVG(z.revenue) FROM (SELECT o4.customer_id, SUM(...) ... ) z ...)
            THEN 'above' ELSE 'at or below' END                                              AS vs_country_avg
FROM (SELECT c.customer_id, ..., COUNT(DISTINCT o.order_id) AS orders, SUM(...) AS revenue
      FROM customers c JOIN orders o ON ... JOIN order_items i ON ... JOIN products p ON ...
      WHERE o.status = 'completed' GROUP BY ...) t
```

### The refactoring recipe

1. **State the grain and the question** of each piece of the answer.
2. **Find the repeated work** (here, "revenue per customer") and compute it **once**, in a CTE.
3. **Name every step** after what it contains, and write its grain in a comment.
4. **Replace correlated subqueries with window functions** where they express the same idea (a country total is `SUM() OVER (PARTITION BY country)`; a rank is `RANK()`).
5. **Remove band-aids.** `COUNT(DISTINCT order_id)` was there because of a join; once there is a one-row-per-order CTE, plain `COUNT(*)` is correct.
6. **Prove equivalence** (below), then **measure**.

The result:

```sql
WITH order_totals AS (                    -- grain: one row per completed order
    SELECT o.order_id, o.customer_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.order_id, o.customer_id
),
customer_totals AS (                    -- grain: one row per customer
    SELECT customer_id,
           COUNT(*)     AS orders,       -- one row per order, so COUNT(*) needs no DISTINCT
           SUM(revenue) AS revenue
    FROM order_totals
    GROUP BY customer_id
),
with_country AS (                       -- same grain, plus country-level windows
    SELECT c.customer_id, c.customer_name, c.country, c.segment, t.orders, t.revenue,
           SUM(t.revenue) OVER (PARTITION BY c.country)                          AS country_revenue,
           RANK()         OVER (PARTITION BY c.country ORDER BY t.revenue DESC)  AS country_rank,
           AVG(t.revenue) OVER (PARTITION BY c.country)                          AS country_avg
    FROM customer_totals t
    JOIN customers c ON c.customer_id = t.customer_id
)
SELECT customer_id, customer_name, country, segment, orders,
       ROUND(revenue, 2)                         AS revenue,
       ROUND(revenue / orders, 2)                AS avg_order_value,
       ROUND(100 * revenue / country_revenue, 1) AS pct_of_country,
       country_rank,
       CASE WHEN revenue > country_avg THEN 'above' ELSE 'at or below' END AS vs_country_avg
FROM with_country
ORDER BY revenue DESC, customer_id;
```

The first rows (26 in total):

```
 customer_id | customer_name  |    country    | segment | orders | revenue  | avg_order_value | pct_of_country | country_rank | vs_country_avg
-------------+----------------+---------------+---------+--------+----------+-----------------+----------------+--------------+----------------
           4 | Dennis Okeke   | Tanzania      | Retail  |     14 | 33505.35 |         2393.24 |           71.4 |            1 | above
           2 | Brian Ali      | Kenya         | Retail  |      8 | 20504.30 |         2563.04 |           30.5 |            1 | above
           1 | Achieng Omondi | Kenya         | SME     |      9 | 15520.75 |         1724.53 |           23.1 |            2 | above
           3 | Chloe Brown    | United States | Retail  |      4 |  9280.30 |         2320.08 |           29.1 |            1 | above
          13 | Mercy Ibrahim  | Germany       | Retail  |      1 |  8505.00 |         8505.00 |           60.9 |            1 | above
```

### Prove it, then measure it

Run both versions and compare with `EXCEPT` in both directions (the technique from Module 1), and count how often each one scans `order_items`:

```
 before_rows | after_rows | differences
-------------+------------+-------------
          26 |         26 |           0

 before_scans_of_order_items | after_scans_of_order_items
-----------------------------+----------------------------
                           4 |                          1
```

Identical results (26 rows each, 0 differences), and the nested version scans `order_items` **four times** against **once**: that is the repeated work, made visible. Three points about the proof:

- **It must run both ways.** `A EXCEPT B` finding nothing only says A has no extra rows; you also need `B EXCEPT A`.
- **Window rank equals the correlated rank** only because `RANK()` and "`COUNT(*)` of strictly greater, plus one" treat ties identically. If you had used `ROW_NUMBER()` and the data had ties, the proof would have caught it.
- **Rounding matters.** Compare the *rounded* output columns, as the report presents them.

## 13.3 What PostgreSQL does with a CTE (a one-page recap)

From Modules 1, 2 and 7:

| The CTE... | Default behaviour | Take-away |
|---|---|---|
| is used **once**, no volatile functions | **inlined**: planned like a subquery | A wrapper CTE costs nothing, and gains nothing |
| is used **more than once** | **materialized**: computed once, read by each reference | Good for expensive work, bad if each use needs only a few rows |
| contains `random()` and the like | never inlined | Every reference sees the same value |
| is **recursive** or **data-modifying** | never inlined | Always runs as written |

Use `MATERIALIZED` / `NOT MATERIALIZED` only with **evidence from `EXPLAIN ANALYZE`**, and comment the evidence next to the hint.

## 13.4 Indexing a recursive query

A recursive CTE repeats one join per round: *"find the rows whose parent pointer equals one of the rows found in the previous round."* That join column (`manager_id`, `parent_id`) is exactly what needs an index.

To see it, we generate an org chart of **111,111 people** in 6 levels (every manager has 10 reports) and traverse it with no index on `manager_id`:

```sql
WITH RECURSIVE org(emp_id, depth) AS (
    SELECT emp_id, 1 FROM big_org WHERE manager_id IS NULL
    UNION ALL
    SELECT e.emp_id, o.depth + 1 FROM big_org e JOIN org o ON e.manager_id = o.emp_id
)
SELECT COUNT(*), MAX(depth) FROM org;
```

The plan's recursive step is `Hash Join` over a **`Seq Scan on big_org e ... loops=6`**: the **whole table is scanned once per round**. After `CREATE INDEX idx_big_org_manager ON big_org (manager_id)` it becomes a `Nested Loop` over an **`Index Scan using idx_big_org_manager ... loops=111111`**: one cheap lookup per person expanded.

Two traversals, measured from the plan (these counts do not depend on machine speed):

```
          scenario           | whole_table_scans | index_lookups | result_rows | max_depth
-----------------------------+-------------------+---------------+-------------+-----------
 no index: whole organisation|                 6 |             0 |      111111 |         6
 no index: one team of 11    |                 2 |             0 |          11 |         2
 with index: whole organisation|               0 |        111111 |      111111 |         6
 with index: one team of 11  |                 0 |            11 |          11 |         2
```

And what that meant for time on my test machine (**yours will differ**):

| Traversal | No index | With index | Speed-up |
|---|---|---|---|
| Whole organisation (111,111 people) | about 170 ms | about 127 ms | about 1.3 times |
| One team of 11 | about 28.5 ms | about 0.08 ms | **about 375 times** |

This is the nuance that matters. For the **whole organisation** every row has to be visited anyway, so scanning the table six times is not much worse than 111,111 lookups. For a **small team** the index is transformative, because without it PostgreSQL reads all 111,111 rows in every round just to find 10 people. **An index on the join column pays off most when the traversal is selective**, which is the typical business case ("everyone under this manager", "everything in this category").

Practical rules:

- **Index the column the recursion joins on**: `manager_id`, `parent_id`, and for a BOM the column you join *upwards* on (in Module 11 the primary key `(assembly_id, component_id)` serves the downward explosion, but the where-used query joins on `component_id`, which needs its own index).
- **PostgreSQL does not index foreign keys automatically.** A `REFERENCES` clause enforces a rule; it does not create an index on the referencing column.
- **Run `ANALYZE` after bulk loads**, so the planner has statistics to choose between a scan and an index.
- **Indexes are not free**: they take space and slow writes. Add them for the traversals you actually run.

## 13.5 Everyday performance habits

| Habit | Why | Module |
|---|---|---|
| **Aggregate, then join** | Joining first multiplies rows and then you sum repeats | 4 |
| **Filter early** | Fewer rows flow through later steps | 7 |
| **Name columns; avoid `SELECT *`** | Hides what flows downstream and breaks on schema changes | 3 |
| **`UNION ALL`, not `UNION`** | `UNION` pays for de-duplication and can silently drop rows | 8, 11 |
| **Window function instead of a correlated subquery** | One pass instead of one per row | 5 |
| **`EXISTS` / `LEFT JOIN ... IS NULL`, not `NOT IN`** | `NOT IN` returns nothing if a `NULL` appears | 3 |
| **Cap recursion** (path check, depth guard) | A cycle makes it run forever | 8, 10 |
| **Index the recursion's join column** | One lookup per node instead of a scan per round | 13.4 |
| **Keep statistics fresh** (`ANALYZE`) | The planner chooses from them | 7 |
| **Reconcile totals** | Wrong fast is still wrong | 4, 6, 9 |
| **Comment every hint with its evidence** | A hint is a bet about your data | 7 |

## 13.6 Anti-pattern catalogue

| Anti-pattern | Why it hurts | Fix |
|---|---|---|
| **Wrapper CTE** around one table or one step, used once | Noise; suggests an optimisation that does not exist | Query the table directly |
| **`SELECT *` in a CTE** | Breaks when a column is added; hides the data flow; drags wide rows through every step | List the columns |
| **Recursion with no stop condition** | Runs forever on a cycle | Path check or `CYCLE` clause; a depth guard as a safety net |
| **The same subquery written several times** | Repeated work, and four places to keep in sync | One CTE, referenced as needed |
| **`COUNT(DISTINCT)` as a repair for a join fan-out** | Hides the real grain error; wrong for sums | Aggregate to the join grain first |
| **`NOT IN (subquery)`** | Returns zero rows once a `NULL` appears | `NOT EXISTS` |
| **`UNION` in a quantity roll-up** | Identical rows from different branches vanish | `UNION ALL`, then aggregate |
| **Hints added "to be safe"** | A wrong guess can slow a query 1,000-fold | Measure first; keep only what wins |
| **`ORDER BY` inside a CTE** with no `LIMIT` | Usually ignored; misleading | Sort in the outer query |
| **Naming a CTE after a real table** | Shadows the table | A descriptive name |
| **Shipping numbers without a reconciliation** | Silent errors reach reports | Compare with an independent total |
| **Experimenting on real data** | A leaked `UPDATE` is real | `BEGIN ... ROLLBACK` |

### Evidence for three of them

**A wrapper CTE** changes nothing, in either direction:

```
 differing_rows | before_has_cte_scan | after_has_cte_scan | before_scans_of_orders | after_scans_of_orders
----------------+---------------------+--------------------+------------------------+-----------------------
              0 | f                   | f                  |                      1 |                     1
```

Same result, no `CTE Scan` in either plan (the CTE is inlined), the same single scan of `orders`. The wrapper adds ceremony and no benefit.

**`SELECT *`** works today and fails tomorrow. A CTE selects `*` from `departments` and is combined with a fixed three-column list; then a colleague adds a column (inside a transaction we roll back):

```
                     what                      | outcome
-----------------------------------------------+---------
 SELECT * in the CTE, before a column is added | ok
 SELECT * in the CTE, after a column is added  | 42601
 explicit column list, after a column is added | ok
```

`42601` is a syntax error: *each UNION query must have the same number of columns*. The explicit version is immune.

**A recursion with no stop condition** on the routes graph is cancelled by a timeout; with a path check it returns the 12 genuine simple paths:

```
 unguarded_search_cancelled        guarded_search_rows
----------------------------      ---------------------
 t                                                  12
```

## 13.7 Reading a plan like a reviewer

When a query is slow, work through the plan in this order:

1. **Which node dominates the time?** (look at `actual time`, or the biggest `loops`)
2. **Are `actual rows` close to the estimate?** A big gap usually means stale statistics (`ANALYZE`) or a join that multiplies rows.
3. **Is something scanned many times?** (`loops=` large on a `Seq Scan`: the pattern from 13.4)
4. **Is an index used where you expect?** If not: does it exist, is the column the one you join on, are statistics current?
5. **Do you see a `CTE Scan`?** Then a CTE was materialized: is that what you intended?

Add `BUFFERS` (`EXPLAIN (ANALYZE, BUFFERS)`) to see how many pages each node touched, which is often steadier than timings. Remember `EXPLAIN ANALYZE` **runs** the query: wrap data-changing statements in `BEGIN ... ROLLBACK`.

## 13.8 Choosing how to store a hierarchy

Everything in Modules 9 to 11 used the **adjacency list** (a parent pointer) read with recursive CTEs. There are other models. We build the same 12-category tree four ways, inside a transaction we roll back, and compare them with evidence.

| Model | How the tree is stored |
|---|---|
| **Adjacency list** + recursive CTE | `parent_id` on each row (the `categories` table) |
| **Materialized path** | each row stores its whole path, e.g. `1/5/6/` |
| **Closure table** | a separate table with one row for every ancestor and descendant pair |
| **`ltree`** | the path as a special type with indexable operators, e.g. `1.5.6` |

### Reading: all four agree

*The subtree of Electronics (category 1, itself and everything below):*

```
             model              | rows_found | differences_from_adjacency
--------------------------------+------------+----------------------------
 adjacency list + recursive CTE |          7 |                          0
 materialized path              |          7 |                          0
 closure table                  |          7 |                          0
 ltree                          |          7 |                          0
```

### Writing: they differ a lot

*Move the Phones subtree (Phones and Smartphones) from Electronics to Office. How many stored rows must each model change?*

```
             model              | rows_changed
--------------------------------+--------------
 adjacency list + recursive CTE |            1
 materialized path              |            2
 closure table                  |            4
 ltree                          |            2
```

| Model | What it rewrites | Cost grows with |
|---|---|---|
| Adjacency list | one parent pointer | nothing: always 1 row |
| Materialized path, `ltree` | the path of **every node in the moved subtree** | the size of the subtree |
| Closure table | links to the **old and new ancestors** of every node in the subtree | subtree size **times** depth |

After the move, all four models still give the right answer for both the Office and the Electronics subtrees. (A gotcha: with `ltree`, the moved node itself has no remainder to append, so calling `subpath` on it fails with `invalid positions`; handle the subtree root separately, as the exercise does.)

### Storage

```
             model              | stored_rows
--------------------------------+-------------
 adjacency list + recursive CTE |          12
 materialized path              |          12
 closure table                  |          27
 ltree                          |          12
```

The closure table keeps **27 rows for 12 nodes**, because it stores every ancestor-descendant pair. That grows quickly with depth.

### Constraints and tooling

| | Adjacency list | Materialized path / `ltree` | Closure table |
|---|---|---|---|
| **Integrity** | a foreign key guarantees the parent exists (it does **not** prevent cycles) | the stored path can **disagree** with the parent pointer if updates are missed | the derived pairs can drift unless maintained (usually by triggers) |
| **Subtree read** | recursive CTE, one round per level | one `LIKE` / `<@` condition, can use an index | one indexed lookup |
| **Ancestors** | upward recursion | split the path | one lookup |
| **Move a subtree** | trivial | rewrite subtree | rewrite links |
| **Tooling** | plain SQL, works everywhere | `ltree` adds operators and index types | plain SQL |

A stored path is **redundant data**, so it needs an audit. The query "stored path should equal the parent's path plus my own id" finds any row that has drifted. We corrupted one row to prove it: it reported exactly one mismatch (Smartphones claiming `8/6/` when its parent says `1/5/6/`).

### Recommendation

**Start with the adjacency list and recursive CTEs** (this course's approach): it is the simplest to write to, is easy to keep correct, and is fast enough for most business hierarchies, especially with an index on the parent column (13.4). Move to `ltree` or a closure table when you have measured a **read-heavy workload on a deep or very large tree** where recursion is too slow, and you can accept the cost of maintaining the extra data (and auditing it).

## 13.9 A review checklist for CTE-based SQL

Before you ship a query, check:

- [ ] Every CTE has a **descriptive name** and a **grain comment**.
- [ ] Each CTE has **one job** (filter, aggregate, join or rank).
- [ ] **No `SELECT *`**; the columns are listed.
- [ ] A measure is only summed at the grain where it lives (**no fan-out**).
- [ ] **`UNION ALL`** unless de-duplication is truly intended.
- [ ] Every recursion has a **stop condition** (path check, `CYCLE`, or a guard) and typed anchor columns.
- [ ] Anti-joins use **`NOT EXISTS`** or `LEFT JOIN ... IS NULL`.
- [ ] **Totals reconcile** against an independent query.
- [ ] A refactor is **proven equivalent** (`EXCEPT` both ways).
- [ ] Any **hint is commented** with its evidence.
- [ ] The **join column of every recursion is indexed**, and statistics are current.
- [ ] Anything that **changes data** runs inside a transaction, with a documented rollback plan.

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Refactoring without an equivalence proof | Silent change in results | `EXCEPT` both ways, then compare counts |
| Optimising without measuring | No gain, or a slowdown | `EXPLAIN ANALYZE`, compare, keep what wins |
| Judging an index on a whole-table traversal | "It barely helped" | Test the selective case (one subtree) too |
| No index on the parent column of a big tree | Whole-table scan every round | Index the join column; `ANALYZE` |
| Believing a wrapper CTE is an optimisation fence | Needless clutter | Since version 12 a single-use CTE is inlined |
| `SELECT *` in shared CTEs | Breaks after a column is added | Explicit columns |
| Choosing a fancy hierarchy model first | Extra maintenance with no measured benefit | Start with adjacency list + recursive CTE |
| Storing a path and never auditing it | Paths drift from the parent pointers | An audit query, or derive the path from the pointers |
| Comparing timings from one run | Noise mistaken for signal | Repeat; prefer stable counts (scans, rows, loops) |

## Key takeaways

- **Correct, clear, fast, in that order.** Measure before you optimise, and prove equivalence before you refactor.
- A nested query that repeats the same aggregation can usually be **one CTE**; the plan shows the saving (4 scans become 1).
- **Index the join column of a recursive query.** It transforms **selective** traversals (375 times faster here) and helps whole-tree traversals only modestly.
- A **wrapper CTE** is noise, **`SELECT *`** is fragile, and a **recursion without a guard** is a hang waiting for a cycle.
- For hierarchies, the adjacency list is the best default. Materialized paths, `ltree` and closure tables trade **cheaper reads** for **costlier, riskier writes**.
- Use the **checklist**: it is the course in twelve lines.

## Checkpoint

<details>
<summary>1. You rewrite a nested query as CTEs and the output "looks the same". What do you do before shipping, and why both directions?</summary>

Compare old and new with `EXCEPT` in **both** directions and confirm the row counts match. One direction only shows the first query has no extra rows; the other direction catches rows that the rewrite lost.
</details>

<details>
<summary>2. A recursive org-chart query takes 28 ms for one team in a 111,111-row table. What is the likely cause and fix?</summary>

There is no index on the parent column (`manager_id`), so every round scans the whole table to find a handful of reports. Create an index on that column and run `ANALYZE`; the same query drops to well under a millisecond.
</details>

<details>
<summary>3. Why did the index help the single team 375 times but the whole organisation only 1.3 times?</summary>

The whole-organisation traversal visits every row anyway, so six full scans cost about as much as 111,111 index lookups. The single team needs only 11 rows, so avoiding a full scan in each round saves almost everything.
</details>

<details>
<summary>4. You moved a subtree of 2 nodes and the closure table changed 4 rows while the adjacency list changed 1. What does that tell you about the models?</summary>

The adjacency list stores one pointer per node, so a move rewrites one row. The closure table stores every ancestor-descendant pair, so a move rewrites the links to the old and new ancestors for each node in the subtree. Its write cost grows with subtree size and depth, in exchange for very fast subtree reads.
</details>

**Next:** do the [exercises](exercises.md), then continue to Module 14: Capstone Portfolio Projects *(coming soon)*.
