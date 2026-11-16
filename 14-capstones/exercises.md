# Module 14 Exercises: the four capstone projects

Each exercise is a **project brief**. The reference solution for each is in this folder ([`14-01.sql`](14-01.sql) to [`14-04.sql`](14-04.sql)), but **build your own first**, using the acceptance criteria below as your definition of done. Then compare.

> **Safety:** build inside `BEGIN ... ROLLBACK` while you develop (the reference files do), use one **schema per project**, and finish every project with a **self-check table** whose rows all say `passed = true`. When you are happy, copy the file into your own repository, remove the `BEGIN;` and `ROLLBACK;` lines, and run it once to keep the objects.
>
> **Requirements:** PostgreSQL 14 or newer. Project 4's benchmark builds a few hundred thousand rows in a temporary table and takes about a second.

## How to approach any project

1. **Write the business need** in one paragraph before any SQL.
2. **List the tables and state the grain** of each (one row per what?).
3. **Write the self-checks first** (what must be true?), with expected values from an **independent** route.
4. Build in small, named steps. Run the checks after every change.
5. Write the README last, from real output.

## Project 1: Sales analytics mart (reference: [`14-01.sql`](14-01.sql))

**Business need.** Analysts want revenue, orders, categories and customers without rewriting joins each time. Deliver a BI-ready star schema in a schema called `mart`.

**Deliverables**

| Object | Requirement |
|---|---|
| `dim_date` | one row per day from the first to the last order (bounds taken **from the data**) |
| `dim_customer`, `dim_product` | descriptive attributes; the product dimension carries the category **path** and **top-level category** (recursive CTE) |
| `fact_order_line` | grain: one row per order line; gross, discount and net amount |
| `fact_order` | grain: one row per order; shipping fee lives **here** |
| keys and indexes | primary keys, **foreign keys enforced**, indexes on the fact tables' key columns |
| `kpi_monthly` | monthly completed orders and revenue, growth over the previous month, running total (safe against missing months) |
| `kpi_category`, `kpi_customer` | revenue by top-level category with share of total; customers ranked within their country |
| documentation | `COMMENT ON` every table, stating its grain |

**Acceptance criteria** (your self-checks must show all of these as `t`)

| Check | Expected |
|---|---|
| every order line and every order is in the facts | `286` lines, `120` orders |
| every calendar day is present | `546` days |
| completed revenue equals an **independent** total from the base tables | `184254.90` |
| order grain and line grain agree on total net revenue | `268482.40` |
| shipping is counted once per order | `870.00` (not `2110.00`) |
| the category KPI adds up to completed revenue | `184254.90` |
| the monthly KPI has every month, and March 2025 growth | `18` months, `136.0` |
| the running total ends at the completed revenue | `184254.90` |

**Hints**

<details>
<summary>Grains and fan-out</summary>

Build `fact_order_line` straight from `order_items` joined to `orders` and `products`. Build `fact_order` by **summarising the lines first** (one row per order) and then joining that to `orders`, so the shipping fee is never repeated. Check shipping with `SUM(shipping_fee)` on `fact_order` against the base `orders` table.
</details>

<details>
<summary>The calendar and the growth KPI</summary>

`generate_series(first_date::timestamp, last_date::timestamp, interval '1 day')`, with both bounds from `MIN` and `MAX` of `orders.order_date`. For `kpi_monthly`, start from the **distinct months of `dim_date`** and `LEFT JOIN` the monthly revenue, with `COALESCE(..., 0)`, before applying `LAG`.
</details>

<details>
<summary>Enforcing keys</summary>

`ALTER TABLE ... ADD PRIMARY KEY`, then `ADD FOREIGN KEY (...) REFERENCES ...`. If a foreign key fails to create, you have found an orphan row: the database is doing your integrity check for you.
</details>

**Stretch goals:** connect Power BI or Tableau and **reconcile the dashboard total against 184,254.90**; add a `dim_product` attribute that you derive (for example a price band); add a check that fails if any customer's `first_order_date` is earlier than their `signup_date`.

## Project 2: Org-chart explorer (reference: [`14-02.sql`](14-02.sql))

**Business need.** HR wants to see who manages whom, how big each team is and what it costs, and to be warned when the reporting data is broken. Deliver this in a schema called `org`.

**Deliverables**

| Object | Requirement |
|---|---|
| `v_org_chart` | every employee with **depth**, the **chain** of managers, **direct and total reports**, and **team payroll** |
| `v_level_stats` | people, average salary and payroll per level |
| `team(manager)` | a function returning everyone below a manager |
| `v_audit` | employees total, reached from the root, number of roots, unreachable employees |

**Acceptance criteria**

| Check | Expected |
|---|---|
| every employee appears in the chart | `30` |
| the deepest level | `5` |
| the CEO's total reports; the sum of all direct reports | `29` each |
| the CEO's team payroll equals the whole payroll | `2850000.00` |
| the VP Data's team payroll equals the Data and Analytics **department** payroll (a different route to the same number) | `612000.00` |
| `team(6)` | `6` people |
| the audit | `1` root, `0` unreachable |
| after you make employees 14 and 15 each other's manager, the audit shows | `30` total, `28` reached, `2` unreachable |

**Hints**

<details>
<summary>Team size and payroll in one pass</summary>

Build a **closure** (every manager paired with all of their descendants, with a distance), then count and sum per manager. Count direct reports with `COUNT(*) FILTER (WHERE distance = 1)`. Add your own salary to the payroll. Put a depth guard (`distance < 20`) on the closure so a cycle in bad data cannot make it run forever.
</details>

<details>
<summary>The audit</summary>

A traversal from the root can never loop, but it cannot reach rows that are not connected to the root. So **reached < total** is how you detect a detached cycle. Count `employees` with `manager_id IS NULL` for the number of roots.
</details>

**Stretch goals:** a front end (a Power BI hierarchy using the `path_ids` column, or a small web page that renders the tree); add `span of control` (direct reports) to the level statistics; add a check that no manager earns less than someone in their own team.

## Project 3: Data-quality pipeline (reference: [`14-03.sql`](14-03.sql))

**Business need.** Customer records arrive messy and repeatedly. Produce a clean customer table, quarantine unusable rows **with the reason**, log every run, and prove the result with automated checks. Deliver this in a schema called `dq`.

**Write the policy first.** The reference policy: the **latest record per email wins** (a newer record updates the stored row); a **blank name is allowed but reported**; a **missing or malformed email is quarantined**, never dropped silently. If you choose a different policy, write it down and make your checks match it.

**Deliverables**

| Object | Requirement |
|---|---|
| `customer` | clean customers, **email is the primary key** |
| `rejected` | quarantine with the reason and the original raw values |
| `run_log` | one row per run: raw rows, loaded or updated, duplicates seen, newly quarantined |
| `run_pipeline()` | **one statement** (data-modifying CTEs) that cleans, loads, quarantines and logs **atomically** |
| `v_checks` | automated checks with an expected value, an actual value and a `passed` flag |

**Acceptance criteria**

| Check | Expected |
|---|---|
| run 1 (raw, loaded or updated, duplicates, quarantined) | `20, 12, 6, 2` and it **reconciles**: `20 = 12 + 6 + 2` |
| run 2 on unchanged data (the load is **idempotent**) | `20, 0, 6, 0` |
| run 3 after a **newer** record for an existing email arrives | `21, 1, 7, 0`; the stored name is updated |
| the clean table | no duplicate, malformed or missing emails; one customer per distinct valid email |
| the quarantine | `2` rows (one malformed email, one missing email), each with a reason |
| tamper test: insert a bad row **directly** into the clean table | `2` checks fail |

**Hints**

<details>
<summary>The single statement</summary>

Chain the CTEs: `cleaned`, `classified` (with a reject reason), `ranked` (`ROW_NUMBER() ... ORDER BY loaded_at DESC`), then two data-modifying CTEs, `quarantined` (`INSERT ... ON CONFLICT (raw_id) DO NOTHING RETURNING raw_id`) and `loaded` (`INSERT ... ON CONFLICT (email) DO UPDATE ... WHERE existing.loaded_at < EXCLUDED.loaded_at RETURNING email`). The main statement inserts into `run_log` the counts of those CTEs (`SELECT COUNT(*) FROM loaded`, and so on).
</details>

<details>
<summary>Idempotence</summary>

The quarantine has `raw_id` as its primary key with `ON CONFLICT DO NOTHING`, so a second run does not quarantine the same rows again. The upsert's `WHERE` makes the load update only when the incoming record is newer.
</details>

**Stretch goals:** add a **profiling** view (null and blank counts per column of the raw table); make the pipeline also record **which rows were duplicates** in an audit table; add a check that every `rejected.raw_id` still exists in the raw data.

## Project 4: Route planner (reference: [`14-04.sql`](14-04.sql))

**Business need.** List the possible routes between two cities, within an optional distance budget, and know what is impossible. Deliver this in a schema called `routing`.

**Deliverables**

| Object | Requirement |
|---|---|
| `plan_route(from, to, max_km)` | a function returning every **simple** route (no city twice), shortest first, with an optional distance budget |
| `v_shortest` | the shortest distance for every ordered pair of cities |
| benchmark | counts that show how path enumeration **grows** (use a generated ladder graph) |
| a README section called **Limits** | when this approach stops being right, and what to use instead |

**Acceptance criteria**

| Check | Expected |
|---|---|
| Nairobi to Kigali | `2` routes, shortest `1220` km |
| Nairobi to Dar es Salaam within `1000` km | `1` route |
| nothing is reachable from Kigali (no road leaves it) | `0` |
| ordered city pairs; reachable pairs | `72`; `64` |
| the longest shortest route | `2730` km (Arusha to Kigali) |
| no returned route visits a city twice | `0` violations |
| each extra 2 layers of the ladder | multiplies the path count by `4` (`2048, 8192, 32768, 131072` for 12, 14, 16, 18 layers) |

**Hints**

<details>
<summary>The function</summary>

Anchor on the **start node** (not on an edge) and put it in the path array, so a return to it is caught. The recursive step joins `routes` on `origin = w.city` with `WHERE NOT (r.destination = ANY (w.path))`. The optional budget is `AND (p_max_km IS NULL OR w.total_km + r.distance_km <= p_max_km)`. Select the rows where `city = p_to AND hops > 0`.
</details>

<details>
<summary>The all-pairs view</summary>

Cross join the distinct cities with themselves (excluding equal pairs) and take `MIN(total_km)` from `plan_route` in a correlated subquery. Unreachable pairs give `NULL`, so `COUNT(shortest_km)` counts the reachable ones.
</details>

**Stretch goals:** compare the recursive version with **pgRouting** on a larger generated graph; add a `max_hops` parameter; produce a **distance matrix** pivoted so each city is a column.

## Then publish

For each project: write the README from [`projects/README_TEMPLATE.md`](projects/README_TEMPLATE.md) (the four finished READMEs in [`projects/`](projects/) show the level to aim for), run through [`projects/PORTFOLIO_CHECKLIST.md`](projects/PORTFOLIO_CHECKLIST.md), and push. Add the CI badge, keep the **Limitations** section honest, and describe only what you actually built.
