# Module 1 Exercises

Write your answer first, then compare with the tested solution file.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 01-01 | List employees who earn **more than the company average**. Compute the average in a CTE, and show it alongside each row. Sort by salary, highest first. | `employees` | 10 rows; company average is `95000.00` | [`01-01.sql`](01-01.sql) |
| 01-02 | Departments with **more than 3 employees**, with their headcount. Rewrite the nested version below as a CTE. | `employees`, `departments` | 4 rows; HR (exactly 3) must **not** appear | [`01-02.sql`](01-02.sql) |
| 01-03 | Prove a CTE exists for only one statement: use it successfully, then reference it in a second statement and capture the error. | `employees` | First statement returns `9`; second raises `relation "high_earners" does not exist` | [`01-03.sql`](01-03.sql) |

### The nested query for 01-02

```sql
SELECT d.dept_name
FROM departments d
WHERE d.dept_id IN (SELECT dept_id
                    FROM employees
                    GROUP BY dept_id
                    HAVING COUNT(*) > 3);
```

After writing your CTE version, **prove** it matches the original with the `EXCEPT` technique from the lesson (compare the `dept_name` column in both directions).

## Hints

<details>
<summary>01-01</summary>

The CTE returns one row with one column (`AVG(salary)`). Join it to `employees` with `CROSS JOIN`, or use a scalar subquery against the CTE in `WHERE`.
</details>

<details>
<summary>01-02</summary>

Put the `GROUP BY dept_id` with `COUNT(*)` in the CTE, then join to `departments` and filter `headcount > 3` in the main query. Think about which departments an `INNER JOIN` to the CTE excludes automatically (Marketing has no employees).
</details>

<details>
<summary>01-03</summary>

In `psql`, just run the two statements one after another. If you want the file to keep running after the error (for example in CI), wrap the second statement in a `DO` block with an `EXCEPTION WHEN undefined_table THEN ...` handler, as the solution does.
</details>

## Stretch goal

Add a second CTE to 01-01 that computes the **number of employees above average**, and show it as a column. Then ask yourself: is the second CTE needed, or would a window function be simpler? (Window functions arrive in Module 5.)
