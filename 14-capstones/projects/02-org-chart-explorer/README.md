# Org-chart explorer: a recursive view, a function and an integrity audit

> **This README is a model.** Rewrite it in your own words, and keep only the claims that are true of **your** project.

## The problem

HR needs to see who manages whom, how large each team is and what it costs, and to be **warned when the reporting data is broken**. Reporting lines live in one self-referencing table (`employees.manager_id`), which is easy to query wrongly and easy to corrupt.

## What this project demonstrates

- **Top-down recursion** with a path and depth, and a **closure** to compute team sizes and payroll in one pass.
- **Aggregate, then join**, so the manager's own salary is never repeated.
- A **depth guard** on the closure, so a cycle in bad data cannot hang the query.
- An **integrity audit** that detects broken data, with a test that breaks the data on purpose.
- A reusable SQL **function** (`org.team`) and **documented** views.

## Design

| Object | Purpose |
|---|---|
| `org.v_org_chart` | every employee with depth, chain of managers, direct and total reports, team payroll |
| `org.v_level_stats` | people, average salary and payroll per level |
| `org.team(manager)` | function: everyone below a manager |
| `org.v_audit` | employees total, reached from the root, roots, unreachable |

**Decisions.** A traversal from the root can never loop (every row has one parent), so it is safe, but it cannot reach rows disconnected from the root. That is exactly why `reached < total` detects a broken cycle. The closure *can* loop on a cycle, so it carries a depth guard.

## How to run it

```bash
psql -d your_database -f 14-capstones/14-02.sql
```

To keep the `org` schema, delete the `BEGIN;` and `ROLLBACK;` lines in your copy. The last part of the file deliberately corrupts the data inside the transaction to prove the audit works.

## Results

The managers' scorecard in outline order (first rows):

```
         manager         | direct_reports | total_reports | team_payroll
-------------------------+----------------+---------------+--------------
 Amina Hassan            |              5 |            29 |   2850000.00
     Brian Otieno        |              2 |             7 |    757000.00
         Grace Wanjiru   |              3 |             3 |    329000.00
         Hassan Ali      |              2 |             2 |    263000.00
     Carla Mendes        |              2 |             6 |    564000.00
```

The audit, on the real data and then after employees 14 and 15 are made each other's manager (a detached cycle):

```
 employees_total | employees_reached | roots | unreachable_employees
-----------------+-------------------+-------+-----------------------
              30 |                30 |     1 |                     0      (real data)
              30 |                28 |     1 |                     2      (after the corruption)
```

## How it is tested

Eight self-checks, all `t`, with expected values from independent routes. The strongest: the **VP Data's team payroll (612,000.00) equals the Data and Analytics department payroll**, computed through a completely different path (by department, not by management line). Others: every employee appears; the deepest level is 5; the CEO's total reports and the sum of all direct reports are both 29; the CEO's team payroll equals the whole payroll; exactly one root and no unreachable employee.

## Limitations

- It assumes **one manager per employee**; matrix organisations (several managers) need a different design.
- There is **no history**: it shows the organisation now, not as it was.
- There is no front end yet: the output is SQL views, ready for a BI tool's hierarchy feature.

## What I would do next

- A **front end**: a Power BI hierarchy on `path_ids`, or a small web page that renders the tree.
- **Effective dates** on reporting lines, to answer "who reported to whom last March".
- Schedule the audit and send its result somewhere a person will see it.

## Skills used

Recursive CTEs and hierarchies ([Modules 8](../../../08-recursive-basics/lesson.md) and [9](../../../09-hierarchies/lesson.md)), cycle safety ([10](../../../10-graphs-and-cycles/lesson.md)), reconciliation ([4](../../../04-aggregation-patterns/lesson.md)). Reference solution: [`14-02.sql`](../../14-02.sql).
