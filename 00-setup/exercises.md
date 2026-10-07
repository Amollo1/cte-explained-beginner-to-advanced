# Module 0 Exercises

Write your own answers first (in a scratch file or your SQL client), then compare with the solution files. Each solution is tested in CI against an `.expected` output file.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 00-01 | Write one query that returns the row count of every practice table (11 tables from `departments` to `customers_raw`), sorted by table name. | all | 11 rows; `order_items` = 286 | [`00-01.sql`](00-01.sql) |
| 00-02 | List every employee with their **department name** and **manager name**. The CEO must still appear. | `employees`, `departments` | 30 rows; the CEO's manager shows `(none)` | [`00-02.sql`](00-02.sql) |
| 00-03 | Total revenue per product category for **completed** orders only. `revenue = quantity * unit_price * (1 - discount)`. Sort highest first. | `orders`, `order_items`, `products`, `categories` | 7 rows; first row is `Laptops` at `71847.50` | [`00-03.sql`](00-03.sql) |

## Hints

<details>
<summary>00-01</summary>

Use `UNION ALL` to stack eleven `SELECT 'name', COUNT(*) FROM name` queries. Wrap the stack in a subquery so you can `ORDER BY` the whole result.
</details>

<details>
<summary>00-02</summary>

You need two joins to two different tables, and the second one joins `employees` back to itself under a different alias. Use `LEFT JOIN` for the manager, and `COALESCE` to print a label instead of `NULL`.
</details>

<details>
<summary>00-03</summary>

Put the `status = 'completed'` condition on the `orders` join (or in `WHERE`). Compute revenue per line inside `SUM(...)`. Categories on products are leaf categories, so you are not rolling up to "Electronics" yet; that comes in Module 9.
</details>

## Stretch goal

Without looking at the solution, rewrite 00-03 so it also shows the **number of distinct orders** per category. Then check: does a plain `COUNT(*)` give the same number? Why not? (You will meet this "fan-out" problem formally in Module 4.)
