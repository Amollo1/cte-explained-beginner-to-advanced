# Module 4: CTEs for Aggregation & Joins

**Level:** Intermediate  |  **Time:** about 2.5 hours  |  **Files:** [`examples.sql`](examples.sql) · [`exercises.md`](exercises.md)

## Learning objectives

By the end of this module you can:

- explain **fan-out** (join row multiplication) and spot it before it corrupts a report,
- fix it by **summarising to the join grain first**, and explain why `SUM(DISTINCT)` is not a fix,
- use conditional aggregation (`FILTER` and `CASE`) to build pivot-style reports,
- **reconcile** any report against an independent control total,
- build a cohort report, and choose a threshold from the data instead of guessing,
- avoid averaging at the wrong grain.

---

## 4.1 The core rule: a join multiplies rows

When you join a "one" side to a "many" side, each "one" row is **repeated once per matching "many" row**.

| Relationship | Example | Effect of joining |
|---|---|---|
| one-to-one | `employees` to a profile row | rows unchanged |
| one-to-many | `orders` to `order_items` | each order row repeats once per line item |
| many-to-many | `orders` to products via `order_items` | repetition from both directions |

Every number in your data **lives at a grain**. Shipping fee lives at the **order** grain. Line revenue lives at the **order line** grain. The rule that prevents most wrong numbers in analytics:

> **Only SUM a measure at the grain where it lives.** If a join changes the grain, summarise first, or you are summing repeated values.

(Module 3 introduced writing the grain next to each CTE. This module shows what it protects you from.)

## 4.2 The fan-out trap

`orders` has one row per order, and `shipping_fee` is a column on it. Here is a real order from the practice data, and what it looks like after joining to `order_items`:

```
 order_id | shipping_fee | item_id | product_id | quantity
----------+--------------+---------+------------+----------
        4 |        15.00 |      11 |         11 |        2
        4 |        15.00 |      12 |          1 |        1
        4 |        15.00 |      13 |         16 |        3
        4 |        15.00 |      14 |         20 |        3
```

Order 4 has **one** shipping fee of 15, but after the join it appears on **four** rows. `SUM(shipping_fee)` now counts it as 60. Do that for every order:

```sql
SELECT (SELECT SUM(shipping_fee) FROM orders)                              AS true_shipping_total,
       (SELECT SUM(o.shipping_fee)
        FROM orders o JOIN order_items i ON i.order_id = o.order_id)       AS shipping_after_join,
       (SELECT COUNT(*) FROM orders)                                       AS order_rows,
       (SELECT COUNT(*)
        FROM orders o JOIN order_items i ON i.order_id = o.order_id)       AS joined_rows;
```

```
 true_shipping_total | shipping_after_join | order_rows | joined_rows
---------------------+---------------------+------------+-------------
              870.00 |             2110.00 |        120 |         286
```

The report overstates shipping by about **143%**, and **nothing errors**. The number is plausible, formatted correctly, and wrong. This is why fan-out is so dangerous: you only find it by checking.

## 4.3 Fixes that are not fixes

**`SUM(DISTINCT shipping_fee)`** looks tempting. It does not deduplicate *orders*; it deduplicates *values*:

```sql
SELECT SUM(DISTINCT o.shipping_fee) AS sum_distinct_is_not_a_fix
FROM orders o JOIN order_items i ON i.order_id = o.order_id;
```

```
 sum_distinct_is_not_a_fix
---------------------------
                     30.00
```

It adds each *distinct fee value* once: 0 + 5 + 10 + 15 = 30. Two different orders with the same fee collapse into one. It would be wrong on any data.

**`COUNT(DISTINCT key)`** is a legitimate way to count parents (you will use it), but it does nothing for **sums** and **averages** of parent-level measures.

## 4.4 The right fix: summarise to the join grain, then join

Collapse the many side to **one row per order** in a CTE, then join. Now each order matches exactly one row, and nothing repeats:

```sql
WITH order_item_totals AS (          -- grain: one row per order
    SELECT i.order_id,
           SUM(i.quantity)                                    AS units,
           SUM(i.quantity * p.unit_price * (1 - i.discount))  AS items_revenue
    FROM order_items i
    JOIN products p ON p.product_id = i.product_id
    GROUP BY i.order_id
)
SELECT COUNT(*)                       AS orders,
       SUM(o.shipping_fee)            AS shipping_total,
       SUM(t.units)                   AS units,
       ROUND(SUM(t.items_revenue), 2) AS items_revenue
FROM orders o
LEFT JOIN order_item_totals t ON t.order_id = o.order_id;
```

```
 orders | shipping_total | units | items_revenue
--------+----------------+-------+---------------
    120 |         870.00 |   872 |     268482.40
```

`shipping_total` is now the true 870.00. Two details:

- The CTE has **one row per order**, so the join cannot multiply anything. (Module 3's check `COUNT(*) = COUNT(DISTINCT order_id)` proves it.)
- It is a `LEFT JOIN` from `orders`, so an order with no items could never drop out of the shipping total.

**Pattern: aggregate, then join.** Whenever a report mixes measures from different grains, give each grain its own CTE and join them on the shared key.

## 4.5 Summing safely at the right grain

The trap only affects measures that live on the **parent** side. A measure that lives on the **line** can be summed freely over a line-level join, because each line appears exactly once. So for line revenue, the safe move is to compute the expression **once**, at the line grain:

```sql
WITH order_lines AS (                -- grain: one row per order line
    SELECT o.order_id, o.status, c.country,
           i.quantity * p.unit_price * (1 - i.discount) AS line_revenue
    FROM orders o
    JOIN customers   c ON c.customer_id = o.customer_id
    JOIN order_items i ON i.order_id    = o.order_id
    JOIN products    p ON p.product_id  = i.product_id
)
SELECT country,
       ROUND(SUM(line_revenue) FILTER (WHERE status = 'completed'), 2)               AS completed_filter,
       ROUND(SUM(CASE WHEN status = 'completed' THEN line_revenue END), 2)           AS completed_case,
       ROUND(COALESCE(SUM(line_revenue) FILTER (WHERE status = 'cancelled'), 0), 2)  AS cancelled
FROM order_lines
GROUP BY country
ORDER BY country;
```

```
    country     | completed_filter | completed_case | cancelled
----------------+------------------+----------------+-----------
 Germany        |         13961.75 |       13961.75 |   3347.50
 Kenya          |         67216.90 |       67216.90 |   2356.00
 Tanzania       |         46951.85 |       46951.85 |   3352.00
 Uganda         |         14329.60 |       14329.60 |    480.00
 United Kingdom |          9860.50 |        9860.50 |      0.00
 United States  |         31934.30 |       31934.30 |   5280.80
```

### Conditional aggregation: `FILTER` vs `CASE`

Both produce a "pivot-style" report in a single pass, with one column per condition:

| | Syntax | Notes |
|---|---|---|
| `FILTER` | `SUM(x) FILTER (WHERE status = 'completed')` | Clearer; standard SQL; works in PostgreSQL |
| `CASE` | `SUM(CASE WHEN status = 'completed' THEN x END)` | Works in every database; more verbose |

The two columns above are identical. Prefer `FILTER` in PostgreSQL, and know `CASE` because you will meet it in other systems.

### Watch for `NULL` from an empty filter

If **no rows** pass a `FILTER`, `SUM` returns `NULL`, not 0. The United Kingdom has no cancelled orders, so without `COALESCE(..., 0)` its cancelled cell would be blank. Wrap conditional sums in `COALESCE` whenever a zero is meaningful.

## 4.6 Reconcile every report

Fan-out errors are silent, so build the habit of **reconciling**: compare a total from your report with a total from an independent, simpler query.

```sql
WITH order_lines AS (
    SELECT o.status, c.country,
           i.quantity * p.unit_price * (1 - i.discount) AS line_revenue
    FROM orders o
    JOIN customers   c ON c.customer_id = o.customer_id
    JOIN order_items i ON i.order_id    = o.order_id
    JOIN products    p ON p.product_id  = i.product_id
),
by_country AS (
    SELECT country, SUM(line_revenue) AS completed
    FROM order_lines
    WHERE status = 'completed'
    GROUP BY country
)
SELECT ROUND((SELECT SUM(completed) FROM by_country), 2) AS sum_of_countries,
       ROUND((SELECT SUM(i.quantity * p.unit_price * (1 - i.discount))
              FROM orders o
              JOIN order_items i ON i.order_id   = o.order_id
              JOIN products    p ON p.product_id = i.product_id
              WHERE o.status = 'completed'), 2)               AS control_total;
```

```
 sum_of_countries | control_total
------------------+---------------
        184254.90 |     184254.90
```

They match. If they ever differ, you have a grain bug, and you know it **before** anyone sees the report. The same total also appears in Module 2's category-share report, which is another way to cross-check.

## 4.7 Two grains in one report

Question: *for each category, how many products, how many units sold, and how much revenue?* Products and sales are different grains.

**The naive attempt** joins everything and groups:

```sql
SELECT c.category_name,
       COUNT(*)                     AS products_wrong,
       COUNT(DISTINCT p.product_id) AS products_distinct_band_aid
FROM categories c
JOIN products    p ON p.category_id = c.category_id
JOIN order_items i ON i.product_id  = p.product_id
JOIN orders      o ON o.order_id    = i.order_id AND o.status = 'completed'
GROUP BY c.category_name
ORDER BY c.category_name;
```

```
 category_name | products_wrong | products_distinct_band_aid
---------------+----------------+----------------------------
 Accessories   |             62 |                          6
 Chairs        |             25 |                          2
 Desks         |             17 |                          2
 Desktops      |             20 |                          2
 Laptops       |             27 |                          3
 Smartphones   |             19 |                          3
 Stationery    |             21 |                          2
```

`COUNT(*)` counts **joined rows** (one per sale line), so Accessories "has 62 products" when it has 6. `COUNT(DISTINCT p.product_id)` repairs *that one count*, but any other product-level measure in the same query (say `SUM(p.unit_price)`) would still be inflated. Patching each column with `DISTINCT` is fragile.

Notice what is **not** broken: line revenue. It lives at the line grain, so summing it over a line-level join is correct. Only the **parent-grain** columns (the product count) are corrupted.

**The robust version** summarises sales to the **product** grain first:

```sql
WITH product_sales AS (              -- grain: one row per product (completed orders only)
    SELECT i.product_id,
           SUM(i.quantity)                                    AS units_sold,
           SUM(i.quantity * p.unit_price * (1 - i.discount))  AS revenue
    FROM order_items i
    JOIN orders   o ON o.order_id   = i.order_id AND o.status = 'completed'
    JOIN products p ON p.product_id = i.product_id
    GROUP BY i.product_id
)
SELECT c.category_name,
       COUNT(*)                                AS products,
       COALESCE(SUM(ps.units_sold), 0)         AS units_sold,
       ROUND(COALESCE(SUM(ps.revenue), 0), 2)  AS revenue
FROM products p
JOIN categories c ON c.category_id = p.category_id
LEFT JOIN product_sales ps ON ps.product_id = p.product_id
GROUP BY c.category_name
ORDER BY revenue DESC, c.category_name;
```

```
 category_name | products | units_sold | revenue
---------------+----------+------------+----------
 Laptops       |        3 |         51 | 71847.50
 Desktops      |        2 |         56 | 34852.50
 Smartphones   |        3 |         63 | 23292.50
 Desks         |        2 |         61 | 18801.00
 Accessories   |        6 |        193 | 18563.00
 Chairs        |        2 |         92 | 16133.00
 Stationery    |        2 |         77 | 765.40
```

Now `products` and `product_sales` both have **one row per product**, so `COUNT(*)` genuinely counts products. The `LEFT JOIN` from `products` also means a product with no sales would still appear (with 0 units), which an `INNER JOIN` would silently remove. The revenue column matches Module 2 exactly.

## 4.8 Cohort reports

A **cohort** groups customers by something they share at the start (here, signup year) and tracks what they do afterwards. Question: *for each signup year, how many customers ordered, and how quickly?*

### Choose thresholds from the data

A natural first question is "how many ordered within 30 days of signing up?" Before building it, check the distribution:

```sql
WITH first_orders AS (
    SELECT customer_id, MIN(order_date) AS first_order_date
    FROM orders GROUP BY customer_id
)
SELECT MIN(f.first_order_date - c.signup_date)                           AS min_days,
       ROUND(AVG(f.first_order_date - c.signup_date))                    AS avg_days,
       MAX(f.first_order_date - c.signup_date)                           AS max_days,
       COUNT(*) FILTER (WHERE f.first_order_date - c.signup_date <= 30)  AS within_30_days,
       COUNT(*) FILTER (WHERE f.first_order_date - c.signup_date <= 365) AS within_365_days
FROM customers c
JOIN first_orders f ON f.customer_id = c.customer_id;
```

```
 min_days | avg_days | max_days | within_30_days | within_365_days
----------+----------+----------+----------------+-----------------
       59 |      467 |      960 |              0 |              11
```

The fastest customer took **59 days**. A "within 30 days" report would show zero in every row, which looks like a result but carries no information. (In this dataset all orders are from 2025 onwards while customers signed up in 2023 and 2024.) Always ask: *can my data answer this question at this threshold?* We use 365 days instead.

### The report

```sql
WITH first_orders AS (               -- grain: one row per customer who has ordered
    SELECT customer_id, MIN(order_date) AS first_order_date
    FROM orders GROUP BY customer_id
),
customer_cohorts AS (                -- grain: one row per customer
    SELECT c.customer_id,
           EXTRACT(YEAR FROM c.signup_date)::int AS signup_year,
           f.first_order_date,
           f.first_order_date - c.signup_date    AS days_to_first_order
    FROM customers c
    LEFT JOIN first_orders f ON f.customer_id = c.customer_id
)
SELECT signup_year,
       COUNT(*)                                              AS customers,
       COUNT(first_order_date)                               AS ordered,
       ROUND(100.0 * COUNT(first_order_date) / COUNT(*), 1)  AS pct_ordered,
       ROUND(AVG(days_to_first_order))                       AS avg_days_to_first_order,
       COUNT(*) FILTER (WHERE days_to_first_order <= 365)    AS ordered_within_365_days
FROM customer_cohorts
GROUP BY signup_year
ORDER BY signup_year;
```

```
 signup_year | customers | ordered | pct_ordered | avg_days_to_first_order | ordered_within_365_days
-------------+-----------+---------+-------------+-------------------------+-------------------------
        2023 |        12 |      12 |       100.0 |                     705 |                       0
        2024 |        14 |      14 |       100.0 |                     263 |                      11
        2026 |         4 |       0 |         0.0 |                         |                       0
```

Read it: the 2023 cohort took on average almost two years to place a first order, none within a year; the 2024 cohort was far faster, with 11 of 14 inside a year; the 2026 signups have not ordered yet.

Techniques worth noticing:

- **`LEFT JOIN` from `customers`** keeps the four customers who never ordered. An `INNER JOIN` would erase the entire 2026 cohort from the report.
- **`COUNT(*)` vs `COUNT(first_order_date)`**: `COUNT(*)` counts every customer; `COUNT(column)` counts only non-`NULL` values, so it counts those who ordered.
- **`AVG` ignores `NULL`s**, so the 2026 average is `NULL` (nobody to average), shown as blank.
- **`date - date` returns whole days** in PostgreSQL.

## 4.9 Averages at the wrong grain

"Average order value" means revenue **per order**. Averaging over line items answers a different question:

```sql
SELECT (SELECT ROUND(AVG(i.quantity * p.unit_price * (1 - i.discount)), 2)
        FROM orders o
        JOIN order_items i ON i.order_id   = o.order_id
        JOIN products    p ON p.product_id = i.product_id
        WHERE o.status = 'completed')                                  AS avg_line_value_wrong,
       (SELECT ROUND(SUM(i.quantity * p.unit_price * (1 - i.discount))
                     / COUNT(DISTINCT o.order_id), 2)
        FROM orders o
        JOIN order_items i ON i.order_id   = o.order_id
        JOIN products    p ON p.product_id = i.product_id
        WHERE o.status = 'completed')                                  AS avg_order_value_right;
```

```
 avg_line_value_wrong | avg_order_value_right
----------------------+-----------------------
               964.69 |               2247.01
```

The "wrong" figure is **less than half** the right one, because orders have several lines. Before averaging anything, finish the sentence *"the average ___ per ___"*. The second blank is your grain.

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Summing a parent-level column (`shipping_fee`) after joining to a child table | Totals far too high, no error | Summarise the child table to the parent grain in a CTE, then join |
| `SUM(DISTINCT amount)` as a deduplication shortcut | Wrong, and data-dependent | Never use it to fix fan-out; pre-aggregate |
| `COUNT(*)` after joining a parent to a child | Counts child rows | Count the key from a one-row-per-parent CTE, or `COUNT(DISTINCT key)` for counts only |
| `INNER JOIN` to a summary CTE | Parents with no children vanish | `LEFT JOIN` from the parent side |
| Conditional `SUM` with no `COALESCE` | Blank cells instead of 0 | `COALESCE(SUM(...) FILTER (...), 0)` |
| Averaging at the line grain | Average is too low | Decide "average X per Y" first, then divide at grain Y |
| Picking a threshold without looking at the data | Report is all zeros or all 100% | Inspect the distribution first |
| Shipping a report without reconciling | Silent wrong numbers | Compare a total with an independent control total |

## Key takeaways

- A join to a "many" side **repeats** the "one" side. Summing a parent-level measure afterwards overcounts, silently.
- **Aggregate, then join:** give each grain its own CTE, and join on the shared key.
- `SUM(DISTINCT)` deduplicates values, not rows. It is never the fix.
- Use `FILTER` (or `CASE`) for one-pass conditional totals, and `COALESCE` for empty groups.
- **Reconcile** every report against an independent control total.
- Choose thresholds from the data, and define "average X per Y" before averaging.

## Checkpoint

<details>
<summary>1. A report joins <code>orders</code> to <code>order_items</code> and sums <code>shipping_fee</code>. Why is the total wrong?</summary>

Each order row is repeated once per line item, so its shipping fee is counted once per line. Summarise the items to one row per order first (or sum shipping from `orders` alone), then join.
</details>

<details>
<summary>2. Why does <code>SUM(DISTINCT shipping_fee)</code> return 30.00 here, and why is it not a fix?</summary>

It sums the distinct fee **values** (0, 5, 10, 15), not one fee per order. Two orders with the same fee collapse into one, so the result is unrelated to the real total.
</details>

<details>
<summary>3. Which measures are safe to SUM after a join to <code>order_items</code>: <code>orders.shipping_fee</code> or line revenue?</summary>

Line revenue, because it lives at the order-line grain and each line appears exactly once. `shipping_fee` lives at the order grain and is repeated per line.
</details>

<details>
<summary>4. How do you know a report built from several joins is trustworthy?</summary>

Reconcile it: compare a total from the report with the same total from a simple, independent query. A mismatch signals a grain bug.
</details>

**Next:** do the [exercises](exercises.md). Module 5 (CTEs + Window Functions) is coming soon.
