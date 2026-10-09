# Module 5: CTEs + Window Functions

**Level:** Intermediate  |  **Time:** about 3 hours  |  **Files:** [`examples.sql`](examples.sql) · [`exercises.md`](exercises.md)

## Learning objectives

By the end of this module you can:

- explain how a window function differs from `GROUP BY`,
- explain why a window function cannot be filtered in `WHERE`, and use a CTE to solve it,
- choose between `ROW_NUMBER`, `RANK` and `DENSE_RANK`, and predict what each does with ties,
- build top-N-per-group, running-total and period-over-period reports,
- write window frames explicitly and avoid the default-frame trap,
- compare each row with the previous one using `LAG` and `LEAD`.

---

## 5.1 What is a window function?

`GROUP BY` **collapses** rows: 30 employees in 6 departments become 6 rows. A **window function** computes a value by looking at a set of related rows (the "window") but **keeps every row**.

**Analogy.** A `GROUP BY` report is a summary sheet that replaces the detail. A window function is a new column added to the detail sheet, where each cell is filled in by glancing at related rows. "Show every employee, and next to each one, their department's average salary."

```sql
SELECT (SELECT COUNT(*) FROM (SELECT dept_id, AVG(salary) FROM employees GROUP BY dept_id) g) AS group_by_rows,
       (SELECT COUNT(*) FROM (SELECT AVG(salary) OVER (PARTITION BY dept_id) FROM employees) w) AS window_rows;
```

```
 group_by_rows | window_rows
---------------+-------------
             6 |          30
```

And the detail view:

```sql
SELECT emp_id, first_name, dept_id, salary,
       ROUND(AVG(salary) OVER (PARTITION BY dept_id), 2) AS dept_avg
FROM employees
WHERE dept_id IN (2, 6)
ORDER BY dept_id, salary DESC
LIMIT 5;
```

```
 emp_id | first_name | dept_id |  salary   | dept_avg
--------+------------+---------+-----------+----------
      2 | Brian      |       2 | 165000.00 | 94625.00
      7 | Grace      |       2 | 105000.00 | 94625.00
      8 | Hassan     |       2 | 102000.00 | 94625.00
     17 | Quentin    |       2 |  85000.00 | 94625.00
     15 | Omar       |       2 |  82000.00 | 94625.00
```

## 5.2 Anatomy of a window

```sql
function(...) OVER (
    PARTITION BY dept_id          -- split rows into independent groups (optional)
    ORDER BY salary DESC          -- order rows inside each group (needed for ranking, LAG, running totals)
    ROWS BETWEEN ... AND ...      -- which rows around the current one to include (the "frame", optional)
)
```

| Part | Meaning | Omit it and... |
|---|---|---|
| `PARTITION BY` | Restart the calculation for each group | the whole result is one group |
| `ORDER BY` | Sequence of rows within the group | ranking and `LAG` have no meaning; sums become whole-group totals |
| frame | Which neighbouring rows feed the calculation | a default frame applies (see 5.6) |

## 5.3 Why you need a CTE: order of evaluation

SQL does not run clauses in the order you write them. The logical order is:

`FROM` then `WHERE` then `GROUP BY` then `HAVING` then **window functions** then `SELECT` list then `ORDER BY` then `LIMIT`.

Window functions run **after** `WHERE`, so `WHERE` cannot see them:

```sql
SELECT * FROM employees WHERE ROW_NUMBER() OVER (ORDER BY salary) = 1;
-- ERROR:  window functions are not allowed in WHERE
```

**The fix: compute the window in a CTE, then filter in the next step.** The CTE completes first, so its window column is an ordinary column to the query after it:

```sql
WITH with_avg AS (
    SELECT emp_id, dept_id, salary,
           AVG(salary) OVER (PARTITION BY dept_id) AS dept_avg
    FROM employees
)
SELECT COUNT(*) AS above_dept_avg
FROM with_avg
WHERE salary > dept_avg;          -- 12
```

This is the single most important reason CTEs and window functions travel together. It also replaces the correlated subquery from Module 0 (Example 6c). Prove they agree, with the `EXCEPT` technique:

```
 window_rows | correlated_rows | differences
-------------+-----------------+-------------
          12 |              12 |           0
```

(A subquery in `FROM` works too, but a named CTE reads top to bottom, which is why we use it.)

## 5.4 Ranking functions and ties

Three functions number rows within a window. They differ **only when values tie**. Many customers share an order count, so they make a good demonstration:

```sql
WITH order_counts AS (
    SELECT customer_id, COUNT(*) AS orders_placed
    FROM orders
    GROUP BY customer_id
)
SELECT customer_id,
       orders_placed,
       ROW_NUMBER() OVER (ORDER BY orders_placed DESC, customer_id) AS row_num,
       RANK()       OVER (ORDER BY orders_placed DESC)              AS rnk,
       DENSE_RANK() OVER (ORDER BY orders_placed DESC)              AS dense_rnk
FROM order_counts
ORDER BY orders_placed DESC, customer_id
LIMIT 8;
```

```
 customer_id | orders_placed | row_num | rnk | dense_rnk
-------------+---------------+---------+-----+-----------
           4 |            20 |       1 |   1 |         1
           2 |            14 |       2 |   2 |         2
           3 |            14 |       3 |   2 |         2
           1 |            12 |       4 |   4 |         3
          12 |             6 |       5 |   5 |         4
          20 |             5 |       6 |   6 |         5
           9 |             4 |       7 |   7 |         6
          16 |             4 |       8 |   7 |         6
```

Look at customers 2 and 3 (tied on 14 orders), and what happens next:

| Function | Tied rows | Next rank after a tie | Use when |
|---|---|---|---|
| `ROW_NUMBER` | different numbers (arbitrary unless you add a tiebreaker) | no gap | you need **exactly N rows** |
| `RANK` | **same** rank | **skips** (2, 2, then 4) | you want ties included, Olympic-style |
| `DENSE_RANK` | **same** rank | **no skip** (2, 2, then 3) | you want "top N distinct values" |

Note the `customer_id` added after `orders_placed DESC` in the `ROW_NUMBER` window. **Without a tiebreaker, `ROW_NUMBER` assigns tied rows in an arbitrary order** that can change between runs. Always add a unique column last when you need a repeatable result.

## 5.5 Top N per group

The classic pattern: **rank in one CTE, filter in the next**. Question: *the top 3 products by revenue in each category.*

```sql
WITH product_revenue AS (            -- grain: one row per product (completed orders)
    SELECT p.product_id, p.product_name, p.category_id,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM order_items i
    JOIN orders   o ON o.order_id   = i.order_id AND o.status = 'completed'
    JOIN products p ON p.product_id = i.product_id
    GROUP BY p.product_id, p.product_name, p.category_id
),
ranked AS (                          -- same grain, plus rank and share of category
    SELECT product_id, product_name, category_id, revenue,
           ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY revenue DESC, product_id) AS rn,
           ROUND(100 * revenue / SUM(revenue) OVER (PARTITION BY category_id), 1)        AS pct_of_category
    FROM product_revenue
)
SELECT c.category_name, r.rn AS rank_in_category, r.product_name,
       ROUND(r.revenue, 2) AS revenue, r.pct_of_category
FROM ranked r
JOIN categories c ON c.category_id = r.category_id
WHERE r.rn <= 3
ORDER BY c.category_name, r.rn;
```

```
 category_name | rank_in_category |    product_name     | revenue  | pct_of_category
---------------+------------------+---------------------+----------+-----------------
 Accessories   |                1 | 27in Monitor        | 10440.00 |            56.2
 Accessories   |                2 | Mechanical Keyboard |  2916.00 |            15.7
 Accessories   |                3 | HD Webcam           |  1773.75 |             9.6
 Chairs        |                1 | Ergo Chair          | 11957.00 |            74.1
 Chairs        |                2 | Task Chair          |  4176.00 |            25.9
 Desks         |                1 | Standing Desk       | 14496.00 |            77.1
 Desks         |                2 | Compact Desk        |  4305.00 |            22.9
 Desktops      |                1 | Tower T5            | 20385.00 |            58.5
 Desktops      |                2 | Mini PC M1          | 14467.50 |            41.5
 Laptops       |                1 | Workstation Pro 16  | 49950.00 |            69.5
 Laptops       |                2 | UltraSlim 13        | 18260.00 |            25.4
 Laptops       |                3 | ThinkBook 14        |  3637.50 |             5.1
 Smartphones   |                1 | Pulse A3            | 11450.00 |            49.2
 Smartphones   |                2 | Nova X1 Pro         |  9562.50 |            41.1
 Smartphones   |                3 | Nova X1             |  2280.00 |             9.8
 Stationery    |                1 | Notebook Pack       |   486.60 |            63.6
 Stationery    |                2 | Pen Set             |   278.80 |            36.4
```

Three things to notice:

- **Two windows, one pass.** `rn` ranks within the category; `SUM(revenue) OVER (PARTITION BY category_id)` gives the category total, so each row can show its share without a second aggregation CTE (compare Module 4).
- **The share is computed before the filter.** The 27in Monitor is 56.2% of the *whole* Accessories category, not of the top 3, because the window ran in `ranked` and the `WHERE rn <= 3` came afterwards.
- **Small categories return fewer than 3 rows**, since Chairs only has 2 products. That is correct, not a bug.

### The PostgreSQL shortcut for top 1

When you need only the **single** top row per group, PostgreSQL offers `DISTINCT ON`:

```sql
SELECT DISTINCT ON (category_id) category_id, product_id
FROM product_revenue
ORDER BY category_id, revenue DESC, product_id;
```

It is shorter, but it is PostgreSQL-specific and only works for top 1. Example 6 in [`examples.sql`](examples.sql) proves both techniques return the same 7 rows (`differences = 0`). Use the window version when you need top N, or when the code must run on other databases.

## 5.6 Running totals and frames

Add `ORDER BY` inside `SUM() OVER (...)` and it becomes a **running total**. A **frame** says exactly which rows are included:

```sql
WITH monthly_revenue AS (            -- grain: one row per month (completed orders)
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
)
SELECT month,
       ROUND(revenue, 2) AS revenue,
       ROUND(SUM(revenue) OVER (ORDER BY month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW), 2) AS running_total,
       ROUND(AVG(revenue) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 2)         AS moving_avg_3m
FROM monthly_revenue
ORDER BY month
LIMIT 5;
```

```
   month    | revenue  | running_total | moving_avg_3m
------------+----------+---------------+---------------
 2025-01-01 |  9273.25 |       9273.25 |       9273.25
 2025-02-01 | 10878.35 |      20151.60 |      10075.80
 2025-03-01 | 25668.60 |      45820.20 |      15273.40
 2025-04-01 |  6646.00 |      52466.20 |      14397.65
 2025-05-01 |  1800.00 |      54266.20 |      11371.53
```

Frame vocabulary: `UNBOUNDED PRECEDING` is the start of the partition, `n PRECEDING` is `n` rows back, `CURRENT ROW` is this row. Note the **moving average** in the first two rows averages fewer than three months (10075.80 is the mean of two), so treat the first rows with care in a report.

### The default-frame trap

If you write `ORDER BY` but **no frame**, PostgreSQL uses `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`. With `RANGE`, rows that tie on the `ORDER BY` value are **peers** and all receive the same result. Orders share dates, so the effect is visible:

```sql
WITH running AS (
    SELECT order_id, order_date,
           COUNT(*) OVER (ORDER BY order_date)                                                            AS running_default,
           COUNT(*) OVER (ORDER BY order_date, order_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_rows
    FROM orders
)
SELECT order_id, order_date, running_default, running_rows
FROM running
WHERE order_date BETWEEN '2025-03-10' AND '2025-03-14'
ORDER BY order_date, order_id;
```

```
 order_id | order_date | running_default | running_rows
----------+------------+-----------------+--------------
       17 | 2025-03-12 |              19 |           17
       18 | 2025-03-12 |              19 |           18
       19 | 2025-03-12 |              19 |           19
       20 | 2025-03-13 |              20 |           20
       21 | 2025-03-14 |              21 |           21
```

Three orders on 12 March: the default frame calls all three "19" (peers jump together), while `ROWS` counts them one by one (17, 18, 19). For a running total over **unique** months the two agree, but they silently disagree the moment duplicates appear. **Write the frame explicitly** (`ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`) and add a unique column to the `ORDER BY`.

Also notice the filter on dates sits **outside** the CTE. Had we put `WHERE order_date BETWEEN ...` inside it, the count would have restarted at 1.

## 5.7 `LAG` and `LEAD`: comparing with neighbouring rows

`LAG(x)` returns `x` from the **previous** row in the window; `LEAD(x)` from the **next** one. Both return `NULL` at the edge.

### Month-over-month growth

```sql
WITH monthly_revenue AS (
    SELECT date_trunc('month', o.order_date)::date AS month,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM orders o
    JOIN order_items i ON i.order_id   = o.order_id
    JOIN products    p ON p.product_id = i.product_id
    WHERE o.status = 'completed'
    GROUP BY 1
),
with_prev AS (
    SELECT month, revenue, LAG(revenue) OVER (ORDER BY month) AS prev_revenue
    FROM monthly_revenue
)
SELECT month,
       ROUND(revenue, 2)      AS revenue,
       ROUND(prev_revenue, 2) AS prev_revenue,
       ROUND(100 * (revenue - prev_revenue) / NULLIF(prev_revenue, 0), 1) AS growth_pct
FROM with_prev
ORDER BY month
LIMIT 4;
```

```
   month    | revenue  | prev_revenue | growth_pct
------------+----------+--------------+------------
 2025-01-01 |  9273.25 |              |
 2025-02-01 | 10878.35 |      9273.25 |       17.3
 2025-03-01 | 25668.60 |     10878.35 |      136.0
 2025-04-01 |  6646.00 |     25668.60 |      -74.1
```

- The first month has no previous row, so `prev_revenue` and `growth_pct` are `NULL`. That is honest; do not replace it with 0.
- `NULLIF(prev_revenue, 0)` turns a zero denominator into `NULL`, avoiding a divide-by-zero error.

### The `LAG` trap: previous row is not previous month

`LAG` reads the previous **row**. It equals the previous **month** only if no month is missing. If a month had no completed orders, it would simply not appear, and the next month would be compared with the one **before** the gap, giving a plausible but wrong growth rate. Check contiguity before trusting it:

```sql
SELECT (SELECT COUNT(DISTINCT date_trunc('month', order_date)) FROM orders WHERE status = 'completed') AS months_with_data,
       (SELECT COUNT(*) FROM generate_series(
            (SELECT date_trunc('month', MIN(order_date)) FROM orders WHERE status = 'completed'),
            (SELECT date_trunc('month', MAX(order_date)) FROM orders WHERE status = 'completed'),
            interval '1 month'))                                                                    AS months_expected;
```

```
 months_with_data | months_expected
------------------+-----------------
               18 |              18
```

Both are 18, so this dataset is safe. If they differed, you would build a full calendar and `LEFT JOIN` the revenue to it (Module 8 shows how).

### Per-customer gaps and named windows

`PARTITION BY` makes `LAG` restart for each customer. When the same window is used twice, give it a **name** with the `WINDOW` clause:

```sql
SELECT customer_id, order_id, order_date,
       LAG(order_date) OVER w                AS prev_order_date,
       order_date - LAG(order_date) OVER w   AS days_since_prev
FROM orders
WHERE customer_id = 4
WINDOW w AS (PARTITION BY customer_id ORDER BY order_date, order_id)
ORDER BY order_date, order_id
LIMIT 5;
```

```
 customer_id | order_id | order_date | prev_order_date | days_since_prev
-------------+----------+------------+-----------------+-----------------
           4 |        1 | 2025-01-01 |                 |
           4 |       11 | 2025-02-23 | 2025-01-01      |              53
           4 |       12 | 2025-02-25 | 2025-02-23      |               2
           4 |       22 | 2025-03-16 | 2025-02-25      |              19
           4 |       26 | 2025-04-04 | 2025-03-16      |              19
```

Subtracting two dates gives whole days. The first order has no previous order, so its gap is `NULL`, and `AVG` and `MAX` later ignore it.

## 5.8 Why aggregate in one CTE and window in the next

You *can* write `LAG(SUM(x)) OVER (ORDER BY month)` in a single grouped query, but it mixes two levels of logic. The pattern used throughout this module is cleaner and easier to debug:

1. **CTE 1** aggregates to a clear grain (`monthly_revenue`: one row per month).
2. **CTE 2** adds window columns on that grain (`with_prev`).
3. **Final query** filters, rounds and presents.

This also uses Module 3's habit of inspecting each step on its own.

## 5.9 Quick reference

| Need | Use |
|---|---|
| Number rows, exactly N per group | `ROW_NUMBER()` plus a unique tiebreaker |
| Rank with ties included | `RANK()` or `DENSE_RANK()` |
| Compare with previous or next row | `LAG()` / `LEAD()` |
| Share of group total, keeping detail rows | `SUM(x) OVER (PARTITION BY group)` |
| Running total | `SUM(x) OVER (ORDER BY t ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` |
| Moving average | `AVG(x) OVER (ORDER BY t ROWS BETWEEN n PRECEDING AND CURRENT ROW)` |
| First or last value in a group | `FIRST_VALUE()` / `LAST_VALUE()` (note: with the default frame, `LAST_VALUE` returns the current row's value, so extend the frame to `UNBOUNDED FOLLOWING`) |

Window functions need to sort rows, so on large tables an index that matches the `PARTITION BY` and `ORDER BY` columns can help. Module 13 covers measuring this.

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Window function in `WHERE` | `window functions are not allowed in WHERE` | Compute it in a CTE, filter in the next step |
| `ROW_NUMBER` with no tiebreaker | Results change between runs | Add a unique column last in the window `ORDER BY` |
| Using `RANK` and expecting exactly N rows | More than N rows when ties occur | Use `ROW_NUMBER`, or accept the ties deliberately |
| `ORDER BY` without a frame | Peers share a running value | Write `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` |
| Filtering inside the CTE that holds the window | Running totals and ranks restart or shrink | Filter after the window, in the outer query |
| `LAG` on data with missing periods | Wrong growth rates, no error | Check contiguity, or join to a calendar |
| Dividing by a `LAG` value without `NULLIF` | `division by zero` error | `NULLIF(prev, 0)` |
| Replacing a first-row `NULL` growth with 0 | Misleading "0% growth" | Leave it `NULL` |

## Key takeaways

- A window function adds a computed column **without collapsing rows**.
- Window functions run **after** `WHERE`, so **a CTE is how you filter on them**.
- `ROW_NUMBER` gives exactly N, `RANK` skips after ties, `DENSE_RANK` does not. Add a tiebreaker for repeatable output.
- Top N per group is two steps: rank in a CTE, filter `rn <= N` outside.
- Write frames explicitly; the default `RANGE` frame treats tied rows as peers.
- `LAG` and `LEAD` read neighbouring **rows**, so verify the periods are contiguous.

## Checkpoint

<details>
<summary>1. Why does <code>WHERE ROW_NUMBER() OVER (...) = 1</code> fail, and what is the fix?</summary>

Window functions are evaluated after `WHERE` in the logical order of a query, so `WHERE` cannot reference them. Compute the window in a CTE (or subquery) and filter in the query that reads it.
</details>

<details>
<summary>2. Three customers have 14, 14 and 12 orders. What ranks do <code>RANK</code> and <code>DENSE_RANK</code> assign?</summary>

`RANK` gives 1, 1, 3 (it skips after the tie). `DENSE_RANK` gives 1, 1, 2 (no gap). `ROW_NUMBER` gives 1, 2, 3, with the order of the two tied rows arbitrary unless you add a tiebreaker.
</details>

<details>
<summary>3. A running total uses <code>ORDER BY order_date</code> with no frame, and several orders share a date. What goes wrong?</summary>

The default frame is `RANGE`, so rows with the same date are peers and all receive the same running value, which jumps by several at once. Write `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` and add a unique column to the `ORDER BY`.
</details>

<details>
<summary>4. Why can <code>LAG</code> give a wrong month-over-month figure without any error?</summary>

`LAG` reads the previous row, not the previous month. If a month is missing from the data, the next month is compared with the month before the gap. Check that the months are contiguous, or join to a generated calendar.
</details>

**Next:** do the [exercises](exercises.md), then continue to [Module 6: Data Cleaning & Deduplication](../06-data-cleaning/lesson.md).
