# Module 6: Data Cleaning & Deduplication

**Level:** Intermediate  |  **Time:** about 2 hours  |  **Files:** [`examples.sql`](examples.sql) · [`exercises.md`](exercises.md)

## Learning objectives

By the end of this module you can:

- profile a messy table before touching it,
- standardise text (whitespace, case, blanks vs `NULL`) in a dedicated CTE,
- validate values with a regular expression and classify rows,
- deduplicate with `ROW_NUMBER`, including the `NULL` trap,
- choose and document a **survivorship rule** (which duplicate wins),
- build a pipeline whose row counts **reconcile**, with an audit trail of what was rejected.

We work on `customers_raw`, a 20-row table of customer records with the kinds of problems every real system has.

---

## 6.1 The principle: raw data is never edited

Cleaning data with `UPDATE` and `DELETE` destroys evidence. If you later discover a rule was wrong, you cannot go back. The professional approach is to treat **cleaning as a query**: the raw table stays untouched, and a pipeline of CTEs produces the clean result on demand.

| Stage | CTE | Grain (one row per...) | Job |
|---|---|---|---|
| 1 | `cleaned` | raw row | standardise text, turn blanks into `NULL` |
| 2 | `classified` | raw row | decide if the row is acceptable, and why not |
| 3 | `valid_ranked` | acceptable raw row | rank duplicates of the same person |
| 4 | final query | person | keep rank 1, report the rest |

Each stage has one job and one stated grain, exactly as in Module 3. (Module 12 shows how to *load* the result into a clean table.)

## 6.2 Profile first

Before writing any rule, look at the data. `psql` and most SQL clients do not show trailing spaces, so make them visible with `quote_nullable()`, which wraps text in quotes and prints `NULL` for nulls:

```sql
SELECT raw_id, quote_nullable(full_name) AS full_name, quote_nullable(email) AS email
FROM customers_raw
WHERE raw_id IN (2, 4, 9, 10, 11, 13, 17)
ORDER BY raw_id;
```

```
 raw_id |    full_name     |            email
--------+------------------+------------------------------
      2 | 'alice mwangi '  | 'Alice.Mwangi@Example.com'
      4 | 'Brian  Otieno'  | 'BRIAN.OTIENO@EXAMPLE.COM '
      9 | ''               | 'unknown@example.com'
     10 | 'Farah Ahmed'    | 'farah.ahmed@example'
     11 | 'George Ouma'    | NULL
     13 | 'hannah schmidt' | 'Hannah.Schmidt@example.com'
     17 | 'Kevin Mutua'    | 'kevin.mutua@example.com '
```

A catalogue of what we can see:

| Problem | Example row | Kind |
|---|---|---|
| Trailing space | 2 (name), 4 and 17 (email) | formatting |
| Double space inside a name | 4 | formatting |
| Upper case in an email | 2, 4, 13 | formatting |
| Blank name (`''`, not `NULL`) | 9 | missing value |
| Missing email (`NULL`) | 11 | missing value |
| Malformed email (no `.` after `@`) | 10 | invalid value |
| Same person loaded several times | 1 and 2, 3 and 4, and more | duplicates |

### Why `SELECT DISTINCT` is not enough

```sql
SELECT COUNT(email)                                   AS non_null_emails,
       COUNT(DISTINCT email)                          AS distinct_as_stored,
       COUNT(DISTINCT NULLIF(lower(trim(email)), '')) AS distinct_after_cleaning
FROM customers_raw;
```

```
 non_null_emails | distinct_as_stored | distinct_after_cleaning
-----------------+--------------------+-------------------------
              19 |                 17 |                      13
```

As stored, the table seems to hold 17 different emails. After cleaning it holds 13. **Four duplicates were invisible** because `Alice.Mwangi@Example.com` and `alice.mwangi@example.com` are different strings but the same person. Standardise first, then deduplicate.

## 6.3 Standardise

The `cleaned` CTE applies one rule per column:

```sql
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
```

```
 raw_id |    full_name     |            email
--------+------------------+------------------------------
      2 | 'Alice Mwangi'   | 'alice.mwangi@example.com'
      4 | 'Brian Otieno'   | 'brian.otieno@example.com'
      9 | NULL             | 'unknown@example.com'
     13 | 'Hannah Schmidt' | 'hannah.schmidt@example.com'
     17 | 'Kevin Mutua'    | 'kevin.mutua@example.com'
```

| Function | What it does here |
|---|---|
| `trim(x)` | strips leading and trailing **spaces** |
| `regexp_replace(x, '\s+', ' ', 'g')` | collapses any run of whitespace to one space (`'g'` means every occurrence) |
| `lower(x)` | case-folds emails so `A@x.com` and `a@x.com` match |
| `NULLIF(x, '')` | turns an empty string into `NULL`, so "blank" and "missing" are one thing |
| `INITCAP(x)` | capitalises each word of a name |

Three cautions:

- **`trim` removes only spaces, not tabs or newlines.** Compare `length(trim(E'\tabc '))` (which is 4, the tab survived) with `length(regexp_replace(E'\tabc ', '^\s+|\s+$', '', 'g'))` (which is 3). When data comes from files or web forms, trim with the regex.
- **`INITCAP` is a blunt tool for names.** It turns `mcdonald` into `Mcdonald` and mishandles particles such as "van der". Use it for display tidiness, never as a matching key.
- **Match on the standardised email, not the name.** Email is the identifier; names are noisy. (Email local parts are technically case-sensitive, but virtually every provider treats them as insensitive. Confirm this holds for your system before you rely on it.)

## 6.4 Validate

Standardising fixes *format*. Validating decides whether the value is *usable*. A regular expression gives a practical first filter:

```sql
WITH cleaned AS (
    SELECT raw_id, NULLIF(lower(trim(email)), '') AS email
    FROM customers_raw
),
classified AS (
    SELECT raw_id,
           CASE WHEN email IS NULL                          THEN 'missing email'
                WHEN email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'  THEN 'malformed email'
                ELSE 'valid' END AS email_status
    FROM cleaned
)
SELECT email_status, COUNT(*) AS rows
FROM classified
GROUP BY email_status
ORDER BY email_status;
```

```
  email_status   | rows
-----------------+------
 malformed email |    1
 missing email   |    1
 valid           |   18
```

Reading the pattern `^[^@\s]+@[^@\s]+\.[^@\s]+$`: one or more characters that are neither `@` nor whitespace, then `@`, then the same again, then a literal dot, then the same again, anchored at both ends. `!~` means "does not match".

- **Order of the `CASE` branches matters.** `NULL` must be tested first, because `NULL !~ pattern` is `NULL`, not true.
- **This is a sanity check, not email validation.** It catches missing `@` and missing domain dots. It does not prove the mailbox exists, and the full email standard is far more permissive. Say so in your documentation.

## 6.5 Deduplicate

A duplicate here means *the same cleaned email*. `ROW_NUMBER` ranks the rows of each email so you can keep rank 1:

```sql
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
    WHERE email IS NOT NULL          -- see the NULL trap below
)
SELECT raw_id, full_name, email, loaded_at::date AS loaded_on
FROM ranked
WHERE rn = 1
ORDER BY email;
```

```
 raw_id |   full_name    |           email            | loaded_on
--------+----------------+----------------------------+------------
      2 | Alice Mwangi   | alice.mwangi@example.com   | 2026-02-10
      4 | Brian Otieno   | brian.otieno@example.com   | 2026-03-01
      5 | Carol Njeri    | carol.njeri@example.com    | 2026-01-07
      7 | Daniel Kiprop  | daniel.kiprop@example.com  | 2026-02-08
      8 | Esther Wafula  | esther.wafula@example.com  | 2026-01-09
     10 | Farah Ahmed    | farah.ahmed@example        | 2026-01-11
     13 | Hannah Schmidt | hannah.schmidt@example.com | 2026-03-14
     14 | Ibrahim Musa   | ibrahim.musa@example.com   | 2026-01-15
     15 | Julia Santos   | julia.santos@example.com   | 2026-01-16
     17 | Kevin Mutua    | kevin.mutua@example.com    | 2026-02-17
     18 | Linda Achieng  | linda.achieng@example.com  | 2026-01-18
     20 | Mark Otieno    | mark.otieno@example.com    | 2026-03-19
      9 |                | unknown@example.com        | 2026-01-10
```

19 rows with an email become 13. Notice the `ORDER BY loaded_at DESC, raw_id DESC`: **latest wins**, and `raw_id` breaks an exact timestamp tie so the result is repeatable.

### The `NULL` trap

Partitions treat all `NULL`s as **one group**. Two unrelated rows with no email would be ranked 1 and 2 as if they were duplicates, and one would be thrown away:

```sql
SELECT id, email,
       ROW_NUMBER() OVER (PARTITION BY email ORDER BY id) AS rn
FROM (VALUES (1, NULL::text), (2, NULL), (3, 'a@x.com')) AS v(id, email)
ORDER BY id;
```

```
 id |  email  | rn
----+---------+----
  1 |         |  1
  2 |         |  2
  3 | a@x.com |  1
```

A row without an email is not a duplicate of anything; it is simply unidentifiable. That is why the CTE above filters `WHERE email IS NOT NULL` first, and why such rows are *reported*, not silently deduplicated.

### The `DISTINCT ON` shortcut

PostgreSQL's `DISTINCT ON` does the same job in less code. Prove the two agree:

```
 window_rows | distinct_on_rows | differences
-------------+------------------+-------------
          13 |               13 |           0
```

The window version is more general (it extends to "top N" and to other databases); `DISTINCT ON` is a convenient PostgreSQL idiom for keep-one.

## 6.6 Survivorship: which duplicate wins is a policy

"Latest wins" is a **business decision**, not a technical fact, and it has a failure mode. Suppose a newer duplicate of Carol arrives with a blank name (we tested this inside a rolled-back transaction):

| Rule | `ORDER BY` | Surviving name |
|---|---|---|
| Latest wins | `loaded_at DESC` | `NULL`, because the newer record is blank and overwrites the good one |
| Most complete first | `(full_name IS NOT NULL) DESC, loaded_at DESC` | `Carol Njeri` |
| Merge fields | newest timestamp, but the latest *non-blank* name from any duplicate | `Carol Njeri`, last loaded 2026-04-01 |

Choose the rule deliberately, **write it in a comment at the top of the query**, and make sure the people who own the data agree. The merge approach can be written with `array_agg(full_name ORDER BY loaded_at DESC) FILTER (WHERE full_name IS NOT NULL)` and taking the first element; the stretch goals ask you to build it.

## 6.7 The whole pipeline, with reconciliation

Now chain the stages, and **account for every raw row**:

```sql
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
```

```
 kept | duplicates_removed | rejected | accounted_for | raw_rows
------+--------------------+----------+---------------+----------
   12 |                  6 |        2 |            20 |       20
```

**12 + 6 + 2 = 20.** Every raw row landed in exactly one outcome. This is the same reconciliation habit as Module 4, applied to cleaning. If `accounted_for` ever differs from `raw_rows`, rows are vanishing or being counted twice.

Two policy choices are visible here: a bad or missing email means **reject** (we cannot identify the person), while a blank name only means a `NULL` name (a repairable gap, so row 9 is kept).

### The audit trail

Never drop rows silently. List what was rejected, and why:

```sql
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
```

```
 raw_id |  reject_reason  |     cleaned_email
--------+-----------------+-----------------------
     10 | malformed email | 'farah.ahmed@example'
     11 | missing email   | NULL
```

Someone can now follow up on those two records instead of wondering where they went.

## 6.8 Cleaning checklist

| Principle | In practice |
|---|---|
| Raw data is immutable | Clean in a query or view; never `UPDATE` the source |
| One concern per CTE | standardise, classify, deduplicate are separate steps |
| State the grain | a comment on every CTE |
| Document the policy | survivorship rule and reject rules in comments |
| Reconcile | kept + duplicates + rejected = raw rows |
| Keep an audit trail | list rejected rows with a reason |
| Repeatable | explicit tiebreakers, so the same input always gives the same output |

## Common mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| `SELECT DISTINCT` on unstandardised data | Duplicates survive (17 vs 13) | Standardise first, then deduplicate |
| Deduplicating without excluding `NULL` keys | Unrelated rows discarded as "duplicates" | Filter `WHERE key IS NOT NULL` and report those rows separately |
| `ROW_NUMBER` with no tiebreaker | Result changes between runs | Add a unique column last |
| Treating `''` and `NULL` as different | Blank names slip past `IS NULL` checks | `NULLIF(trim(x), '')` |
| `trim` on data with tabs or newlines | Hidden whitespace remains | `regexp_replace(x, '^\s+\|\s+$', '', 'g')` |
| "Latest wins" without thinking | A newer blank record overwrites a good one | Choose a survivorship rule deliberately |
| Dropping rejected rows silently | Nobody knows data was lost | Produce an audit list and reconcile counts |
| Using `INITCAP` as a join key | Names like McDonald mismatch | Match on a clean identifier such as email |

## Key takeaways

- **Raw data is never edited.** Cleaning is a pipeline of CTEs: standardise, classify, deduplicate.
- Profile first, and make invisible characters visible with `quote_nullable()`.
- Standardise **before** deduplicating, or duplicates hide in plain sight.
- `ROW_NUMBER` keeps one row per key, but `NULL` keys form a single partition, so exclude and report them.
- Which duplicate wins is a **policy**: write it down.
- **Reconcile** every run (kept + duplicates + rejected = raw) and keep an audit list of rejects.

## Checkpoint

<details>
<summary>1. A table shows 17 distinct emails, yet cleaning leaves 13. What explains the difference?</summary>

Emails that differ only in case or surrounding whitespace are different strings but the same address. `DISTINCT` compares raw strings, so four duplicates were hidden until `lower(trim(...))` was applied.
</details>

<details>
<summary>2. Why can <code>ROW_NUMBER() OVER (PARTITION BY email ...)</code> wrongly discard rows?</summary>

All `NULL` emails fall into one partition, so every row after the first `NULL`-email row gets `rn > 1` and is discarded as a "duplicate" even though they are unrelated. Filter out `NULL` keys and handle them separately.
</details>

<details>
<summary>3. What is a survivorship rule, and why write it down?</summary>

It is the rule for deciding which duplicate record's values survive (latest wins, most complete wins, or merge fields). Different rules give different data (for example a newer blank record can erase a good name), so it is a business decision that should be agreed with the data owner and documented.
</details>

<details>
<summary>4. How do you know your cleaning pipeline did not lose rows?</summary>

Reconcile: count kept, duplicates removed and rejected rows, and check that they add up to the raw row count. Also list rejected rows with a reason as an audit trail.
</details>

**Next:** do the [exercises](exercises.md). Module 7 (Materialization & the Optimizer) is coming soon, and it begins the Advanced tier.
