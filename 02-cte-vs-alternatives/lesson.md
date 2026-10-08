# Module 2: CTE vs Subquery vs View vs Temp Table

**Level:** Beginner  |  **Time:** about 1.5 hours  |  **Files:** [`examples.sql`](examples.sql) · [`exercises.md`](exercises.md)

## Learning objectives

By the end of this module you can:

- explain when a CTE and a subquery produce the same plan, and when they do not,
- reuse one CTE result several times in a statement and see it computed once,
- choose between a CTE, view, temporary table and materialized view for a given problem,
- name the main trap of each option.

---

## 2.1 Five containers for the same logic

You can package a piece of SQL logic in five ways. They differ in **how long they live**, **whether they store data**, and **who can use them**.

| Container | Lifetime | Stores rows? | Reusable across statements? |
|---|---|---|---|
| Subquery | one statement | no | no |
| **CTE** | one statement | no (may be materialized internally) | no |
| View | permanent definition | no | yes, by anyone with access |
| Temporary table | your session | yes | yes, in your session |
| Materialized view | permanent | yes | yes, but data goes stale |

Module 1 showed that a CTE lives for one statement. This module is about when that is enough, and what to reach for when it is not.

## 2.2 CTE vs subquery

A CTE and a subquery can express the same logic. The difference depends on **how many times the result is used**:

1. **Used once:** since PostgreSQL 12 the CTE is *inlined*, so it is planned exactly like a subquery. Choose on readability.
2. **Used more than once:** the CTE is computed **once** and stored for the duration of the statement. The equivalent subquery logic has to be written, and computed, **each time**.

### Worked example 1: customers above the average order count

Question: *which customers placed more orders than the average customer?* (The average is taken over the 26 customers who have ordered, counting all order statuses.)

**Subquery version.** Notice the `GROUP BY customer_id` count is written twice:

```sql
SELECT oc.customer_id, oc.orders_placed
FROM (SELECT customer_id, COUNT(*) AS orders_placed
      FROM orders
      GROUP BY customer_id) oc
WHERE oc.orders_placed > (SELECT AVG(orders_placed)
                          FROM (SELECT COUNT(*) AS orders_placed
                                FROM orders
                                GROUP BY customer_id) x)
ORDER BY oc.orders_placed DESC, oc.customer_id;
```

**CTE version.** Written once, used twice:

```sql
WITH order_counts AS (
    SELECT customer_id, COUNT(*) AS orders_placed
    FROM orders
    GROUP BY customer_id
),
avg_orders AS (
    SELECT AVG(orders_placed) AS avg_orders
    FROM order_counts
)
SELECT oc.customer_id, oc.orders_placed
FROM order_counts oc
CROSS JOIN avg_orders a
WHERE oc.orders_placed > a.avg_orders
ORDER BY oc.orders_placed DESC, oc.customer_id;
```

Both return the same 6 rows:

```
 customer_id | orders_placed
-------------+---------------
           4 |            20
           2 |            14
           3 |            14
           1 |            12
          12 |             6
          20 |             5
```

Example 3 in [`examples.sql`](examples.sql) proves this with the `EXCEPT` technique from Module 1 (both counts come back `0`).

### Reading the plans

Put `EXPLAIN` in front of each query. The exact numbers differ by machine, and labels such as `$0` differ by PostgreSQL version, but the **shape** is the point.

Subquery version (trimmed):

```
HashAggregate
  Filter: ((count(*))::numeric > $0)
  InitPlan 1 (returns $0)
    ->  Aggregate
          ->  HashAggregate
                ->  Seq Scan on orders orders_1        <-- first scan of orders
  ->  Seq Scan on orders                               <-- second scan of orders
```

CTE version (trimmed):

```
CTE Scan on order_counts oc
  Filter: ((orders_placed)::numeric > $1)
  CTE order_counts
    ->  HashAggregate
          ->  Seq Scan on orders                       <-- ONE scan of orders
  InitPlan 2 (returns $1)
    ->  Aggregate
          ->  CTE Scan on order_counts                 <-- reuses the stored result
```

The subquery version reads `orders` **twice**. The CTE version reads it **once** and scans the stored result a second time. On 120 rows nobody notices; on 120 million rows the difference is real. This is the genuine, defensible performance argument for a CTE: **reuse**, not the `WITH` keyword itself.

### When a plain subquery is the better choice

- A one-off filter: `WHERE x IN (SELECT ...)`, `EXISTS (...)`, or a single scalar value.
- Logic that is already short and used once. Wrapping it in a CTE adds ceremony without adding clarity.

## 2.3 Worked example 2: computing a total once

Question: *what share of total completed-order revenue does each category contribute?* You need revenue per category **and** the grand total, and the grand total is just the sum of the per-category figures.

```sql
WITH category_revenue AS (
    SELECT c.category_name,
           SUM(i.quantity * p.unit_price * (1 - i.discount)) AS revenue
    FROM order_items i
    JOIN orders     o ON o.order_id    = i.order_id AND o.status = 'completed'
    JOIN products   p ON p.product_id  = i.product_id
    JOIN categories c ON c.category_id = p.category_id
    GROUP BY c.category_name
),
grand_total AS (
    SELECT SUM(revenue) AS total_revenue
    FROM category_revenue
)
SELECT cr.category_name,
       ROUND(cr.revenue, 2)                         AS revenue,
       ROUND(100 * cr.revenue / g.total_revenue, 1) AS pct_of_total
FROM category_revenue cr
CROSS JOIN grand_total g
ORDER BY cr.revenue DESC, cr.category_name;
```

```
 category_name | revenue  | pct_of_total
---------------+----------+--------------
 Laptops       | 71847.50 |         39.0
 Desktops      | 34852.50 |         18.9
 Smartphones   | 23292.50 |         12.6
 Desks         | 18801.00 |         10.2
 Accessories   | 18563.00 |         10.1
 Chairs        | 16133.00 |          8.8
 Stationery    |   765.40 |          0.4
```

`category_revenue` is referenced twice (by `grand_total` and by the final query). It contains four joins and an aggregation, and you wrote them once. If a business rule changes (say, include shipped orders), you change **one** line. Example 6 in the examples file shows the `CTE Scan` nodes in the plan.

## 2.4 When one statement is not enough

CTEs vanish when the statement ends. Three alternatives outlive it.

### View: a saved query

```sql
CREATE VIEW v_monthly_revenue AS
SELECT date_trunc('month', o.order_date)::date AS month,
       COUNT(DISTINCT o.order_id)              AS orders,
       ROUND(SUM(i.quantity * p.unit_price * (1 - i.discount)), 2) AS revenue
FROM orders o
JOIN order_items i ON i.order_id   = o.order_id
JOIN products    p ON p.product_id = i.product_id
WHERE o.status = 'completed'
GROUP BY 1;

SELECT * FROM v_monthly_revenue ORDER BY month LIMIT 3;
```

```
   month    | orders | revenue
------------+--------+----------
 2025-01-01 |      2 |  9273.25
 2025-02-01 |      5 | 10878.35
 2025-03-01 |      8 | 25668.60
```

A view stores **no data**, only the query. Each time you select from it, PostgreSQL runs the query against today's data, so it is always current. Any later statement, in any session, can use it (given permissions). Use views to share business logic, give BI tools a stable interface, or hide complexity.

### Temporary table: stored rows, private to your session

```sql
CREATE TEMP TABLE tmp_monthly_revenue AS
SELECT * FROM v_monthly_revenue;

CREATE INDEX ON tmp_monthly_revenue (month);
ANALYZE tmp_monthly_revenue;

SELECT COUNT(*) FROM tmp_monthly_revenue;      -- 18, in a LATER statement
```

This is the key contrast with a CTE: the temp table **survives** into later statements, and it can be **indexed**. It disappears when your session ends. Run `ANALYZE` yourself after loading a large temp table, because autovacuum does not process temporary tables, so the planner would otherwise have no statistics.

Reach for a temp table when a heavy intermediate result is used by **many statements in one script**, or when you need an index on it.

### Materialized view: stored rows that go stale

```sql
CREATE MATERIALIZED VIEW mv_monthly_revenue AS
SELECT * FROM v_monthly_revenue;
```

A materialized view stores the result **permanently**, so reads are fast, but the data is a snapshot. It only changes when you run `REFRESH MATERIALIZED VIEW mv_monthly_revenue;`. Example 9 shows the staleness. Inside a transaction we complete a pending order, then compare:

```
 view_total | matview_total_stale
------------+---------------------
  190070.40 |           184254.90
```

The view sees the change immediately; the materialized view does not. (The transaction is then rolled back, so your data is unchanged.) Use materialized views for **expensive, read-heavy reports** where yesterday's numbers are acceptable, refreshed on a schedule.

## 2.5 Decision guide

Ask these questions in order:

1. **Do I need it only inside this one query?** Use a **CTE** (or a plain subquery if it is tiny and used once).
2. **Do I need the same logic from many queries, always current?** Use a **view**.
3. **Is it a heavy intermediate result I will hit repeatedly in one session or script, perhaps with an index?** Use a **temporary table**.
4. **Is it expensive, read often, and slightly stale data is fine?** Use a **materialized view** with a scheduled refresh.

| | CTE | View | Temp table | Materialized view |
|---|---|---|---|---|
| Always current | yes | yes | no (snapshot) | no (until refreshed) |
| Can be indexed | no | no (index base tables) | yes | yes |
| Survives the statement | no | yes | yes (session) | yes |
| Main trap | recomputed each statement | runs full query every time | forgetting `ANALYZE`; session-private | stale data; needs a refresh job |

## Gotchas

| Gotcha | What happens | What to do |
|---|---|---|
| `SELECT *` inside a view | The column list is **frozen at creation**. Add a column to the table later and the view does not show it (Example 10) | List columns explicitly |
| Assuming a CTE is cached between statements | It is gone after the statement ends | Use a temp table or view |
| Assuming a CTE is faster than a subquery | Same plan when referenced once | Choose for readability; measure with `EXPLAIN ANALYZE` |
| Forgetting `REFRESH` | Reports show old numbers | Schedule it, and show "last refreshed" in reports |
| Creating a permanent view for a one-off question | Clutters the database | Use a CTE |

## Key takeaways

- A CTE used **once** behaves like a subquery. A CTE used **twice or more** is computed once and reused.
- Views are always current but recompute every time. Temp tables and materialized views store rows, with different lifetimes and different staleness.
- Pick the container from the question: how long must it live, who needs it, how fresh must it be?

## Checkpoint

<details>
<summary>1. Your CTE is referenced three times in one query. How many times does PostgreSQL compute it?</summary>

Once. A CTE referenced more than once is materialized by default for the statement, and each reference scans the stored result. (Module 7 shows how to override this with `NOT MATERIALIZED`.)
</details>

<details>
<summary>2. A dashboard needs yesterday's sales totals, queried hundreds of times a day, and slightly old data is fine. Which container?</summary>

A materialized view refreshed on a schedule: the expensive aggregation runs once per refresh, and every dashboard read is a fast lookup.
</details>

<details>
<summary>3. Why might you choose a temp table over a CTE?</summary>

When several separate statements need the same intermediate result, or you need to index it. A CTE disappears after one statement and cannot be indexed.
</details>

**Next:** do the [exercises](exercises.md), then continue to [Module 3: Multiple & Chained CTEs](../03-chained-ctes/lesson.md).
