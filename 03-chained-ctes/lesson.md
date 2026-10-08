# Module 3: Multiple & Chained CTEs

**Level:** Beginner  |  **Time:** about 2 hours  |  **Files:** [`examples.sql`](examples.sql) · [`exercises.md`](exercises.md)

## Learning objectives

By the end of this module you can:

- write a query as a pipeline of named steps, each with one job,
- state and verify the **grain** (what one row means) of every step,
- debug a chain by inspecting any step in isolation,
- join independent CTEs without silently losing rows,
- write an anti-join safely, and explain the `NOT IN` trap.

---

## 3.1 What "chained" means

Module 1 showed two CTEs in one query. Real analysis often needs five or six steps. A **chain** is a `WITH` list where each CTE builds on the ones before it, like stages on an assembly line.

The rules:

| Rule | Example |
|---|---|
| Write `WITH` **once**, then separate CTEs with commas | `WITH a AS (...), b AS (...), c AS (...)` |
| A CTE can use any CTE **defined before it** | `b` can read from `a`; `a` cannot read from `b` |
| The final query can use any CTE | `SELECT ... FROM c JOIN a ...` |
| A CTE can be referenced several times | by joins, subqueries, or later CTEs |
| No semicolon until the very end | one statement |

## 3.2 The grain principle

The most important habit in this module: **before writing a CTE, decide its grain, meaning what one row represents.** Then write it in a comment.

A good chain moves through grains deliberately:

| CTE | Grain (one row per...) | Job |
|---|---|---|
| `order_totals` | completed order | collapse line items into one revenue figure per order |
| `customer_totals` | customer | collapse orders into one row per customer |
| `customer_rank` | customer | add a rank, without changing the grain |

Most wrong numbers in analytics come from mixing grains: joining a per-order table to a per-line table and then summing. Naming the grain makes that mistake visible. (Module 4 studies this trap in detail.)

## 3.3 Worked example 1: a three-step pipeline

Question: *who are the top 5 customers by revenue, counting completed orders?*

```sql
WITH order_totals AS (            -- grain: one row per completed order
    SELECT o.order_id,
           o.customer_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS items_revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.order_id, o.customer_id
),
customer_totals AS (              -- grain: one row per customer
    SELECT customer_id,
           COUNT(*)           AS orders,
           SUM(items_revenue) AS revenue
    FROM order_totals
    GROUP BY customer_id
),
customer_rank AS (                -- same grain, plus a rank column
    SELECT customer_id, orders, revenue,
           RANK() OVER (ORDER BY revenue DESC) AS revenue_rank
    FROM customer_totals
)
SELECT r.revenue_rank, c.customer_name, c.country, r.orders, ROUND(r.revenue, 2) AS revenue
FROM customer_rank r
JOIN customers c ON c.customer_id = r.customer_id
WHERE r.revenue_rank <= 5
ORDER BY r.revenue_rank, c.customer_id;
```

```
 revenue_rank | customer_name  |    country    | orders | revenue
--------------+----------------+---------------+--------+----------
            1 | Dennis Okeke   | Tanzania      |     14 | 33505.35
            2 | Brian Ali      | Kenya         |      8 | 20504.30
            3 | Achieng Omondi | Kenya         |      9 | 15520.75
            4 | Chloe Brown    | United States |      4 |  9280.30
            5 | Mercy Ibrahim  | Germany       |      1 |  8505.00
```

**A first taste of `RANK()`.** `RANK() OVER (ORDER BY revenue DESC)` numbers rows by revenue, highest first. Customers with equal revenue share a rank, and the next rank is skipped (1, 2, 2, 4). Module 5 covers window functions fully; for now, read it as "number the rows by this ordering".

Why three steps rather than one big query?

- **Each step is small enough to verify by eye.** `order_totals` is nothing but "one revenue figure per order".
- **Aggregation happens before the join to `customers`.** We summarise first, then attach names, which keeps the join small and safe.
- **Any step can be tested alone** (see 3.5).

## 3.4 Check the grain, do not assume it

If `order_totals` is meant to have one row per order, **prove it**:

```sql
WITH order_totals AS (
    SELECT o.order_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS items_revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY o.order_id
)
SELECT COUNT(*)                 AS row_count,
       COUNT(DISTINCT order_id) AS distinct_orders,
       COUNT(*) = COUNT(DISTINCT order_id) AS grain_is_one_row_per_order
FROM order_totals;
```

```
 row_count | distinct_orders | grain_is_one_row_per_order
-----------+-----------------+----------------------------
        82 |              82 | t
```

82 rows and 82 distinct orders: the grain holds. If these two numbers ever differ, a join upstream is duplicating rows. This one query catches the most expensive class of SQL bug, so use it on every key step.

## 3.5 Debugging a chain

Because each step is a named table-like object, you can inspect any of them by **changing only the final `SELECT`**:

```sql
WITH order_totals AS (...),
     customer_totals AS (...)
-- SELECT * FROM order_totals LIMIT 5;       -- inspect step 1 instead
SELECT customer_id, orders, ROUND(revenue, 2) AS revenue
FROM customer_totals                           -- inspect step 2
ORDER BY revenue DESC
LIMIT 3;
```

Workflow when a result looks wrong:

1. Point the final select at the **first** CTE. Are the rows right?
2. Move to the second, then the third. The first step that looks wrong is where the bug is.
3. At each step, check the row count against the grain you wrote in the comment.

With nested subqueries you cannot do this without taking the query apart.

## 3.6 Joining independent CTEs

CTEs in a chain do not have to depend on each other. Two CTEs can answer two different questions, and you combine them on a shared key.

Question: *for each month, how many orders were placed (any status) and how much completed revenue came in?*

```sql
WITH monthly_orders AS (          -- grain: one row per month, ALL orders
    SELECT date_trunc('month', order_date)::date AS month,
           COUNT(*) AS orders_placed
    FROM orders
    GROUP BY 1
),
monthly_revenue AS (              -- grain: one row per month, completed revenue only
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
)
SELECT mo.month, mo.orders_placed, ROUND(COALESCE(mr.revenue, 0), 2) AS completed_revenue
FROM monthly_orders mo
LEFT JOIN monthly_revenue mr ON mr.month = mo.month
ORDER BY mo.month;
```

```
   month    | orders_placed | completed_revenue
------------+---------------+-------------------
 2025-01-01 |             5 |           9273.25
 2025-02-01 |             8 |          10878.35
 2025-03-01 |            12 |          25668.60
 2025-04-01 |             6 |           6646.00
 ...
```

(`date_trunc('month', ...)` rounds a date down to the first day of its month.)

### The join-type pitfall

Both CTEs share the same grain (one row per month), which makes the join safe. But **which join** you use decides whether rows survive. Compare orders per month with **cancellations** per month. Most months have none:

```sql
WITH monthly_orders AS (
    SELECT date_trunc('month', order_date)::date AS month, COUNT(*) AS orders_placed
    FROM orders GROUP BY 1
),
monthly_cancelled AS (
    SELECT date_trunc('month', order_date)::date AS month, COUNT(*) AS cancelled
    FROM orders WHERE status = 'cancelled' GROUP BY 1
)
SELECT (SELECT COUNT(*) FROM monthly_orders)                                AS months_total,
       (SELECT COUNT(*) FROM monthly_orders mo JOIN monthly_cancelled mc
                             ON mc.month = mo.month)                        AS months_with_inner_join,
       (SELECT COUNT(*) FROM monthly_orders mo LEFT JOIN monthly_cancelled mc
                             ON mc.month = mo.month)                        AS months_with_left_join;
```

```
 months_total | months_with_inner_join | months_with_left_join
--------------+------------------------+-----------------------
           18 |                      6 |                    18
```

The `INNER JOIN` silently **drops 12 of 18 months**, and nothing errors. A report built this way would show only the six months that had a cancellation and look perfectly plausible.

**Rule:** start from the CTE that defines "all the rows you must keep" (`monthly_orders`), `LEFT JOIN` the others, and wrap their columns in `COALESCE(..., 0)` so missing values read as zero instead of `NULL`.

## 3.7 Anti-joins: finding what is missing

An **anti-join** returns rows with **no match** in another table. Question: *which customers have never ordered?* There are three standard techniques, and they all return the same four customers (27 to 30):

```sql
-- (a) LEFT JOIN ... IS NULL, with a CTE
WITH ordering_customers AS (
    SELECT DISTINCT customer_id FROM orders
)
SELECT c.customer_id, c.customer_name
FROM customers c
LEFT JOIN ordering_customers oc ON oc.customer_id = c.customer_id
WHERE oc.customer_id IS NULL
ORDER BY c.customer_id;

-- (b) NOT EXISTS
SELECT c.customer_id, c.customer_name
FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id)
ORDER BY c.customer_id;

-- (c) NOT IN
SELECT c.customer_id, c.customer_name
FROM customers c
WHERE c.customer_id NOT IN (SELECT customer_id FROM orders)
ORDER BY c.customer_id;
```

```
 customer_id |   customer_name
-------------+-------------------
          27 | Aaron Martin
          28 | Beatrice Kiplagat
          29 | Collins Raza
          30 | Diana Torres
```

### The `NOT IN` trap

`NOT IN` has a nasty property: **if the list contains a single `NULL`, it returns no rows at all.** SQL cannot prove any value is "not equal" to an unknown, so every comparison becomes unknown. Here we deliberately add one `NULL` to the list:

```sql
SELECT COUNT(*) AS not_exists_result
FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM (SELECT customer_id FROM orders UNION ALL SELECT NULL) o
                  WHERE o.customer_id = c.customer_id);                          -- 4 (correct)

SELECT COUNT(*) AS not_in_result
FROM customers c
WHERE c.customer_id NOT IN (SELECT customer_id FROM orders UNION ALL SELECT NULL);  -- 0 (wrong!)
```

| not_exists_result | not_in_result |
|---|---|
| 4 | 0 |

In our data `orders.customer_id` never contains `NULL`, so `NOT IN` happens to work. In real data a nullable column can introduce a `NULL` at any time, and your report would silently return nothing.

**Recommendation:** use `NOT EXISTS` or `LEFT JOIN ... IS NULL`. Avoid `NOT IN` against a subquery unless the column is declared `NOT NULL`.

## 3.8 Style guide for chains

| Do | Avoid |
|---|---|
| Name a CTE after **what it contains**: `order_totals`, `monthly_revenue` | `cte1`, `temp`, `a`, `x` |
| Write the grain in a comment on the same line as the name | Leaving the reader to guess |
| One purpose per CTE: filter, aggregate, join, or rank | A single CTE that does all four |
| Select only the columns later steps need | `SELECT *` inside CTEs, which hides what flows downstream |
| Order the chain so it reads top to bottom, source to result | Defining CTEs in an order that makes the reader jump back |

## 3.9 How long should a chain be?

There is no fixed limit, but past roughly 6 to 8 steps a single query becomes hard to review. Signs it is time to split: you scroll to understand it, two people edit it at once, or part of it is reused in other reports. Then promote stable steps to a **view** (Module 2) or, in a data warehouse, to separate models. Until then, a clear chain beats premature structure.

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| `INNER JOIN` between summary CTEs | Rows vanish silently (18 months become 6) | Start from the "keep everything" CTE and `LEFT JOIN` the rest |
| Missing `COALESCE` after a `LEFT JOIN` | `NULL` instead of 0 in reports | `COALESCE(x, 0)` |
| Not stating or checking grain | Revenue doubled, counts inflated | Comment the grain; run the `COUNT(*) = COUNT(DISTINCT key)` check |
| `NOT IN (subquery)` | Returns zero rows when a `NULL` appears | `NOT EXISTS` or `LEFT JOIN ... IS NULL` |
| Referencing a CTE defined later in the list | `relation ... does not exist` | Reorder: dependencies first |
| `cte1`, `cte2`, `cte3` names | Nobody can review it | Descriptive names |

## Key takeaways

- A chain is a `WITH` list where each step builds on earlier ones; write `WITH` once and separate with commas.
- **State the grain** of every CTE in a comment, and **verify** it with a row-count check.
- Debug by pointing the final `SELECT` at each step in turn.
- When combining CTEs, choose the join deliberately: `LEFT JOIN` plus `COALESCE` protects rows.
- Anti-joins: prefer `NOT EXISTS` or `LEFT JOIN ... IS NULL` over `NOT IN`.

## Checkpoint

<details>
<summary>1. What is the "grain" of a CTE, and why write it down?</summary>

It is what one row represents (for example "one row per completed order"). Writing it down makes mixed-grain joins visible, which are the most common cause of inflated or doubled numbers.
</details>

<details>
<summary>2. A monthly report built by joining two CTEs shows only 6 months out of 18. What is the most likely cause?</summary>

An `INNER JOIN` dropped the months that had no match in one of the CTEs. Use a `LEFT JOIN` from the CTE that has all months, and `COALESCE` the other columns.
</details>

<details>
<summary>3. Why is <code>NOT IN (subquery)</code> risky?</summary>

If the subquery returns even one `NULL`, the whole `NOT IN` condition can never be true, so the query returns no rows. `NOT EXISTS` does not have this problem.
</details>

**Next:** do the [exercises](exercises.md). Module 4 (CTEs for Aggregation & Joins) is coming soon and begins the Intermediate tier.
