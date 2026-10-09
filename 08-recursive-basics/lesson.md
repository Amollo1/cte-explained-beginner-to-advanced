# Module 8: Recursive CTE Fundamentals

**Level:** Intermediate  |  **Time:** about 2.5 hours  |  **Files:** [`examples.sql`](examples.sql) · [`exercises.md`](exercises.md)

## Learning objectives

By the end of this module you can:

- explain how a recursive CTE runs, one round at a time,
- write one with an anchor member, a recursive member and a safe stop condition,
- build number and date series, and use a calendar to **fill gaps** in data,
- carry several columns of state from one row to the next,
- end a recursion safely, and explain what `UNION` vs `UNION ALL` does to a cycle,
- recognise the common error messages and fix them.

This module is the foundation for the next three: org charts and category trees (Module 9), graphs and cycles (Module 10) and bills of materials (Module 11).

---

## 8.1 Why recursion?

Some questions have an answer whose **depth you cannot know in advance**:

- *Who is above this employee, and who is above them, and so on, until the top?*
- *Which cities can I reach, and from those, which more?*
- *What parts does a bicycle contain, including parts of parts?*

A normal query can walk a fixed number of steps by joining a table to itself two or three times. A **recursive CTE** repeats a step *until there is nothing left to find*.

**Analogy.** Russian dolls. Open the biggest doll and find a smaller one inside. Open that one. Repeat until a doll has nothing inside. A recursive query works the same way: start with one thing (the *anchor*), look for the next thing inside or beyond it (the *recursive step*), and stop when the search comes back empty.

## 8.2 Anatomy

```sql
WITH RECURSIVE powers(n, iteration) AS (
    SELECT 1, 0                              -- (1) anchor member: where we start
    UNION ALL                                -- (2) combines the rounds
    SELECT n * 2, iteration + 1              -- (3) recursive member: builds the next row from the previous
    FROM powers                              --     it reads from the CTE ITSELF
    WHERE iteration < 5                      -- (4) stop condition
)
SELECT iteration, n FROM powers ORDER BY iteration;
```

```
 iteration | n
-----------+----
         0 |  1
         1 |  2
         2 |  4
         3 |  8
         4 | 16
         5 | 32
```

| Part | Role |
|---|---|
| `WITH RECURSIVE` | the keyword that allows a CTE to refer to itself (it applies to the whole `WITH` list; other CTEs in it may be ordinary) |
| **anchor member** | an ordinary query that produces the starting rows; it may **not** refer to the CTE |
| `UNION ALL` (or `UNION`) | joins the rounds together |
| **recursive member** | refers to the CTE by name and produces the next round from the previous round |
| stop condition | a `WHERE` that stops producing rows, or running out of matching rows |
| column list `powers(n, iteration)` | names the columns (optional, but clear) |

The `iteration` column is not required. It is a teaching and debugging aid, and you will often keep a `depth` column like it.

## 8.3 How it actually runs

PostgreSQL does **not** run the whole thing at once. It works in rounds, using a *working table*:

1. Run the **anchor**. Its rows are the result so far, and also the working table.
2. Run the **recursive member**, feeding it **only the working table** (the rows from the *previous round*, not everything found so far).
3. If it produced rows, add them to the result and make them the new working table.
4. Repeat step 2. When the recursive member produces **zero rows**, stop.
5. The outer query reads the entire accumulated result.

For the powers example:

| Round | Working table (input) | Recursive member produces |
|---|---|---|
| 0 (anchor) | | `(1, 0)` |
| 1 | `(1, 0)` | `(2, 1)` |
| 2 | `(2, 1)` | `(4, 2)` |
| 3 | `(4, 2)` | `(8, 3)` |
| 4 | `(8, 3)` | `(16, 4)` |
| 5 | `(16, 4)` | `(32, 5)` |
| 6 | `(32, 5)` | *nothing* (`iteration < 5` is false), so the recursion stops |

The key insight: **the recursive member only ever sees the previous round**. That is why a recursion over a tree does not re-process rows it has already handled.

## 8.4 Numbers, and when not to recurse

```sql
WITH RECURSIVE counter(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM counter WHERE n < 10
)
SELECT n FROM counter;
```

This produces 1 to 10, exactly what `generate_series(1, 10)` returns. Comparing the two with the `EXCEPT` technique from Module 1:

```
 recursive_rows | series_rows | differences
----------------+-------------+-------------
             10 |          10 |           0
```

**So why learn it?** Because the *mechanism* is what matters:

| Situation | Use |
|---|---|
| A plain run of numbers or dates | `generate_series`: simpler and faster |
| The next row depends on the **previous row** (Fibonacci, running state) | recursion |
| You must follow **data** from parent to child, step by step (Modules 9 to 11) | recursion |

## 8.5 Gap-filling with a calendar

Data only contains days when something happened. A report of "orders per day" silently omits the quiet days. To show them, build a **calendar** with one row per day and `LEFT JOIN` your data onto it.

```sql
WITH RECURSIVE bounds AS (
    SELECT MIN(order_date) AS first_day, MAX(order_date) AS last_day
    FROM orders
),
calendar(day) AS (                   -- grain: one row per calendar day
    SELECT first_day FROM bounds
    UNION ALL
    SELECT c.day + 1                 -- date + 1 = the next day
    FROM calendar c
    CROSS JOIN bounds b
    WHERE c.day < b.last_day
),
daily_orders AS (                    -- grain: one row per day that HAS orders
    SELECT order_date AS day, COUNT(*) AS orders
    FROM orders
    GROUP BY order_date
),
filled AS (                          -- grain: one row per calendar day, zeros filled in
    SELECT c.day, COALESCE(d.orders, 0) AS orders
    FROM calendar c
    LEFT JOIN daily_orders d ON d.day = c.day
)
SELECT date_trunc('month', day)::date                  AS month,
       COUNT(*)                                        AS days,
       COUNT(*) FILTER (WHERE orders > 0)              AS days_with_orders,
       COUNT(*) FILTER (WHERE orders = 0)              AS days_without_orders,
       SUM(orders)                                     AS orders
FROM filled
GROUP BY 1
ORDER BY 1
LIMIT 4;
```

```
   month    | days | days_with_orders | days_without_orders | orders
------------+------+------------------+---------------------+--------
 2025-01-01 |   31 |                5 |                  26 |      5
 2025-02-01 |   28 |                8 |                  20 |      8
 2025-03-01 |   31 |                9 |                  22 |     12
 2025-04-01 |   30 |                6 |                  24 |      6
```

March shows 9 days with orders but 12 orders, because some days had several. Notice that the ordinary CTEs `bounds`, `daily_orders` and `filled` sit in the same `WITH RECURSIVE` list as the recursive `calendar`.

### Reconcile the calendar

As in Modules 4 and 6, check that nothing was lost or invented:

```
 calendar_days | expected_days | orders_via_calendar | orders_total
---------------+---------------+---------------------+--------------
           546 |           546 |                 120 |          120
```

The calendar has exactly the expected 546 days, and carries all 120 orders. Of those days, 434 had no orders at all.

### The bounds trap

A tempting shortcut is to build a calendar for "all of 2026". Watch what that reports:

```
 months_reported_as_zero_in_2026 | last_order_date
---------------------------------+-----------------
                               6 | 2026-06-30
```

July to December show **zero orders**, but the data simply ends on 30 June. Those zeros are not facts; they are the absence of data. **Take the calendar bounds from the data** (`MIN` and `MAX`), or you will report invented zeros.

### Gap-filling fixes `LAG`

In Module 5 you saw that `LAG` compares with the previous **row**, not the previous month. Inside a rolled-back transaction we remove one month of completed orders (September 2025) and compare two approaches for October:

```
 calendar_months | months_with_data | naive_compares_oct_with | naive_growth_pct | calendar_prev_revenue | calendar_growth_pct
-----------------+------------------+-------------------------+------------------+-----------------------+---------------------
              18 |               17 | 2025-08-01              |            -50.7 |                     0 |
```

- **Naive:** only 17 months have data, so `LAG` compares October with **August** and reports -50.7%. Plausible, and wrong.
- **With a month calendar:** September exists with revenue 0, so October is compared with 0. Dividing by zero is avoided with `NULLIF`, so growth is `NULL`, an honest "not meaningful".

The month calendar is built the same way, stepping with `(month + INTERVAL '1 month')::date`.

> **In production, `generate_series` is the usual way to build a calendar**, and it is shorter. The recursive version here teaches the mechanism, and it is the pattern you need when each step depends on data rather than on a fixed increment.

## 8.6 Carrying several columns of state

Each row can carry whatever the next row needs. Fibonacci needs the last **two** numbers; a factorial needs the running product:

```sql
WITH RECURSIVE seq(n, fib, next_fib, factorial) AS (
    SELECT 1, 1::numeric, 1::numeric, 1::numeric
    UNION ALL
    SELECT n + 1, next_fib, fib + next_fib, factorial * (n + 1)
    FROM seq
    WHERE n < 8
)
SELECT n, fib, factorial FROM seq ORDER BY n;
```

```
 n | fib | factorial
---+-----+-----------
 1 |   1 |         1
 2 |   1 |         2
 3 |   2 |         6
 4 |   3 |        24
 5 |   5 |       120
 6 |   8 |       720
 7 |  13 |      5040
 8 |  21 |     40320
```

`next_fib` of one row becomes `fib` of the next, and `fib + next_fib` becomes the new `next_fib`. The type is `numeric` because factorials grow fast: with `bigint` the calculation fails at 21! with `22003: bigint out of range`.

## 8.7 Termination: how a recursion ends

A recursion stops in one of three ways:

| Mechanism | Example | When it applies |
|---|---|---|
| **Runs out of rows** | an org chart: eventually nobody reports to anyone left | the data itself is finite and has no cycles |
| **An explicit guard** | `WHERE iteration < 5`, `WHERE depth < 10` | series, and as a safety net everywhere |
| **`UNION` de-duplication** | rows already produced are discarded | simple cycles where whole rows repeat |

### What happens with no stop

```sql
SET statement_timeout = '300ms';
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n)    -- no stop condition
SELECT COUNT(*) FROM n;
-- ERROR:  canceling statement due to statement timeout
RESET statement_timeout;
```

It never ends by itself; it runs until something kills it. **Always set `statement_timeout` before experimenting** with a query that might not stop. (In the examples file the error is caught and shown as text, so the script keeps running.)

A `LIMIT` on the **outer** query also stops an infinite recursion, because rows are produced one at a time:

```sql
WITH RECURSIVE forever(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM forever)
SELECT i FROM forever LIMIT 5;       -- returns 1, 2, 3, 4, 5
```

That is handy for exploring, but do not rely on it: an `ORDER BY` or an aggregate on the outer query needs *all* the rows and would never finish.

### `UNION` vs `UNION ALL`

Consider a cycle: 1 leads to 2, 2 to 3, and 3 back to 1.

| Form | Result |
|---|---|
| `UNION` | stops by itself: `{1, 2, 3}`, since round 4 only produces rows already seen |
| `UNION ALL` + `WHERE depth < 10` | produces **10 rows** (1, 2, 3, 1, 2, 3, ...) and only the guard stops it |

`UNION ALL` is the default choice (it is faster, and keeps every row). `UNION` costs a duplicate check on every round, and it only works when **entire rows** repeat. If a row also carries a `depth` or a `path`, it never repeats exactly, so `UNION` cannot save you. Module 10 shows the proper tools for graph cycles.

## 8.8 The rules, with the real error messages

Mistakes in the recursive term produce specific errors. These are the exact messages PostgreSQL gives:

| Mistake | Error |
|---|---|
| Aggregate in the recursive term (`MAX(i) + 1`) | `aggregate functions are not allowed in a recursive query's recursive term` |
| Referencing the CTE **twice** in the recursive term | `recursive reference to query "n" must not appear more than once` |
| Referencing it inside an expression subquery (`WHERE i < (SELECT MAX(i) FROM n)`) | `recursive reference to query "n" must not appear within a subquery` |
| Referencing it on the nullable side of an outer join | `recursive reference to query "n" must not appear within an outer join` |
| The **anchor** referencing the CTE | `recursive reference to query "n" must not appear within its non-recursive term` |
| `ORDER BY`, `LIMIT` or `OFFSET` inside the recursive term | `ORDER BY in a recursive query is not implemented` (the same wording appears with `LIMIT` or `OFFSET`) |

Put `ORDER BY` and `LIMIT` in the **outer** query instead.

## 8.9 The type trap

The **anchor decides each column's type**, and the recursive term must produce the same type. This fails:

```sql
WITH RECURSIVE n(i) AS (
    SELECT 1                              -- integer
    UNION ALL
    SELECT i + 1::bigint FROM n WHERE i < 5   -- bigint
)
SELECT * FROM n;
-- ERROR: recursive query "n" column 1 has type integer in non-recursive term but type bigint overall
```

The fix is to make the anchor the wider type: `SELECT 1::bigint`. This is the very error you hit when a running product or sum outgrows `integer`. When in doubt, **cast the anchor** to the type you need (`numeric` for money and factorials, `text` for built-up strings).

## 8.10 Debugging checklist

1. **Run the anchor alone.** Is the starting set what you expect?
2. **Add an `iteration` or `depth` column**, and return it.
3. **Cap the rounds** while developing: `WHERE depth < 3`, then look at each round.
4. **Set `statement_timeout`** (for example `'2s'`) before running anything unproven.
5. **Check the types** of the anchor columns against the recursive term.
6. **Count rounds, not rows.** The number of rounds is the *depth*. A recursion over a 5-level hierarchy runs 5 rounds regardless of how many rows exist.

Performance note, for later: each round joins only the previous round's rows to your table, so the **join column should be indexed** (Module 13 measures this).

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| No stop condition on a series | Query never finishes | `WHERE n < limit`; `statement_timeout` while developing |
| Anchor type narrower than the recursive result | `column 1 has type integer ... but type bigint overall` | Cast the anchor (`1::bigint`, `1::numeric`) |
| Building a calendar for a fixed year | Fake zeros beyond the data | Take `MIN` and `MAX` from the data |
| Using `UNION` and expecting it to stop a cycle that carries a `depth` | Still loops | `UNION` only de-duplicates identical rows; use a guard |
| Aggregate or `ORDER BY` in the recursive member | `...not allowed in a recursive query's recursive term` | Move it to the outer query |
| Referencing the CTE twice in the recursive member | `must not appear more than once` | Restructure to one reference |
| Trusting `LIMIT` to cap a recursion that has an outer `ORDER BY` | Hangs | Use a real guard in the recursive term |
| Using recursion where `generate_series` is enough | Longer, slower code | Reserve recursion for dependent steps |

## Key takeaways

- A recursive CTE has an **anchor**, a **recursive member**, and something that **stops** it.
- It runs in **rounds**; the recursive member sees **only the previous round**.
- Each row can carry **several columns of state** to build the next row.
- Termination: run out of rows, a guard, or `UNION` de-duplication. Always have a guard in development, plus `statement_timeout`.
- **Gap-filling** with a calendar reveals missing days and months, but take its bounds **from the data**.
- Cast the **anchor** to the type you need, and keep `ORDER BY`, `LIMIT` and aggregates out of the recursive member.

## Checkpoint

<details>
<summary>1. In round 3 of a recursive CTE, which rows does the recursive member read?</summary>

Only the rows produced by round 2 (the working table), not the anchor rows and not everything accumulated so far.
</details>

<details>
<summary>2. You build a calendar for all of 2026 and the report shows zero orders for July to December. What went wrong?</summary>

The data ends on 30 June, so those zeros are not real. The calendar's bounds should come from the data (`MIN` and `MAX` of the date column), not from a fixed year.
</details>

<details>
<summary>3. A cycle 1, 2, 3, 1, 2, 3, ... is queried with <code>UNION ALL</code> and a <code>depth &lt; 10</code> guard, and with plain <code>UNION</code>. How many rows does each produce?</summary>

`UNION ALL` with the guard returns 10 rows. `UNION` returns 3, because it discards rows already produced, so the recursion finds nothing new after round 3.
</details>

<details>
<summary>4. <code>recursive query "n" column 1 has type integer in non-recursive term but type bigint overall</code>. How do you fix it?</summary>

Cast the anchor to the wider type, for example `SELECT 1::bigint`, so the anchor and the recursive term agree.
</details>

**Next:** do the [exercises](exercises.md), then continue to Module 9: Hierarchies, Org Charts & Category Trees *(coming soon)*.
