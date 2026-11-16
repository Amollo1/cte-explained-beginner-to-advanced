-- Capstone 3: DATA-QUALITY PIPELINE (cleaning, quarantine, an audit log and automated checks).
--
-- The business need: customer records arrive messy and repeatedly. We need a clean customer table, a quarantine for
-- rows that cannot be used (with the reason), a log of every run, and automated checks that fail loudly.
--   dq.customer       clean, de-duplicated customers (email is the key)
--   dq.rejected       quarantine: rows with a missing or malformed email, with the reason
--   dq.run_log        one row per run: raw rows, loaded or updated, duplicates seen, newly quarantined
--   dq.run_pipeline() ONE statement (data-modifying CTEs) that cleans, loads, quarantines and logs atomically
--   dq.v_checks       automated checks; every row must say passed = true
-- Policy: the latest record per email wins (a newer record updates the stored row); a blank name is allowed
-- but reported; a missing or malformed email is quarantined.
-- Techniques: cleaning and de-duplication (Module 6), upsert and RETURNING (Module 12), reconciliation (Modules 4, 6).
-- HOW THIS FILE IS USED
--   In this course repository the file runs inside BEGIN ... ROLLBACK, so the practice data is never changed
--   and the automated tests can run it again and again.
--   To KEEP the objects in YOUR OWN project repository, copy the file, delete the BEGIN; and ROLLBACK; lines
--   (or replace ROLLBACK; with COMMIT;) and run it once against your own database.

BEGIN;

CREATE SCHEMA dq;

CREATE TABLE dq.customer (
    email         text      PRIMARY KEY,
    full_name     text,
    loaded_at     timestamp NOT NULL,
    source_raw_id int       NOT NULL
);
CREATE TABLE dq.rejected (
    raw_id    int  PRIMARY KEY,
    reason    text NOT NULL,
    raw_email text,
    raw_name  text
);
CREATE TABLE dq.run_log (
    run_id                 int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raw_rows               int NOT NULL,
    loaded_or_updated_rows int NOT NULL,
    duplicate_rows         int NOT NULL,
    rejected_rows          int NOT NULL
);

CREATE FUNCTION dq.run_pipeline() RETURNS void
LANGUAGE sql AS $$
WITH cleaned AS (                                           -- grain: one row per raw row
    SELECT raw_id,
           INITCAP(NULLIF(regexp_replace(trim(full_name), '\s+', ' ', 'g'), '')) AS full_name,
           NULLIF(lower(trim(email)), '')                                         AS email,
           loaded_at,
           email     AS raw_email,
           full_name AS raw_name
    FROM customers_raw
),
classified AS (                                             -- same grain, plus a reject reason (NULL = usable)
    SELECT raw_id, full_name, email, loaded_at, raw_email, raw_name,
           CASE WHEN email IS NULL                          THEN 'missing email'
                WHEN email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'  THEN 'malformed email' END AS reject_reason
    FROM cleaned
),
ranked AS (                                                 -- the newest usable record per email gets rn = 1
    SELECT raw_id, full_name, email, loaded_at,
           ROW_NUMBER() OVER (PARTITION BY email ORDER BY loaded_at DESC, raw_id DESC) AS rn
    FROM classified
    WHERE reject_reason IS NULL
),
quarantined AS (                                            -- unusable rows go to quarantine (once)
    INSERT INTO dq.rejected (raw_id, reason, raw_email, raw_name)
    SELECT raw_id, reject_reason, raw_email, raw_name
    FROM classified
    WHERE reject_reason IS NOT NULL
    ON CONFLICT (raw_id) DO NOTHING
    RETURNING raw_id
),
loaded AS (                                                 -- latest wins: insert, or update only if newer
    INSERT INTO dq.customer (email, full_name, loaded_at, source_raw_id)
    SELECT email, full_name, loaded_at, raw_id
    FROM ranked
    WHERE rn = 1
    ON CONFLICT (email) DO UPDATE
        SET full_name = EXCLUDED.full_name, loaded_at = EXCLUDED.loaded_at, source_raw_id = EXCLUDED.source_raw_id
        WHERE dq.customer.loaded_at < EXCLUDED.loaded_at
    RETURNING email
)
INSERT INTO dq.run_log (raw_rows, loaded_or_updated_rows, duplicate_rows, rejected_rows)
SELECT (SELECT COUNT(*) FROM customers_raw),
       (SELECT COUNT(*) FROM loaded),
       (SELECT COUNT(*) FROM ranked WHERE rn > 1),
       (SELECT COUNT(*) FROM quarantined)
$$;

CREATE VIEW dq.v_checks AS
SELECT ord, check_name, expected, actual, (expected = actual) AS passed
FROM (
    VALUES
    (1, 'no duplicate emails in dq.customer', '0',
        (SELECT COUNT(*) FROM (SELECT email FROM dq.customer GROUP BY email HAVING COUNT(*) > 1) d)::text),
    (2, 'no malformed emails in dq.customer', '0',
        (SELECT COUNT(*) FROM dq.customer WHERE email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')::text),
    (3, 'no missing emails in dq.customer', '0',
        (SELECT COUNT(*) FROM dq.customer WHERE email IS NULL OR email = '')::text),
    (4, 'every quarantined row has a reason', '0',
        (SELECT COUNT(*) FROM dq.rejected WHERE reason IS NULL OR reason = '')::text),
    (5, 'one customer per distinct valid email in the raw data',
        (SELECT COUNT(DISTINCT lower(trim(email))) FROM customers_raw
         WHERE lower(trim(email)) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')::text,
        (SELECT COUNT(*) FROM dq.customer)::text),
    (6, 'run 1 reconciles: raw = loaded + duplicates + rejected', 'true',
        (SELECT (raw_rows = loaded_or_updated_rows + duplicate_rows + rejected_rows)::text FROM dq.run_log ORDER BY run_id LIMIT 1)),
    (7, 'run 2 changed nothing (the load is idempotent)', '0',
        (SELECT loaded_or_updated_rows::text FROM dq.run_log ORDER BY run_id OFFSET 1 LIMIT 1))
) c(ord, check_name, expected, actual);

-- Part A: run 1, then run 2 immediately (nothing new). Run 3 follows a late-arriving, NEWER record for an existing email.
DO $$ BEGIN PERFORM dq.run_pipeline(); END $$;
DO $$ BEGIN PERFORM dq.run_pipeline(); END $$;
INSERT INTO customers_raw (raw_id, full_name, email, loaded_at)
VALUES (21, 'Alice  Mwangi-Otieno', 'ALICE.MWANGI@example.com', '2026-05-01 10:00');
DO $$ BEGIN PERFORM dq.run_pipeline(); END $$;

-- The run log. Expected: (20, 12, 6, 2), (20, 0, 6, 0), (21, 1, 7, 0).
SELECT raw_rows, loaded_or_updated_rows, duplicate_rows, rejected_rows FROM dq.run_log ORDER BY run_id;

-- Part B: the quarantine, with the original raw values, and the late record that won. Expected: 2 rows, then Alice.
SELECT raw_id, reason, quote_nullable(raw_email) AS raw_email, quote_nullable(raw_name) AS raw_name
FROM dq.rejected
ORDER BY raw_id;
SELECT email, full_name FROM dq.customer WHERE email = 'alice.mwangi@example.com';

-- Part C: the automated checks. Every row must say passed = true.
SELECT check_name, expected, actual, passed FROM dq.v_checks ORDER BY ord;

-- Part D: the checks catch tampering. Someone inserts a bad row straight into the clean table, bypassing the pipeline.
-- Expected: 2 checks now fail (no malformed emails; one customer per distinct valid email).
INSERT INTO dq.customer (email, full_name, loaded_at, source_raw_id) VALUES ('not-an-email', 'Bad Row', '2026-06-01', 999);
SELECT COUNT(*) FILTER (WHERE NOT passed) AS failing_checks
FROM dq.v_checks;
SELECT check_name FROM dq.v_checks WHERE NOT passed ORDER BY ord;

ROLLBACK;
