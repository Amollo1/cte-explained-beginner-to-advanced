-- Exercise 06-01: keep the latest record per normalised email.
-- Policy: "latest wins" (highest loaded_at; raw_id breaks exact timestamp ties).
-- Rows with no email cannot be identified by email, so they are excluded here and flagged in 06-02.
-- Standardising first is essential: as stored there are 17 distinct emails, after cleaning 13.
-- Expected: 13 rows.
WITH cleaned AS (                    -- grain: one row per raw row
    SELECT raw_id,
           INITCAP(NULLIF(regexp_replace(trim(full_name), '\s+', ' ', 'g'), '')) AS full_name,
           NULLIF(lower(trim(email)), '')                                         AS email,
           loaded_at
    FROM customers_raw
),
ranked AS (                          -- same grain, plus rank within each email
    SELECT raw_id, full_name, email, loaded_at,
           ROW_NUMBER() OVER (PARTITION BY email ORDER BY loaded_at DESC, raw_id DESC) AS rn
    FROM cleaned
    WHERE email IS NOT NULL
)
SELECT raw_id, full_name, email, loaded_at::date AS loaded_on
FROM ranked
WHERE rn = 1
ORDER BY email;
