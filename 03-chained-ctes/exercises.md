# Module 3 Exercises

Write your answer first, then compare with the tested solution file.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 03-01 | **Top 5 customers by revenue** (completed orders) using three chained CTEs: `order_totals`, `customer_totals`, `customer_rank`. Show rank, name, country, number of orders and revenue. | `orders`, `order_items`, `products`, `customers` | 5 rows; rank 1 is Dennis Okeke at `33505.35` | [`03-01.sql`](03-01.sql) |
| 03-02 | **Monthly order count and monthly completed revenue side by side**, built from two independent CTEs joined on month. No month may be missing. | `orders`, `order_items`, `products` | 18 rows; Jan 2025 = 5 orders, `9273.25` | [`03-02.sql`](03-02.sql) |
| 03-03 | **Customers who never ordered.** Use a CTE with an anti-join, then show that `LEFT JOIN ... IS NULL`, `NOT EXISTS` and `NOT IN` all give the same count. | `customers`, `orders` | 4 customers (ids 27 to 30); all three counts equal `4` | [`03-03.sql`](03-03.sql) |

## Hints

<details>
<summary>03-01</summary>

Write down each CTE's grain before coding it. `order_totals` needs a `GROUP BY` on the order; `customer_totals` groups `order_totals` by customer. Use `RANK() OVER (ORDER BY revenue DESC)` for the rank, then filter `revenue_rank <= 5` in the final query. Verify the grain of `order_totals` with `COUNT(*) = COUNT(DISTINCT order_id)`.
</details>

<details>
<summary>03-02</summary>

Build `monthly_orders` from `orders` alone (all statuses) and `monthly_revenue` from the three-table join (completed only). Start the final query from `monthly_orders` and `LEFT JOIN` the revenue, wrapping it in `COALESCE`. Then deliberately switch to `INNER JOIN` and see whether the row count changes. With *completed* revenue it will not, because every month has at least one completed order, but ask yourself what would happen if a month had none.
</details>

<details>
<summary>03-03</summary>

The CTE holds the distinct customers who **do** appear in `orders`. `LEFT JOIN` it from `customers` and keep rows where the CTE's key is `NULL`. For the comparison, write the `NOT EXISTS` and `NOT IN` versions as `COUNT(*)` subqueries in a single `SELECT`.
</details>

## Stretch goals

1. **Rank ties:** change 03-01 to `ROW_NUMBER()` instead of `RANK()`. When would the two give different results?
2. **Break the grain on purpose:** in 03-01, join `order_items` to `orders` *after* summing and add `o.shipping_fee` to the sum. What happens to the numbers, and which CTE would you add to fix it? (This is the opening problem of Module 4.)
3. **NOT IN trap:** add a customer-less order to a scratch copy of `orders` (`customer_id` is `NULL`) and rerun the three anti-join versions inside a transaction you roll back. Which one breaks?
