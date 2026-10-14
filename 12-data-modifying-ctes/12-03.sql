-- Exercise 12-03: load the cleaned, de-duplicated customers_raw into customers_clean with an UPSERT.
-- The source is a CTE pipeline (the cleaning from Module 6). ON CONFLICT (email) makes the load idempotent:
-- running it again does not duplicate anything.
-- Everything runs inside BEGIN ... ROLLBACK so the practice data is left untouched.

BEGIN;

-- Part A: first run. Expected: 12 rows inserted.
WITH cleaned AS (                                               -- grain: one row per raw row
    SELECT raw_id,
           INITCAP(NULLIF(regexp_replace(trim(full_name), '\s+', ' ', 'g'), '')) AS full_name,
           NULLIF(lower(trim(email)), '')                                         AS email,
           loaded_at
    FROM customers_raw
),
valid AS (                                                  -- rows with a usable email
    SELECT raw_id, full_name, email, loaded_at
    FROM cleaned
    WHERE email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
),
latest AS (                                                 -- the newest record per email
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

-- Part B: second run of the very same statement. Expected: 0 rows inserted (idempotent).
WITH cleaned AS (                                               -- grain: one row per raw row
    SELECT raw_id,
           INITCAP(NULLIF(regexp_replace(trim(full_name), '\s+', ' ', 'g'), '')) AS full_name,
           NULLIF(lower(trim(email)), '')                                         AS email,
           loaded_at
    FROM customers_raw
),
valid AS (                                                  -- rows with a usable email
    SELECT raw_id, full_name, email, loaded_at
    FROM cleaned
    WHERE email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
),
latest AS (                                                 -- the newest record per email
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

-- Part C: what was loaded. Expected: 12 rows, one per distinct valid email.
SELECT email, full_name, loaded_at::date AS loaded_on
FROM customers_clean
ORDER BY email;

-- Part D: a NEWER record for an existing email arrives. DO UPDATE ... WHERE changes a row only if it is
-- newer, so exactly one row is updated. Expected: alice.mwangi@example.com, Alice Mwangi-Otieno.
INSERT INTO customers_raw (raw_id, full_name, email, loaded_at)
VALUES (21, 'Alice  Mwangi-Otieno', 'ALICE.MWANGI@example.com', '2026-05-01 10:00');

WITH cleaned AS (                                               -- grain: one row per raw row
    SELECT raw_id,
           INITCAP(NULLIF(regexp_replace(trim(full_name), '\s+', ' ', 'g'), '')) AS full_name,
           NULLIF(lower(trim(email)), '')                                         AS email,
           loaded_at
    FROM customers_raw
),
valid AS (                                                  -- rows with a usable email
    SELECT raw_id, full_name, email, loaded_at
    FROM cleaned
    WHERE email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
),
latest AS (                                                 -- the newest record per email
    SELECT full_name, email, loaded_at,
           ROW_NUMBER() OVER (PARTITION BY email ORDER BY loaded_at DESC, raw_id DESC) AS rn
    FROM valid
),
upserted AS (
    INSERT INTO customers_clean (full_name, email, loaded_at)
    SELECT full_name, email, loaded_at FROM latest WHERE rn = 1
    ON CONFLICT (email) DO UPDATE                           -- already there? update it, but only if newer
        SET full_name = EXCLUDED.full_name,
            loaded_at = EXCLUDED.loaded_at
        WHERE customers_clean.loaded_at < EXCLUDED.loaded_at
    RETURNING email, full_name
)
SELECT email, full_name FROM upserted;

-- And running the same DO UPDATE statement again changes nothing (nothing is newer now). Expected: no rows.
WITH cleaned AS (                                               -- grain: one row per raw row
    SELECT raw_id,
           INITCAP(NULLIF(regexp_replace(trim(full_name), '\s+', ' ', 'g'), '')) AS full_name,
           NULLIF(lower(trim(email)), '')                                         AS email,
           loaded_at
    FROM customers_raw
),
valid AS (                                                  -- rows with a usable email
    SELECT raw_id, full_name, email, loaded_at
    FROM cleaned
    WHERE email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'
),
latest AS (                                                 -- the newest record per email
    SELECT full_name, email, loaded_at,
           ROW_NUMBER() OVER (PARTITION BY email ORDER BY loaded_at DESC, raw_id DESC) AS rn
    FROM valid
),
upserted AS (
    INSERT INTO customers_clean (full_name, email, loaded_at)
    SELECT full_name, email, loaded_at FROM latest WHERE rn = 1
    ON CONFLICT (email) DO UPDATE                           -- already there? update it, but only if newer
        SET full_name = EXCLUDED.full_name,
            loaded_at = EXCLUDED.loaded_at
        WHERE customers_clean.loaded_at < EXCLUDED.loaded_at
    RETURNING email, full_name
)
SELECT email, full_name FROM upserted;
ROLLBACK;

-- Part E: rolled back. Expected: 0 customers_clean rows and the original 20 raw rows.
SELECT (SELECT COUNT(*) FROM customers_clean) AS customers_clean_rows,
       (SELECT COUNT(*) FROM customers_raw)   AS customers_raw_rows;
