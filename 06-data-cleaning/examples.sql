-- Module 6 worked examples: cleaning and deduplicating customers_raw with CTEs.
-- Run:  psql -d cte_lab -f 06-data-cleaning/examples.sql
-- Principle: the raw table is never modified. Cleaning is a QUERY, built as a pipeline of CTEs.

-- =====================================================================
-- Part A: profile first, clean second
-- =====================================================================

-- Example 1: see the invisible. quote_nullable() shows quotes, spaces and NULL vs ''.
SELECT raw_id, quote_nullable(full_name) AS full_name, quote_nullable(email) AS email
FROM customers_raw
WHERE raw_id IN (2, 4, 9, 10, 11, 13, 17)
ORDER BY raw_id;

-- Example 2: SELECT DISTINCT cannot see the duplicates until the data is standardised.
SELECT COUNT(email)                                   AS non_null_emails,
       COUNT(DISTINCT email)                          AS distinct_as_stored,
       COUNT(DISTINCT NULLIF(lower(trim(email)), '')) AS distinct_after_cleaning
FROM customers_raw;

-- Example 3: TRIM removes only SPACES. A leading tab survives; a regex removes all whitespace.
SELECT length(trim(E'\tabc '))                                           AS trim_length,
       length(regexp_replace(E'\tabc ', '^\s+|\s+$', '', 'g'))           AS regex_length;

-- =====================================================================
-- Part B: standardise and validate
-- =====================================================================

-- Example 4: the standardising step. One row per raw row; blanks become NULL.
WITH cleaned AS (                    -- grain: one row per raw row
    SELECT raw_id,
           INITCAP(NULLIF(regexp_replace(trim(full_name), '\s+', ' ', 'g'), '')) AS full_name,
           NULLIF(lower(trim(email)), '')                                         AS email,
           loaded_at
    FROM customers_raw
)
SELECT raw_id, quote_nullable(full_name) AS full_name, quote_nullable(email) AS email
FROM cleaned
WHERE raw_id IN (2, 4, 9, 13, 17)
ORDER BY raw_id;

-- Example 5: validate. Classify every row, then count by status.
WITH cleaned AS (
    SELECT raw_id, NULLIF(lower(trim(email)), '') AS email
    FROM customers_raw
),
classified AS (
    SELECT raw_id,
           CASE WHEN email IS NULL                            THEN 'missing email'
                WHEN email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'    THEN 'malformed email'
                ELSE 'valid' END AS email_status
    FROM cleaned
)
SELECT email_status, COUNT(*) AS rows
FROM classified
GROUP BY email_status
ORDER BY email_status;

-- =====================================================================
-- Part C: deduplicate
-- =====================================================================

-- Example 6: THE NULL TRAP. ROW_NUMBER partitions group all NULLs TOGETHER,
-- so unrelated rows with a missing email look like duplicates of each other.
SELECT id, email,
       ROW_NUMBER() OVER (PARTITION BY email ORDER BY id) AS rn
FROM (VALUES (1, NULL::text), (2, NULL), (3, 'a@x.com')) AS v(id, email)
ORDER BY id;

-- Example 7: keep the LATEST record per cleaned email (rows with an email only).
WITH cleaned AS (
    SELECT raw_id,
           INITCAP(NULLIF(regexp_replace(trim(full_name), '\s+', ' ', 'g'), '')) AS full_name,
           NULLIF(lower(trim(email)), '')                                         AS email,
           loaded_at
    FROM customers_raw
),
ranked AS (                          -- same grain, plus a rank within each email
    SELECT raw_id, full_name, email, loaded_at,
           ROW_NUMBER() OVER (PARTITION BY email ORDER BY loaded_at DESC, raw_id DESC) AS rn
    FROM cleaned
    WHERE email IS NOT NULL          -- keeps NULL emails out of the partition (Example 6)
)
SELECT raw_id, full_name, email, loaded_at::date AS loaded_on
FROM ranked
WHERE rn = 1
ORDER BY email;

-- Example 8: DISTINCT ON is the PostgreSQL shortcut for the same job. Prove they agree.
WITH cleaned AS (
    SELECT raw_id, NULLIF(lower(trim(email)), '') AS email, loaded_at
    FROM customers_raw
),
window_version AS (
    SELECT raw_id
    FROM (SELECT raw_id,
                 ROW_NUMBER() OVER (PARTITION BY email ORDER BY loaded_at DESC, raw_id DESC) AS rn
          FROM cleaned WHERE email IS NOT NULL) t
    WHERE rn = 1
),
distinct_on_version AS (
    SELECT DISTINCT ON (email) raw_id
    FROM cleaned
    WHERE email IS NOT NULL
    ORDER BY email, loaded_at DESC, raw_id DESC
)
SELECT (SELECT COUNT(*) FROM window_version)      AS window_rows,
       (SELECT COUNT(*) FROM distinct_on_version) AS distinct_on_rows,
       (SELECT COUNT(*) FROM (SELECT * FROM window_version EXCEPT SELECT * FROM distinct_on_version) a)
     + (SELECT COUNT(*) FROM (SELECT * FROM distinct_on_version EXCEPT SELECT * FROM window_version) b) AS differences;

-- =====================================================================
-- Part D: the whole pipeline, with reconciliation and an audit trail
-- =====================================================================

-- Example 9: raw -> cleaned -> classified -> valid_ranked, then RECONCILE:
-- every raw row must end up in exactly one outcome.
WITH cleaned AS (                    -- grain: one row per raw row
    SELECT raw_id,
           INITCAP(NULLIF(regexp_replace(trim(full_name), '\s+', ' ', 'g'), '')) AS full_name,
           NULLIF(lower(trim(email)), '')                                         AS email,
           loaded_at
    FROM customers_raw
),
classified AS (                      -- same grain, plus a reject reason (NULL = acceptable)
    SELECT raw_id, full_name, email, loaded_at,
           CASE WHEN email IS NULL                          THEN 'missing email'
                WHEN email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'  THEN 'malformed email' END AS reject_reason
    FROM cleaned
),
valid_ranked AS (                    -- grain: one row per ACCEPTABLE raw row
    SELECT raw_id, full_name, email, loaded_at,
           ROW_NUMBER() OVER (PARTITION BY email ORDER BY loaded_at DESC, raw_id DESC) AS rn
    FROM classified
    WHERE reject_reason IS NULL
)
SELECT (SELECT COUNT(*) FROM valid_ranked WHERE rn = 1)                     AS kept,
       (SELECT COUNT(*) FROM valid_ranked WHERE rn > 1)                     AS duplicates_removed,
       (SELECT COUNT(*) FROM classified   WHERE reject_reason IS NOT NULL)  AS rejected,
       (SELECT COUNT(*) FROM valid_ranked WHERE rn = 1)
     + (SELECT COUNT(*) FROM valid_ranked WHERE rn > 1)
     + (SELECT COUNT(*) FROM classified   WHERE reject_reason IS NOT NULL)  AS accounted_for,
       (SELECT COUNT(*) FROM customers_raw)                                 AS raw_rows;

-- Example 10: the audit trail. Never drop rows silently: list what was rejected and why.
WITH cleaned AS (
    SELECT raw_id, full_name, NULLIF(lower(trim(email)), '') AS email
    FROM customers_raw
)
SELECT raw_id,
       CASE WHEN email IS NULL                         THEN 'missing email'
            WHEN email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN 'malformed email' END AS reject_reason,
       quote_nullable(email) AS cleaned_email
FROM cleaned
WHERE email IS NULL OR email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
ORDER BY raw_id;
