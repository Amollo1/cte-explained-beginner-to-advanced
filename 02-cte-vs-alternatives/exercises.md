# Module 2 Exercises

Write your answer first, then compare with the tested solution file.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 02-01 | Find customers with **more orders than the average customer** (average over customers who have ordered; count all statuses). Write it as a **subquery** and as a **CTE**, prove they match, then run `EXPLAIN` on both and compare. | `orders`, `customers` | 6 rows; top customer is Dennis Okeke with 20 orders; average is `4.62` | [`02-01.sql`](02-01.sql) |
| 02-02 | Show each product category's **share of total revenue** (completed orders only), computing the grand total from a CTE. Sort by revenue, highest first. | `orders`, `order_items`, `products`, `categories` | 7 rows; Laptops = `39.0` | [`02-02.sql`](02-02.sql) |
| 02-03 | Build the **same monthly revenue report four ways** (CTE, view, temp table, materialized view), prove all four return identical rows, clean up, then write a short decision note. | `orders`, `order_items`, `products` | 18 months; all three difference counts are `0` | [`02-03.sql`](02-03.sql) |

## Hints

<details>
<summary>02-01</summary>

Count orders per customer in a CTE, then compute the average **of those counts** in a second CTE. For the `EXPLAIN` comparison, count how many times each plan scans `orders`. What do you notice, and why?
</details>

<details>
<summary>02-02</summary>

First CTE: revenue per category. Second CTE: `SUM(revenue)` over the first. The percentage is `100 * revenue / total`. Filter to completed orders in the join to `orders`.
</details>

<details>
<summary>02-03</summary>

Define the view first, then create the temp table and materialized view from it with `SELECT * FROM v_monthly_revenue`. Compare each against the CTE version with `EXCEPT` in **both directions**. Use `DROP ... IF EXISTS` at the top and `DROP` at the bottom so the file can be re-run.
</details>

## Decision note for 02-03

Write 4 to 6 lines in your own words: for a monthly revenue report, when would you pick each container? Then compare with the model answer.

<details>
<summary>Model answer</summary>

| Situation | Choose | Why |
|---|---|---|
| One-off analysis, answered in a single query | CTE | Nothing to create or clean up |
| Many dashboards and queries need the same definition, always current | View | One definition, always up to date |
| A script reuses a heavy result many times and needs an index | Temp table | Stored rows, indexable, disappears with the session |
| Expensive aggregation over large data, read constantly, nightly freshness is fine | Materialized view | Computed once per refresh, instant reads |
</details>

## Stretch goal

Run `EXPLAIN ANALYZE` (not just `EXPLAIN`) on the two versions of 02-01 and compare actual times. On 120 rows the difference is tiny. How would you test whether it matters on a table 100,000 times larger? (Hint: `generate_series` can build one; Module 13 does this properly.)
