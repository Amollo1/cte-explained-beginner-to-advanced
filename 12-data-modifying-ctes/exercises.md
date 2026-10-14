# Module 12 Exercises

> **Every exercise must run inside `BEGIN ... ROLLBACK`** so the practice data is left untouched. The test runner fingerprints every table before and after the run and fails if anything changed. If you break something while experimenting, reload the data with `psql -f data/schema_and_data.sql` (or run the script in pgAdmin).
>
> In pgAdmin, if a statement fails inside a transaction, run `ROLLBACK;` before continuing.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 12-01 | **Archive** the cancelled orders **and their line items** in **one** statement (chained `DELETE ... RETURNING` into `INSERT`). (A) Run it and count. (B) Reconcile against the original counts. (C) Prove it is **atomic**: put a clashing row in the archive first and show that nothing is lost. (D) Confirm the data is back to normal. | `orders`, `order_items`, `orders_archive`, `order_items_archive` | A: `113, 7, 268, 18, 0`. B: `120, 120, 286, 286`. C: `23505` then `120, 286, 0`. D: `120, 286, 0, 0` | [`12-01.sql`](12-01.sql) |
| 12-02 | **Raise with an audit trail.** Give the Data & Analytics department a 5% raise and log each employee's **old and new** salary in `salary_log`, in one statement. (A) Show the log. (B) Reconcile payroll before and after. (C) Confirm it rolled back. | `employees`, `departments`, `salary_log` | A: 7 rows (Farid `160000.00` to `168000.00`). B: `612000.00, 642600.00, 30600.00, 7`. C: `0, 612000.00` | [`12-02.sql`](12-02.sql) |
| 12-03 | **Idempotent upsert.** Load the cleaned, de-duplicated `customers_raw` into `customers_clean` using a CTE pipeline and `ON CONFLICT (email)`. (A) First run. (B) Second run. (C) Show the loaded rows. (D) A **newer** record arrives: refresh with `DO UPDATE ... WHERE newer`, and run it again. (E) Confirm it rolled back. | `customers_raw`, `customers_clean` | A: `12`. B: `0`. C: 12 rows. D: Alice becomes `Alice Mwangi-Otieno`, then no rows. E: `0, 20` | [`12-03.sql`](12-03.sql) |
| 12-04 | **Snapshot rules.** (A) Double employee 30's salary inside a `WITH` and show what the main query sees, what `RETURNING` gives, and what the next statement sees. (B) Show an `INSERT` is invisible to the same statement. (C) Show that nested DML is rejected. (D) Show a sequence jump after an undone insert. (E) Confirm nothing changed. | `employees`, `customers_clean` | A: `42000.00, 84000.00`, then `84000.00`. B: `0, 1`. C: `0A000`. D: `2, 0`. E: `42000.00, 0` | [`12-04.sql`](12-04.sql) |

## Hints

<details>
<summary>12-01</summary>

Four CTEs in this order: `cancelled` (the order ids), `del_items` (`DELETE ... RETURNING` all five columns), `arch_items` (`INSERT ... SELECT` from `del_items`), `del_orders` (`DELETE ... RETURNING`). The main statement is the `INSERT INTO orders_archive ... SELECT ... FROM del_orders`. Capture the original counts in a temporary table before the archive, for the reconciliation. For Part C, first `INSERT` one cancelled order into `orders_archive`, then run the archive through a helper that catches the error and returns `SQLSTATE` (look at `examples.sql` for the `try_sql` helper).
</details>

<details>
<summary>12-02</summary>

`UPDATE employees e SET salary = ROUND(old.salary * 1.05, 2) FROM employees old JOIN departments d ON ... WHERE old.emp_id = e.emp_id AND d.dept_name = 'Data & Analytics' RETURNING e.emp_id, old.salary, e.salary`. Wrap that in a CTE and `INSERT INTO salary_log ... SELECT` from it. Remember `BEGIN;` first and `ROLLBACK;` last. Do not print `log_id`: it comes from a sequence, which is not rolled back.
</details>

<details>
<summary>12-03</summary>

Reuse the Module 6 pipeline as `cleaned`, `valid`, `latest` CTEs, then `INSERT INTO customers_clean ... SELECT ... FROM latest WHERE rn = 1 ON CONFLICT (email) DO NOTHING RETURNING email`, and count the returned rows in the main query. For Part D insert a newer raw record with `loaded_at = '2026-05-01 10:00'` and use `DO UPDATE SET ... WHERE customers_clean.loaded_at < EXCLUDED.loaded_at RETURNING email, full_name`.
</details>

<details>
<summary>12-04</summary>

Part A: a `WITH bumped AS (UPDATE ... RETURNING ...)` and a main query that selects the salary from `employees` **and** from `bumped`. Part C: wrap `SELECT * FROM (WITH d AS (DELETE ... RETURNING 1) SELECT * FROM d) x` in the error-catching helper, and return `LEFT(result, 5)`. Part D: in a `DO` block, call `nextval` before and after an insert that you undo with `RAISE EXCEPTION` inside a nested `BEGIN ... EXCEPTION` block, and store the difference in a temporary table.
</details>

## Stretch goals

1. **Restore from the archive.** Write the reverse statement that moves the archived orders and items back into `orders` and `order_items` **in one statement** (insert parents and children together, since the foreign key is checked at the end). Run archive then restore inside one transaction and confirm `120, 286, 0, 0`. Finish with `ROLLBACK;`.
2. **Same-row conflict.** Run two sibling `UPDATE`s on employee 30 with different salaries and look at the counts and the result. Then explain why you must never rely on it. (Answer: one update changes `1` row and the other `0`; PostgreSQL does not promise which wins.)
3. **Two audit techniques.** Build the 12-02 log using the **snapshot** technique (a sibling `SELECT` CTE) and prove with `EXCEPT` that it gives exactly the same rows as the self-join version.
4. **PostgreSQL 18 only.** If you have version 18, rewrite 12-02 with `RETURNING old.salary, new.salary`. Check what happens on an older version, and why the course files do not use it.
5. **Count inserts and updates.** Extend 12-03 Part D so that one statement reports how many rows were inserted and how many were updated. (This is harder: `RETURNING` does not say which happened. Think about what you could compare.)
