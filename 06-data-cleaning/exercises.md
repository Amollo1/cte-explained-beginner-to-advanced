# Module 6 Exercises

All three exercises use `customers_raw` (20 rows). Remember: clean in a query and never `UPDATE` the raw table.

| ID | Task | Tables | Self-check | Solution |
|---|---|---|---|---|
| 06-01 | **Deduplicate.** Keep the latest record per **cleaned email** (lower-cased, trimmed). Tidy the name too (collapse spaces, blank to `NULL`, capitalise). Ignore rows with no email. | `customers_raw` | 13 rows; Alice's surviving row is `raw_id` 2 (loaded `2026-02-10`) | [`06-01.sql`](06-01.sql) |
| 06-02 | **Flag problem rows.** For each problem row return one `issues` text combining any of: `missing name`, `missing email`, `malformed email`, `formatting` (extra spaces or upper case that cleaning would fix). Return only rows with at least one issue. | `customers_raw` | 7 rows: ids 2, 4, 9, 10, 11, 13, 17 | [`06-02.sql`](06-02.sql) |
| 06-03 | **Data-quality summary** in one row: total rows, distinct cleaned emails, duplicate rows, rows with a missing name, rows with a missing or malformed email. | `customers_raw` | `20, 13, 6, 1, 2` | [`06-03.sql`](06-03.sql) |

## Hints

<details>
<summary>06-01</summary>

Two CTEs: `cleaned` (one row per raw row, with `lower(trim(email))` and `NULLIF(..., '')`) and `ranked` (`ROW_NUMBER() OVER (PARTITION BY email ORDER BY loaded_at DESC, raw_id DESC)`). Filter `email IS NOT NULL` **inside** `ranked`, then keep `rn = 1` in the final query. As a check, `COUNT(DISTINCT email)` on the cleaned data should equal your row count.
</details>

<details>
<summary>06-02</summary>

Compute four boolean checks in a CTE. `NULLIF(trim(full_name), '') IS NULL` finds missing names. A formatting issue is a value that **differs from its cleaned version** (for example `email <> lower(trim(email))`). Combine the labels with `concat_ws(', ', CASE WHEN ... THEN '...' END, ...)`: `concat_ws` skips `NULL` arguments, so only the issues that apply appear.
</details>

<details>
<summary>06-03</summary>

Clean once in a CTE, then compute everything with aggregates over it. `COUNT(DISTINCT email)` ignores `NULL`s. Duplicates are `COUNT(email) - COUNT(DISTINCT email)`: non-null emails minus distinct ones. Use `COUNT(*) FILTER (WHERE ...)` for the two "missing" counts.
</details>

## Stretch goals

1. **Survivorship in action.** Inside a transaction, insert a newer duplicate of Carol with a blank name:
   `INSERT INTO customers_raw VALUES (21, '', 'carol.njeri@example.com', '2026-04-01 09:00');`
   Re-run 06-01 and see what happens to her name (it becomes `NULL`). Then change the window `ORDER BY` to `(full_name IS NOT NULL) DESC, loaded_at DESC, raw_id DESC` so the complete record wins. Finish with `ROLLBACK;`.
2. **Merge the fields.** In the same scenario, build a query that keeps the **newest** `loaded_at` per email but takes the **latest non-blank name** from any duplicate. Hint: `(array_agg(full_name ORDER BY loaded_at DESC) FILTER (WHERE full_name IS NOT NULL))[1]`. Expected for Carol: `Carol Njeri`, last loaded `2026-04-01`.
3. **Make it reusable.** Wrap the full pipeline from the lesson (cleaned, classified, valid_ranked) in a view called `v_customers_clean` that returns only the rows with `rn = 1`. Query the view to confirm it returns 12 rows, then drop it. (Module 12 uses this same logic to **load** a clean table.)
