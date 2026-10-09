# Module 8 Exercises

Always put a stop condition (or a `statement_timeout`) on a recursion you have not proven yet.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 08-01 | **Numbers 1 to 10 by recursion**, with the square of each. Then prove the same numbers come from `generate_series` using `EXCEPT` in both directions. | none | 10 rows (`10` has square `100`); `10, 10, 0` | [`08-01.sql`](08-01.sql) |
| 08-02 | **Gap-fill with a recursive calendar.** Build a calendar from the first to the last order date (taken from the data). Left join the orders and summarise **by month**: days, days with orders, days without orders, orders. Then reconcile. | `orders` | 18 rows; Jan 2025 is `31, 5, 26, 5`. Reconcile: `546, 546, 120, 120`, and `434` days with no orders | [`08-02.sql`](08-02.sql) |
| 08-03 | **Fibonacci and factorial** for the first 15 values, in one recursive CTE that carries the state forward. | none | 15 rows; n = 15 gives `610` and `1307674368000` | [`08-03.sql`](08-03.sql) |
| 08-04 | **Termination.** (A) Run a recursion with no stop condition under `statement_timeout` and show it is cancelled. (B) Show how `UNION` and `UNION ALL` (with a guard) end the cycle 1, 2, 3, 1, ... | none | A: `t`. B: `3` and `10` | [`08-04.sql`](08-04.sql) |

## Hints

<details>
<summary>08-01</summary>

Anchor `SELECT 1`; recursive member `SELECT n + 1 FROM counter WHERE n < 10`. For the check, put the recursive result and `SELECT g FROM generate_series(1, 10) g` in two CTEs and compare with `EXCEPT` in both directions.
</details>

<details>
<summary>08-02</summary>

Four CTEs in one `WITH RECURSIVE`: `bounds` (MIN and MAX of `order_date`), `calendar` (anchor is the first day; recursive member adds 1 while `day < last_day`), `daily_orders` (count per date) and `filled` (`LEFT JOIN` with `COALESCE(orders, 0)`). Summarise with `date_trunc('month', day)` and `COUNT(*) FILTER (WHERE ...)`. Reconcile: calendar rows should equal `last_day - first_day + 1`, and the summed orders should equal `COUNT(*)` on `orders`.
</details>

<details>
<summary>08-03</summary>

Carry four columns: `n`, `fib`, `next_fib`, `factorial`. Each round: `n + 1`, the old `next_fib`, the sum `fib + next_fib`, and `factorial * (n + 1)`. Make the anchor values `numeric` (`1::numeric`) so nothing overflows.
</details>

<details>
<summary>08-04</summary>

Part A: wrap the runaway query in a small function that catches `query_canceled` (note that `WHEN OTHERS` does **not** catch it), run it after `SET statement_timeout = '300ms'`, then `RESET statement_timeout`. Part B: the recursive step is `(n % 3) + 1`; one version uses `UNION`, the other `UNION ALL` with a `depth < 10` guard.
</details>

## Stretch goals

1. **The bounds trap.** Build a calendar for all of 2026 (anchor `DATE '2026-01-01'`, stop at `DATE '2026-12-31'`) and count the months with zero orders. You should find 6. Explain why they are misleading, and compare with the bounds-from-data version.
2. **Fix `LAG`.** Reproduce Example 8 from the lesson. Inside a transaction, set September 2025's completed orders to `'cancelled'`, then compare the naive month-over-month growth for October with the calendar version (`-50.7` against `NULL`). How would you show "growth after a zero month" in a report? Finish with `ROLLBACK;`.
3. **Recursion vs `generate_series`.** Rebuild the 08-02 calendar with `generate_series` and prove with `EXCEPT` that it gives the same days. Then compare both on a 100,000-day calendar with `EXPLAIN ANALYZE`. Which is faster, and why would you still choose recursion for the traversal problems in Modules 9 to 11?
