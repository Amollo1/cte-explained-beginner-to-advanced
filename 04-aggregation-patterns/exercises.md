# Module 4 Exercises

Write your answer first, then compare with the tested solution file. For every report, **reconcile** it against an independent total before you trust it.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 04-01 | **Fan-out trap.** In one row, show (a) the true total of `shipping_fee` from `orders`, (b) the total after joining `orders` to `order_items`, and (c) the corrected total using a pre-aggregating CTE. | `orders`, `order_items` | `870.00`, `2110.00`, `870.00` | [`04-01.sql`](04-01.sql) |
| 04-02 | **Revenue per country, completed vs cancelled**, with one column for each, using `FILTER`. Countries with no cancelled orders must show `0.00`. Sort by completed revenue, highest first. | `orders`, `customers`, `order_items`, `products` | 6 rows; Kenya first at `67216.90`; United Kingdom cancelled is `0.00` | [`04-02.sql`](04-02.sql) |
| 04-03 | **Category report**: number of products, units sold and revenue per category (completed orders only). The product count must be correct without using `DISTINCT`. | `products`, `categories`, `orders`, `order_items` | 7 rows; Accessories has `6` products and `193` units | [`04-03.sql`](04-03.sql) |
| 04-04 | **Signup-year cohorts.** For each signup year show: customers, how many ordered, percent who ordered, average days from signup to first order, and how many ordered within 365 days. Customers who never ordered must be included. | `customers`, `orders` | 3 rows (2023, 2024, 2026); 2024 has `11` within 365 days | [`04-04.sql`](04-04.sql) |

## Hints

<details>
<summary>04-01</summary>

Write three subqueries in one `SELECT`. For the CTE, group `order_items` by `order_id` so there is one row per order, then `LEFT JOIN` it to `orders`. Verify your CTE's grain with `COUNT(*) = COUNT(DISTINCT order_id)`.
</details>

<details>
<summary>04-02</summary>

Put the revenue expression in a CTE at the order-line grain (carry `status` and `country` along) so you write it once. Then use `SUM(line_revenue) FILTER (WHERE status = ...)` twice. Wrap each in `COALESCE(..., 0)`. To check your answer, add up the completed column and compare it with `184254.90`.
</details>

<details>
<summary>04-03</summary>

Summarise sales to **one row per product** in a CTE (completed orders only). Then start the final query from `products`, join `categories`, and `LEFT JOIN` the CTE. Because both sides have one row per product, `COUNT(*)` is the product count. Compare your revenue column with the Module 2 category report.
</details>

<details>
<summary>04-04</summary>

Two CTEs: `first_orders` (one row per customer who ordered, `MIN(order_date)`) and `customer_cohorts` (one row per customer, `LEFT JOIN` from `customers`). In the final query, `COUNT(*)` counts customers while `COUNT(first_order_date)` counts those who ordered. `signup_year` comes from `EXTRACT(YEAR FROM signup_date)`. Subtracting two dates gives days.
</details>

## Stretch goals

1. **`DISTINCT` is not a cure.** In the naive category query from the lesson (Example 6), add `SUM(p.unit_price)` per category. Compare it with `SELECT category_id, SUM(unit_price) FROM products GROUP BY 1`. Why can `COUNT(DISTINCT ...)` rescue the product count but not this sum?
2. **Pick a better threshold.** Using the distribution query from the lesson, choose a different cutoff (for example 180 days) and extend 04-04. Which choice tells the clearest story, and why?
3. **Average order value per country.** Compute it at the correct grain (revenue per order, completed only) and compare it with the average line value. Reconcile the all-country figure with the `2247.01` from the lesson.
