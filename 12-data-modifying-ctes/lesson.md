# Module 12: Data-Modifying CTEs

**Level:** Advanced  |  **Time:** about 3 hours  |  **Files:** [`examples.sql`](examples.sql) · [`exercises.md`](exercises.md)

> **Safety first.** Until now every query only *read* data. In this module the statements **change** it. Every example and solution here runs inside `BEGIN ... ROLLBACK`, so the practice data is always left exactly as it was, and the test runner now **checks that** (it fingerprints every table before and after the run and fails if anything changed). When you experiment yourself, do the same: start with `BEGIN;`, finish with `ROLLBACK;`. In pgAdmin, if a statement fails inside a transaction, run `ROLLBACK;` before doing anything else.

## Learning objectives

By the end of this module you can:

- use `INSERT`, `UPDATE` and `DELETE` with `RETURNING`, on their own and inside a `WITH` clause,
- **move rows** between tables atomically in a single statement (the archive pattern),
- write an **audit trail** that records old and new values,
- load data with an **idempotent upsert** (`ON CONFLICT`),
- explain the **snapshot rules**: what a statement can and cannot see of its own changes,
- recognise the hazards: sequence gaps, same-row conflicts, nested restrictions.

---

## 12.1 What changes

A **data-modifying CTE** is a `WITH` query whose body is an `INSERT`, `UPDATE` or `DELETE` instead of a `SELECT`. Its result is whatever it hands back through **`RETURNING`**, and the main query (or a later CTE) can use that result.

```sql
WITH removed AS (
    DELETE FROM orders WHERE status = 'cancelled'
    RETURNING order_id, customer_id            -- the rows that were deleted
)
INSERT INTO orders_archive ...                 -- ...become the input of the next step
SELECT ... FROM removed;
```

Why this is useful: it lets you **move** data from one place to another, **log** what you changed, and do several dependent writes as **one atomic statement**, instead of juggling multiple statements and temporary tables. Data-modifying CTEs have existed since PostgreSQL 9.1.

## 12.2 `RETURNING`

`RETURNING` works on all three commands, and returns different rows in each:

| Command | `RETURNING` gives you | Example |
|---|---|---|
| `INSERT` | the rows that were **inserted** (including generated defaults) | `INSERT ... RETURNING email, full_name` |
| `UPDATE` | the rows that were **changed**, with their **new** values | `UPDATE ... RETURNING emp_id, salary AS new_salary` |
| `DELETE` | the rows that were **removed**, as they were | `DELETE ... RETURNING customer_id, customer_name` |

Example, a raise for one employee (inside a transaction that is rolled back):

```sql
BEGIN;
UPDATE employees
SET salary = ROUND(salary * 1.05, 2)
WHERE emp_id = 30
RETURNING emp_id, salary AS new_salary;
ROLLBACK;
```

```
 emp_id | new_salary
--------+------------
     30 |   44100.00
```

Note that for `INSERT ... ON CONFLICT DO NOTHING`, `RETURNING` returns **only the rows that were actually inserted**. Skipped rows return nothing. That is what makes the upsert counts in 12.6 work.

## 12.3 Anatomy and rules

```sql
WITH step_one AS (
    DELETE ... RETURNING ...          -- a data-modifying CTE
),
step_two AS (
    INSERT ... SELECT ... FROM step_one
)
SELECT ... ;                          -- or another INSERT/UPDATE/DELETE as the main statement
```

Five rules that explain almost everything that follows:

| Rule | Consequence |
|---|---|
| A data-modifying CTE **always runs exactly once, to completion**, whether or not anything reads it | an unreferenced `DELETE` still deletes (12.4) |
| Data-modifying statements are allowed **only in the top-level `WITH`** list | not inside a subquery or another CTE (12.7) |
| All statements in the `WITH` list and the main query use **one snapshot** of the data taken before the statement began | none can see the others' changes (12.7) |
| The **order** in which sibling data-modifying statements run is **unspecified** | never depend on one running before another |
| The **only** way to pass a change from one part to another is **`RETURNING`** | design every step to hand its result forward |

## 12.4 Pattern 1: archiving (moving rows)

Goal: move the cancelled orders **and their line items** to archive tables. `order_items` has a foreign key to `orders`, so the items must go as well. Four steps in **one** statement:

```sql
WITH cancelled AS (                                        -- the orders to move
    SELECT order_id FROM orders WHERE status = 'cancelled'
),
del_items AS (                                              -- 1. remove their line items...
    DELETE FROM order_items
    WHERE order_id IN (SELECT order_id FROM cancelled)
    RETURNING item_id, order_id, product_id, quantity, discount
),
arch_items AS (                                             -- 2. ...and file them in the archive
    INSERT INTO order_items_archive (item_id, order_id, product_id, quantity, discount)
    SELECT item_id, order_id, product_id, quantity, discount FROM del_items
),
del_orders AS (                                             -- 3. remove the orders themselves...
    DELETE FROM orders
    WHERE order_id IN (SELECT order_id FROM cancelled)
    RETURNING order_id, customer_id, order_date, status, shipping_fee
)
INSERT INTO orders_archive (order_id, customer_id, order_date, status, shipping_fee)   -- 4. ...and archive them
SELECT order_id, customer_id, order_date, status, shipping_fee FROM del_orders;
```

```
 orders_left | orders_archived | items_left | items_archived | cancelled_left
-------------+-----------------+------------+----------------+----------------
         113 |               7 |        268 |             18 |              0
```

Seven orders and their 18 line items moved. Things worth noticing:

- **The foreign key did not object**, even though the orders and the items are deleted in the same statement and sibling order is unspecified. Foreign keys are checked when the **statement finishes**, not row by row.
- **`arch_items` is never read** by the main query, yet it still runs (rule 1). It is a step in the chain, not an output.
- **Reconcile**: 113 + 7 = 120 orders and 268 + 18 = 286 items, exactly the original counts. Nothing was lost or duplicated.
- **Name your columns.** `INSERT INTO archive SELECT * FROM ...` breaks silently if the two tables ever differ in column order. List the columns.

### Atomicity: all or nothing

Because the whole thing is **one statement**, it succeeds or fails as a unit. Test it by putting a clashing row in the archive first, so the final `INSERT` violates the primary key:

```
 sqlstate_of_failed_archive
----------------------------
 23505

 orders_still_there | items_still_there | items_archived
--------------------+-------------------+----------------
                120 |               286 |              0
```

`23505` is `unique_violation`. The failed statement undid **everything**: all 120 orders and 286 items are still there, and no items were archived, even though the item steps came first. With separate statements outside a transaction, a failure halfway would leave your data half-moved.

## 12.5 Pattern 2: an audit trail

Goal: give the Data & Analytics department a 5% raise and **log the old and new salary** of everyone affected.

The difficulty: after an `UPDATE`, `RETURNING` shows the **new** value. How do you also capture the **old** one?

**Technique 1: join the table to itself.** `UPDATE ... FROM employees old` adds a second reference to the table whose rows still hold the old values, and `RETURNING` may use it:

```sql
WITH raised AS (
    UPDATE employees e
    SET salary = ROUND(old.salary * 1.05, 2)                -- 5% raise
    FROM employees old                                      -- a second reference to the table...
    JOIN departments d ON d.dept_id = old.dept_id
    WHERE old.emp_id = e.emp_id
      AND d.dept_name = 'Data & Analytics'
    RETURNING e.emp_id,
              old.salary AS old_salary,                     -- ...whose rows still hold the OLD salary
              e.salary   AS new_salary
)
INSERT INTO salary_log (emp_id, old_salary, new_salary)
SELECT emp_id, old_salary, new_salary FROM raised;
```

```
 emp_id | old_salary | new_salary
--------+------------+------------
      6 |  160000.00 |  168000.00
     13 |  108000.00 |  113400.00
     26 |   79000.00 |   82950.00
     27 |   88000.00 |   92400.00
     28 |   74000.00 |   77700.00
     29 |   61000.00 |   64050.00
     30 |   42000.00 |   44100.00
```

Reconcile it:

```
 payroll_before | payroll_after | increase | rows_logged
----------------+---------------+----------+-------------
      612000.00 |     642600.00 | 30600.00 |           7
```

5% of 612,000 is 30,600, and seven employees were logged. Only that department was touched: the other 23 employees are unchanged.

**Technique 2: the snapshot.** Because every statement in the list sees the data as it was **before** the statement, a plain `SELECT` CTE shows the old salaries even while a sibling `UPDATE` changes them:

```sql
WITH before AS (
    SELECT emp_id, salary FROM employees WHERE dept_id = 6      -- sees the OLD values
),
raised AS (
    UPDATE employees SET salary = ROUND(salary * 1.05, 2) WHERE dept_id = 6
    RETURNING emp_id, salary AS new_salary
)
INSERT INTO salary_log (emp_id, old_salary, new_salary)
SELECT r.emp_id, b.salary, r.new_salary
FROM raised r JOIN before b ON b.emp_id = r.emp_id;
```

Both techniques give the same log. Technique 1 is more compact; technique 2 makes the snapshot rule visible.

> **PostgreSQL 18 shortcut.** Version 18 lets `RETURNING` name the old and new row directly: `UPDATE ... RETURNING old.salary AS old_salary, new.salary AS new_salary`. On PostgreSQL 17 and earlier that is an error (`missing FROM-clause entry for table "old"`). The course files avoid it so they run on 14 to 18, but it is the cleanest option once you can rely on version 18.

## 12.6 Pattern 3: idempotent loads with an upsert

An **upsert** inserts a row, or does something else if it already exists. The "something else" is decided by `ON CONFLICT`, which needs a unique column or constraint to detect the clash (`customers_clean.email` is `UNIQUE`).

The source of the load is the cleaning pipeline from Module 6, written as CTEs: standardise, keep valid emails, keep the newest record per email.

```sql
WITH cleaned AS ( ... ),                 -- grain: one row per raw row
valid AS ( ... ),                        -- rows with a usable email
latest AS (                              -- the newest record per email
    SELECT full_name, email, loaded_at,
           ROW_NUMBER() OVER (PARTITION BY email ORDER BY loaded_at DESC, raw_id DESC) AS rn
    FROM valid
),
inserted AS (
    INSERT INTO customers_clean (full_name, email, loaded_at)
    SELECT full_name, email, loaded_at FROM latest WHERE rn = 1
    ON CONFLICT (email) DO NOTHING                          -- already there? skip it
    RETURNING email
)
SELECT COUNT(*) AS inserted_rows FROM inserted;
```

Run it **twice**:

```
 inserted_rows           inserted_rows
---------------   then  ---------------
            12                        0
```

The first run inserts 12 customers; the second inserts none. That is **idempotence**: running the load again is harmless, so a retry after a failure cannot create duplicates.

**`DO UPDATE`** is the alternative when an existing row should be refreshed. Add a `WHERE` so it only changes when the incoming data is **newer**:

```sql
    ON CONFLICT (email) DO UPDATE
        SET full_name = EXCLUDED.full_name,
            loaded_at = EXCLUDED.loaded_at
        WHERE customers_clean.loaded_at < EXCLUDED.loaded_at
    RETURNING email, full_name
```

`EXCLUDED` means "the row I was trying to insert". When a newer record for `alice.mwangi@example.com` arrives, exactly one row is updated:

```
          email           |     full_name
--------------------------+--------------------
 alice.mwangi@example.com | Alice Mwangi-Otieno
```

Running the same statement again returns **no rows**, because nothing is newer any more.

## 12.7 The snapshot rules (the subtle part)

Every statement in the `WITH` list, and the main query, sees the data **as it was before the statement began**. Changes reach the rest of the statement **only through `RETURNING`**.

**An update is invisible to the main query.** Employee 30 earns 42,000, and we double it:

```sql
WITH bumped AS (
    UPDATE employees SET salary = salary * 2 WHERE emp_id = 30
    RETURNING emp_id, salary AS new_salary
)
SELECT (SELECT salary FROM employees WHERE emp_id = 30) AS salary_seen_by_main_query,
       (SELECT new_salary FROM bumped)                  AS salary_from_returning;
```

```
 salary_seen_by_main_query | salary_from_returning
---------------------------+-----------------------
                  42000.00 |              84000.00
```

The main query reads the table and still sees 42,000; the doubled value arrives only through `RETURNING`. The **next** statement sees 84,000 (until we roll back).

**An insert is invisible too:**

```
 rows_seen_in_the_table | rows_returned
------------------------+---------------
                      0 |             1
```

**Two siblings changing the same row** is a trap. Of two `UPDATE`s on the same row in one statement, only **one** takes effect, and PostgreSQL does not say which (in our test the first one won, `1` row changed against `0`). Never design for it.

**Data-modifying statements must be at the top level.** Nesting one inside a subquery is rejected:

```
 sqlstate | message
----------+--------------------------------------------------------------------------
 0A000    | WITH clause containing a data-modifying statement must be at the top level
```

**What follows from these rules:** if step B must **see the effect of step A**, you cannot do both in one statement. Use **separate statements inside one transaction**, where each statement sees everything committed or done before it.

## 12.8 Hazards

| Hazard | What happens | What to do |
|---|---|---|
| **Sequences are not rolled back** | An undone insert still consumes an id. After an insert that was rolled back, the next `nextval` jumped by **2** instead of 1 | Never expect gap-free ids from `SERIAL` or identity columns |
| **`EXPLAIN ANALYZE` executes DML** | The change really happens | Wrap in `BEGIN ... ROLLBACK` (Module 7's warning) |
| **Locks** | Rows you change are locked until the transaction ends | Keep transactions short; do not leave one open |
| **A failed statement inside a transaction** | The transaction is aborted; later statements fail | Run `ROLLBACK;` (pgAdmin users: this is the usual surprise) |
| **Triggers** | Triggers on the target tables still fire | Remember side effects when testing |
| **`INSERT ... SELECT *`** | Breaks silently if column order differs | Always list the columns |

## 12.9 When to use data-modifying CTEs

| Use one when... | Use separate statements in a transaction when... |
|---|---|
| a step needs the **rows another step changed** (moving, logging) | a step needs to **see the effect** of an earlier step |
| you want it **atomic and in one round trip** | the logic has branches, loops or several dependent phases |
| the steps are a clear **chain** of `RETURNING` outputs | you must control the **order** of operations |

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Experimenting without `BEGIN ... ROLLBACK` | Practice data really changed | Always wrap; reload with `data/schema_and_data.sql` if needed |
| Expecting the main query to see a sibling's change | Old values, or zero rows | Use `RETURNING`, or separate statements |
| Relying on the order of sibling DML | Intermittent, unpredictable results | Chain through `RETURNING` instead |
| Two siblings updating the same row | Only one takes effect, no error | Combine into a single update |
| Deleting a parent without its children | Foreign-key error (and the whole statement fails) | Delete or move the children in the same statement |
| `SELECT *` into an archive table | Wrong columns after a schema change | List the columns |
| Forgetting that `ON CONFLICT DO NOTHING` returns only inserted rows | Counts look "wrong" on a re-run | That is the idempotence signal: `0` on the second run |
| Nesting DML inside a subquery | `0A000 ... must be at the top level` | Move it to the top-level `WITH` |
| Expecting contiguous ids after a rollback | Gaps in a serial column | Treat ids as unique, not sequential |

## Key takeaways

- A **data-modifying CTE** wraps `INSERT`/`UPDATE`/`DELETE` and passes its result on through **`RETURNING`**.
- It runs **exactly once**, even if unreferenced, and the **whole statement is atomic**: it fully succeeds or leaves no trace.
- **Archive** by chaining `DELETE ... RETURNING` into `INSERT`; foreign keys are checked at the end of the statement.
- **Audit** an update by capturing the old values (a self-join, or the shared snapshot).
- **Upsert** with `ON CONFLICT`: `DO NOTHING` makes a load idempotent; `DO UPDATE ... WHERE newer` refreshes only when needed.
- Everything in the statement shares **one snapshot**: changes are visible **only** through `RETURNING`, and the order of siblings is **unspecified**.
- **Always experiment inside `BEGIN ... ROLLBACK`.** The test runner checks that the practice data is unchanged.

## Checkpoint

<details>
<summary>1. A <code>WITH</code> list contains a <code>DELETE</code> that the main query never reads. Does the delete happen?</summary>

Yes. A data-modifying CTE always runs exactly once, whether or not anything references it.
</details>

<details>
<summary>2. You archive orders and their items in one statement and the final insert fails. What state is the data left in, and why?</summary>

Completely unchanged: nothing was deleted and nothing was archived. The whole statement is atomic, so a failure in any part undoes all of it.
</details>

<details>
<summary>3. After <code>UPDATE ... RETURNING salary</code> you need the <em>old</em> salary too. Give two ways.</summary>

Join the table to itself in the `UPDATE` (`FROM employees old ... RETURNING old.salary`), or read the old values in a sibling `SELECT` CTE, which sees the pre-statement snapshot. (PostgreSQL 18 also offers `RETURNING old.salary, new.salary`.)
</details>

<details>
<summary>4. Why does a second run of the upsert with <code>ON CONFLICT DO NOTHING</code> report 0 inserted rows, and why is that good?</summary>

The rows already exist, so every attempted insert is skipped and `RETURNING` returns only inserted rows, so the count is 0. The load is idempotent: running it again changes nothing, so a retry is safe.
</details>

<details>
<summary>5. Step B of your process must read rows that step A just inserted. Can both be in one <code>WITH</code> statement?</summary>

No. All parts share one snapshot taken before the statement, so B cannot see A's inserts except through `RETURNING`. Put them in separate statements inside one transaction.
</details>

**Next:** do the [exercises](exercises.md), then continue to Module 13: Performance, Best Practices & Anti-Patterns *(coming soon)*.
