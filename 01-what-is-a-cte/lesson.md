# Module 1: What Is a CTE?

**Level:** Beginner  |  **Time:** about 1.5 hours  |  **Files:** [`examples.sql`](examples.sql) · [`exercises.md`](exercises.md)

## Learning objectives

By the end of this module you can:

- define a CTE and explain why it exists,
- write a query with the `WITH` clause, with and without a column list,
- turn a nested subquery into named, top-to-bottom steps,
- prove a refactor returns identical results,
- explain a CTE's scope and the table-shadowing gotcha.

---

## 1.1 Definition

A **Common Table Expression (CTE)** is a **named, temporary result set** defined with the `WITH` clause. It exists **only for the duration of the single statement** that follows it.

- *Common* because it is standard SQL (introduced in SQL:1999; PostgreSQL supports it since version 8.4).
- *Table expression* because, inside the statement, you use it like a table.
- *Temporary* because nothing is stored. When the statement finishes, the CTE is gone.

## 1.2 An analogy

Imagine solving a multi-step maths problem. You can write one enormous expression with brackets nested five deep, or you can write on separate lines: *"let A = the total cost; let B = A divided by the number of items; now compare each item to B."*

Nested subqueries are the single enormous expression. A CTE is the labelled intermediate line: you give a step a **name**, write it once, and refer to it by name afterwards.

## 1.3 Anatomy of a CTE

```sql
WITH dept_avg AS (                 -- 1. name it
    SELECT dept_id, AVG(salary) AS avg_salary    -- 2. define it
    FROM employees
    GROUP BY dept_id
)                                  -- 3. NO semicolon here
SELECT dept_id, ROUND(avg_salary, 2) AS avg_salary   -- 4. main query uses the name
FROM dept_avg
ORDER BY avg_salary DESC;
```

| Part | Purpose |
|---|---|
| `WITH` | Starts the CTE list |
| `dept_avg` | The name you will refer to (choose a descriptive one) |
| `AS ( ... )` | The query that produces the rows |
| main query | The `SELECT` (or `INSERT`/`UPDATE`/`DELETE`, see Module 12) that uses the CTE |

Result (6 rows):

```
 dept_id | avg_salary
---------+------------
       1 |  250000.00
       5 |   97333.33
       2 |   94625.00
       4 |   93750.00
       6 |   87428.57
       3 |   80571.43
```

### Renaming columns with a column list

You can name the CTE's columns in parentheses after its name:

```sql
WITH dept_avg (department, average_pay) AS (
    SELECT dept_id, AVG(salary)
    FROM employees
    GROUP BY dept_id
)
SELECT department, ROUND(average_pay, 2) AS average_pay
FROM dept_avg
ORDER BY average_pay DESC
LIMIT 3;
```

This is handy when the inner query's columns are unnamed expressions.

## 1.4 Worked example: untangling the nested query

In Module 0 we met a query that is correct but must be read inside-out. Here is the same question, *"which departments are larger than the average department?"*, as a pipeline of named steps:

```sql
WITH dept_size AS (                      -- step 1: headcount per department
    SELECT d.dept_name, COUNT(*) AS headcount
    FROM employees e
    JOIN departments d ON d.dept_id = e.dept_id
    GROUP BY d.dept_name
),
avg_size AS (                            -- step 2: the average of those headcounts
    SELECT AVG(headcount) AS avg_headcount
    FROM dept_size
)
SELECT s.dept_name, s.headcount          -- step 3: compare
FROM dept_size s
CROSS JOIN avg_size a
WHERE s.headcount > a.avg_headcount
ORDER BY s.headcount DESC, s.dept_name;
```

```
    dept_name     | headcount
------------------+-----------
 Engineering      |         8
 Data & Analytics |         7
 Sales            |         7
```

What improved:

1. **Top-to-bottom reading.** Each step is understandable alone.
2. **No repetition.** The department count is defined once (`dept_size`) and reused by `avg_size`.
3. **Debuggable.** Replace the final query with `SELECT * FROM dept_size;` to inspect step 1 in isolation.

Two details worth noticing:

- The **second CTE references the first** (`FROM dept_size`). Later CTEs in the same `WITH` list can use earlier ones. You separate CTEs with a comma, and `WITH` is written only once.
- `avg_size` returns exactly **one row**, so `CROSS JOIN` attaches that single value to every department row. This "one-row CTE" pattern is very common.

### Proving the rewrite is equivalent

Never trust a refactor by eye. `EXCEPT` returns rows in the first query that are missing from the second. If both directions return zero rows, the results are identical:

```sql
-- old_version = the nested query, new_version = the CTE rewrite
SELECT (SELECT COUNT(*) FROM (SELECT * FROM old_version EXCEPT SELECT * FROM new_version) a) AS only_in_old,
       (SELECT COUNT(*) FROM (SELECT * FROM new_version EXCEPT SELECT * FROM old_version) b) AS only_in_new;
```

```
 only_in_old | only_in_new
-------------+-------------
           0 |           0
```

The complete runnable version is Example 4 in [`examples.sql`](examples.sql). Use this technique every time you refactor SQL.

## 1.5 Using a CTE more than once

Define once, reference as many times as you need within the same statement:

```sql
WITH headcount AS (
    SELECT dept_id, COUNT(*) AS n FROM employees GROUP BY dept_id
)
SELECT (SELECT MAX(n) FROM headcount) AS largest_dept,
       (SELECT MIN(n) FROM headcount) AS smallest_dept;
```

Result: `largest_dept = 8`, `smallest_dept = 1`. With nested subqueries you would have to copy the `GROUP BY` query twice.

## 1.6 Scope: a CTE lives for one statement

```sql
WITH high_earners AS (SELECT emp_id FROM employees WHERE salary > 100000)
SELECT COUNT(*) FROM high_earners;     -- works: returns 9

SELECT COUNT(*) FROM high_earners;     -- ERROR: relation "high_earners" does not exist
```

The CTE is not a table or a view. It is not stored, and **it cannot have an index**. If you need a result across several statements, use a temporary table or a view (compared properly in Module 2).

## 1.7 Gotcha: a CTE can shadow a real table

If a CTE has the same name as a table, the CTE wins for the rest of that statement:

```sql
WITH employees AS (SELECT * FROM employees WHERE dept_id = 6)
SELECT COUNT(*) FROM employees;     -- 7  (the CTE, not the real table)

SELECT COUNT(*) FROM employees;     -- 30 (the real table, next statement)
```

Note that inside the CTE's own definition, `employees` still refers to the real table. This is legal but confusing, so **never name a CTE after a real table**.

## 1.8 What PostgreSQL actually does

Before PostgreSQL 12, every CTE was computed first and stored (*materialized*), so it acted as an "optimization fence". Since version 12, a simple CTE that is referenced **once** is **inlined**, i.e. treated like a subquery, so the planner can optimise across it. Prove it with `EXPLAIN`:

```sql
EXPLAIN
WITH all_emps AS (SELECT * FROM employees)
SELECT * FROM all_emps WHERE emp_id = 5;
```

```
 Index Scan using employees_pkey on employees  (cost=0.15..8.17 rows=1 width=128)
   Index Cond: (emp_id = 5)
```

There is no `CTE Scan` node: the filter `emp_id = 5` reached the real table and used its primary-key index. A CTE referenced more than once is materialized by default. You can control this explicitly, which is the topic of Module 7. (Exact cost numbers on your machine may differ.)

> **A CTE is not automatically faster.** In modern PostgreSQL a CTE and the equivalent subquery usually produce the same plan. Use CTEs for **clarity, reuse and recursion**, not as a speed trick.

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| A `;` inside the parentheses | syntax error | Only one `;`, at the very end of the whole statement |
| Forgetting the comma between CTEs | syntax error near the second name | `WITH a AS (...), b AS (...)` |
| Writing `WITH` again for the second CTE | syntax error | `WITH` appears once |
| Using the CTE in a later statement | `relation ... does not exist` | Re-declare it, or use a temp table / view |
| Naming a CTE like a real table | Wrong row counts, confusing plans | Use descriptive names such as `dept_size` |
| Referencing a *later* CTE from an earlier one | `relation ... does not exist` | Reorder: define dependencies first |

## Key takeaways

- A CTE is a **named, single-statement, temporary result set** introduced by `WITH`.
- Chain several CTEs with commas; later ones can use earlier ones.
- CTEs make queries readable top to bottom, easier to debug, and let you reuse a result.
- They are **not stored** and **not indexed**.
- Verify any refactor with `EXCEPT` in both directions.
- In PostgreSQL 12+, a CTE used once is inlined; do not expect a speed-up from the `WITH` keyword itself.

## Checkpoint

<details>
<summary>1. How long does a CTE exist?</summary>

For the duration of the single SQL statement it is attached to. A second statement cannot see it.
</details>

<details>
<summary>2. How do you define two CTEs in one query?</summary>

Write <code>WITH</code> once, then separate the definitions with a comma: <code>WITH a AS (...), b AS (...) SELECT ...</code>. The second can reference the first.
</details>

<details>
<summary>3. A teammate says "I'll use a CTE to make this query faster." What do you tell them?</summary>

In PostgreSQL 12+ a CTE referenced once is inlined, so the plan is normally identical to the subquery version. A CTE improves readability and enables reuse and recursion; check <code>EXPLAIN ANALYZE</code> before claiming a speed-up.
</details>

**Next:** do the [exercises](exercises.md), then continue to Module 2: CTE vs Subquery vs View vs Temp Table *(coming soon)*.
