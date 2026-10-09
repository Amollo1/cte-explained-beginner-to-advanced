-- Exercise 06-02: flag rows with data-quality problems.
-- Four issue types, combined into one readable column with concat_ws (which skips NULLs):
--   missing name / missing email / malformed email / formatting (extra spaces or upper case to fix)
-- Only rows with at least one issue are returned. Expected: 7 rows.
WITH checks AS (
    SELECT raw_id,
           NULLIF(trim(full_name), '') IS NULL                                  AS missing_name,
           NULLIF(trim(email), '') IS NULL                                      AS missing_email,
           NULLIF(trim(email), '') IS NOT NULL
             AND lower(trim(email)) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'             AS malformed_email,
           (email IS NOT NULL AND email <> lower(trim(email)))
             OR (full_name <> trim(regexp_replace(full_name, '\s+', ' ', 'g'))) AS formatting_issue
    FROM customers_raw
)
SELECT raw_id,
       concat_ws(', ',
                 CASE WHEN missing_name     THEN 'missing name'     END,
                 CASE WHEN missing_email    THEN 'missing email'    END,
                 CASE WHEN malformed_email  THEN 'malformed email'  END,
                 CASE WHEN formatting_issue THEN 'formatting'       END) AS issues
FROM checks
WHERE missing_name OR missing_email OR malformed_email OR formatting_issue
ORDER BY raw_id;
