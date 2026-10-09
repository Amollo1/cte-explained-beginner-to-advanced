# Module 9 Exercises

Always reconcile hierarchy results (rows reached against rows in the table), and put a depth guard on upward and closure queries.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 09-01 | **Org chart with depth.** List all employees from the CEO down with their level. Then reconcile: employees reached, employees in total, and the maximum depth. | `employees` | 30 rows (levels hold 1, 5, 7, 16, 1 people). Reconcile: `30, 30, 5` | [`09-01.sql`](09-01.sql) |
| 09-02 | **Management chain as text** for every employee, from the CEO down, e.g. `Amina > Brian > Grace > Nia`. | `employees` | 30 rows; Daniel's chain is `Amina > Farid > Mohamed > Zane > Daniel` | [`09-02.sql`](09-02.sql) |
| 09-03 | **(A)** All direct and indirect reports of Farid Rahman (`emp_id` 6), with how many levels below him. **(B)** Headcount for **every** manager: direct and total reports. | `employees` | A: 6 people. B: 14 managers; Amina `5, 29`; Mohamed `4, 5` | [`09-03.sql`](09-03.sql) |
| 09-04 | **Breadcrumb for every category**, e.g. `Electronics > Computers > Laptops`, in tree order. | `categories` | 12 rows; the third is `Electronics > Computers > Laptops` | [`09-04.sql`](09-04.sql) |
| 09-05 | **(A)** Revenue per **top-level** category including all descendants (completed orders), then reconcile against the overall total. **(B)** The roll-up at **every** level. | `categories`, `products`, `order_items`, `orders` | A: Electronics `148555.50`, Office `35699.40`; both reconcile to `184254.90`. B: 12 rows; Computers `106700.00` | [`09-05.sql`](09-05.sql) |
| 09-06 | **The org chart in outline order with indentation** (four spaces per level below the CEO). | `employees` | 30 rows; Daniel is indented 16 spaces and appears right after Zane | [`09-06.sql`](09-06.sql) |

## Hints

<details>
<summary>09-01</summary>

Anchor: `WHERE manager_id IS NULL`. Recursive member: `JOIN org o ON e.manager_id = o.emp_id` with `o.depth + 1`. For the reconciliation, compare `COUNT(*)` of the CTE with `COUNT(*)` of `employees`.
</details>

<details>
<summary>09-02</summary>

Carry a text column: the anchor is `first_name::text`, and each round appends `' > ' || first_name` to the parent's value. (The `::text` cast keeps the anchor and recursive types identical.)
</details>

<details>
<summary>09-03</summary>

Part A: the same recursion with the anchor `WHERE emp_id = 6` and a `level_below` counter; filter `level_below > 0` at the end. Part B: anchor on **every** row that has a manager, keeping `manager_id` and a `distance` that starts at 1; then `COUNT(*) FILTER (WHERE distance = 1)` for direct reports and `COUNT(*)` for the total. Add `WHERE distance < 20` as a safety net.
</details>

<details>
<summary>09-04</summary>

Same template as the org chart: anchor on `parent_id IS NULL`, carry `breadcrumb` as text and `path_ids` as an integer array, and `ORDER BY path_ids`.
</details>

<details>
<summary>09-05</summary>

Part A: carry `root_id` down the tree unchanged (anchor `category_id, category_id`). Summarise revenue to one row per category **before** joining it to the tree. Part B: a closure where every category is its own descendant (anchor `category_id, category_id` from the whole table, recursion via `parent_id`), then `LEFT JOIN` the revenue and `SUM` per ancestor.
</details>

<details>
<summary>09-06</summary>

Reuse 09-01 and 09-02's template with a `path_ids` array. `ORDER BY path_ids`, and prefix each name with `repeat('    ', depth - 1)`.
</details>

## Stretch goals

1. **Audit for broken hierarchies.** Write a query that lists employees **not reachable** from the CEO, plus a check that there is exactly one root. Test it inside a transaction: make employees 14 and 15 each other's managers, confirm it reports `{14,15}`, and `ROLLBACK;`.
2. **Alphabetical siblings.** Outline order currently sorts siblings by `emp_id`. Build a sort key so siblings appear in last-name order (hint: `ROW_NUMBER() OVER (PARTITION BY manager_id ORDER BY last_name)` gives each person a rank among siblings, and the **path of ranks** is an integer array you can sort on).
3. **Product breadcrumbs.** Join `products` to the category breadcrumbs to show, for each product, a path such as `Electronics > Computers > Laptops > ThinkBook 14`. Which products sit under `Electronics > Accessories`, and why does that category have no children?
