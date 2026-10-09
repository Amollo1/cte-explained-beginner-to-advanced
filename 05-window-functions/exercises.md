# Module 5 Exercises

Write your answer first, then compare with the tested solution file. Remember: a window function cannot be filtered in `WHERE`, so use a CTE.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 05-01 | **Top 3 products by revenue within each category** (completed orders). Show category, rank, product, revenue and each product's **share of its whole category**. | `orders`, `order_items`, `products`, `categories` | 17 rows; Accessories rank 1 is 27in Monitor, `10440.00`, `56.2` | [`05-01.sql`](05-01.sql) |
| 05-02 | **Cumulative monthly revenue** (completed orders): revenue, running total and cumulative percent of the overall total. Write the frame explicitly. | `orders`, `order_items`, `products` | 18 rows; last running total is `184254.90` and `100.0` | [`05-02.sql`](05-02.sql) |
| 05-03 | **Month-over-month revenue growth percentage** with `LAG`. The first month has no growth figure. | `orders`, `order_items`, `products` | 18 rows; first growth is `NULL`; March 2025 is `136.0` | [`05-03.sql`](05-03.sql) |
| 05-04 | **Days between each customer's consecutive orders** (all statuses). Summarise per customer: number of orders, average gap and longest gap, for customers with at least 2 orders. | `orders`, `customers` | 23 rows; Dennis Okeke first with average gap `28.6` | [`05-04.sql`](05-04.sql) |
| 05-05 | **Two highest-paid employees per department**, with ties handled explicitly. Then **simulate a tie** for 2nd place inside a transaction and compare `ROW_NUMBER`, `RANK` and `DENSE_RANK` for Engineering. | `employees`, `departments` | Part A: 11 rows (Executive has 1). Part B: Grace and Hassan both rank 2 | [`05-05.sql`](05-05.sql) |

## Hints

<details>
<summary>05-01</summary>

Two CTEs: revenue per product, then a ranked step with `ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY revenue DESC, product_id)` and `SUM(revenue) OVER (PARTITION BY category_id)` for the share. Filter `rn <= 3` in the final query, **not** inside the ranking CTE, so the share stays a share of the whole category.
</details>

<details>
<summary>05-02</summary>

First CTE: one row per month. Then `SUM(revenue) OVER (ORDER BY month ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` for the running total and `SUM(revenue) OVER ()` (an empty `OVER`) for the grand total. Check your last row against `184254.90`.
</details>

<details>
<summary>05-03</summary>

Build `monthly_revenue`, then a second CTE with `LAG(revenue) OVER (ORDER BY month)`. Growth is `100 * (revenue - prev) / NULLIF(prev, 0)`. Before trusting it, confirm there are no missing months (the check is in the lesson).
</details>

<details>
<summary>05-04</summary>

CTE 1 (`order_gaps`, one row per order): `order_date - LAG(order_date) OVER (PARTITION BY customer_id ORDER BY order_date, order_id)`. CTE 2: group by customer and keep `HAVING COUNT(*) >= 2`. `AVG` and `MAX` automatically ignore the `NULL` gap on each customer's first order.
</details>

<details>
<summary>05-05</summary>

Part A: `RANK() OVER (PARTITION BY dept_id ORDER BY salary DESC)`, filter `<= 2` in the next step. Part B: `BEGIN;`, `UPDATE employees SET salary = 105000 WHERE emp_id = 8;`, run your comparison query, then `ROLLBACK;`. If your SQL client reports an error inside the transaction, run `ROLLBACK;` before continuing, or later statements will keep failing.
</details>

## Stretch goals

1. **Ties change the row count.** In 05-01, switching `ROW_NUMBER` to `RANK` changes nothing, because no products tie on revenue. Ties are common elsewhere: using the customer order counts from Example 4 in the lesson, how many rows does a "top 2" filter return with `ROW_NUMBER`, with `RANK` and with `DENSE_RANK`? Predict first, then check (answer: 2, 3 and 3). Which customer does `ROW_NUMBER` silently drop, and what decides it?
2. **Smooth the trend.** Add a 3-month moving average column to 05-02. Why do the first two rows use fewer than three months, and how would you show that honestly in a report?
3. **Break `LAG` safely.** Inside a transaction, set the status of one middle month's completed orders to `'cancelled'` (for example September 2025; deleting them would violate the foreign key from `order_items`), then re-run 05-03 and `ROLLBACK`. Which month is October now compared with, and what growth does it show? How would you fix it using a calendar from `generate_series`? (Module 8 covers this properly.) Answer to check: October is compared with **August** and shows `-50.7`.
