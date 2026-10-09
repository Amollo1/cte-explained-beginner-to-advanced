-- Exercise 06-03: one-row data-quality summary of customers_raw.
--   total_rows               all rows
--   distinct_emails          distinct cleaned emails (NULLs not counted)
--   duplicate_rows           rows that repeat an already-seen cleaned email
--   rows_missing_name        blank or NULL name
--   rows_missing_or_bad_email  NULL, blank or malformed email
WITH cleaned AS (
    SELECT raw_id,
           NULLIF(trim(full_name), '')    AS full_name,
           NULLIF(lower(trim(email)), '') AS email
    FROM customers_raw
),
metrics AS (
    SELECT COUNT(*)                                                   AS total_rows,
           COUNT(DISTINCT email)                                      AS distinct_emails,
           COUNT(email) - COUNT(DISTINCT email)                       AS duplicate_rows,
           COUNT(*) FILTER (WHERE full_name IS NULL)                  AS rows_missing_name,
           COUNT(*) FILTER (WHERE email IS NULL
                               OR email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') AS rows_missing_or_bad_email
    FROM cleaned
)
SELECT total_rows, distinct_emails, duplicate_rows, rows_missing_name, rows_missing_or_bad_email
FROM metrics;
