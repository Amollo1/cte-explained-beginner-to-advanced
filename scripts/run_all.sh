#!/usr/bin/env bash
# Runs every examples.sql (must succeed) and every exercise solution NN-NN.sql
# (must succeed AND match its .expected file).
#   bash scripts/run_all.sh            run the checks
#   bash scripts/run_all.sh --update   regenerate .expected files (review the diff!)
set -uo pipefail
cd "$(dirname "$0")/.."

export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"  PGDATABASE="${PGDATABASE:-cte_lab}"
UPDATE=0; [[ "${1:-}" == "--update" ]] && UPDATE=1
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -A -F '|')
pass=0; fail=0; failed=(); err=$(mktemp)

# --- Environment report: makes a failure that only happens on CI easy to diagnose.
echo "== Environment =="
psql --version
if ! psql -X -q -At -c "select 'server:   ' || version()" 2>"$err"; then
  echo "CANNOT CONNECT to PostgreSQL ($PGUSER@$PGHOST:$PGPORT, database $PGDATABASE):"
  sed 's/^/  /' "$err"; rm -f "$err"; exit 2
fi
psql -X -q -At -c "select 'database: ' || pg_encoding_to_char(encoding) || ' / collation ' || datcollate from pg_database where datname = current_database()"
# --- Practice-data fingerprint: a hash of the CONTENT of every table (row order does not matter).
# The run must leave the data exactly as it found it. A solution that changes data must undo it (ROLLBACK).
data_fingerprint() {
  psql -X -q -At -F ' ' <<'SQL'
SELECT t.table_name,
       (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I', t.table_name), false, true, '')))[1]::text AS row_count,
       left(md5(coalesce((xpath('/row/h/text()', query_to_xml(format('select md5(string_agg(x::text, ''|'' order by x::text)) as h from %I x', t.table_name), false, true, '')))[1]::text, '')), 8) AS content_hash
FROM information_schema.tables t
WHERE t.table_schema = 'public' AND t.table_type = 'BASE TABLE'
ORDER BY 1;
SQL
}
fp_before=$(data_fingerprint)
echo "== Running checks =="

for f in $(ls [0-9][0-9]-*/examples.sql 2>/dev/null | sort); do
  if "${PSQL[@]}" -f "$f" >/dev/null 2>"$err"; then
    echo "PASS  $f"; ((pass++))
  else
    echo "FAIL  $f (the SQL raised an error)"; sed 's/^/      /' "$err"
    ((fail++)); failed+=("$f")
  fi
done

for f in $(ls [0-9][0-9]-*/[0-9][0-9]-[0-9][0-9].sql 2>/dev/null | sort); do
  exp="${f%.sql}.expected"
  if ! out=$("${PSQL[@]}" -f "$f" 2>"$err"); then
    echo "FAIL  $f (the SQL raised an error)"; sed 's/^/      /' "$err"
    ((fail++)); failed+=("$f"); continue
  fi
  if [[ $UPDATE -eq 1 ]]; then
    if printf '%s\n' "$out" > "$exp"; then echo "WROTE $exp"; ((pass++)); else echo "FAIL  cannot write $exp"; ((fail++)); failed+=("$f"); fi
  elif [[ ! -f "$exp" ]]; then
    echo "FAIL  $f (the expected-output file $exp is MISSING from the repository)"
    ((fail++)); failed+=("$f")
  elif diff -u "$exp" <(printf '%s\n' "$out") >/dev/null; then
    echo "PASS  $f"; ((pass++))
  else
    echo "FAIL  $f (output differs from $exp)"
    grep -q $'\r' "$exp" && echo "      note: $exp has Windows (CRLF) line endings; it must use Unix (LF)"
    diff -u "$exp" <(printf '%s\n' "$out") | head -40 | sed 's/^/      /'
    ((fail++)); failed+=("$f")
  fi
done

# --- Did the run leave the practice data exactly as it found it?
fp_after=$(data_fingerprint)
if [[ "$fp_before" == "$fp_after" ]]; then
  echo "PASS  practice data unchanged by the run"; ((pass++))
else
  echo "FAIL  the practice data was MODIFIED by the files above (a change was not rolled back)"
  diff <(printf '%s\n' "$fp_before") <(printf '%s\n' "$fp_after") | grep '^[<>]' | sed 's/^/      /'
  echo "      reload the data with:  psql -f data/schema_and_data.sql"
  ((fail++)); failed+=("practice-data check")
fi

rm -f "$err"
echo "----"; echo "passed: $pass   failed: $fail"
if [[ $fail -gt 0 ]]; then printf 'FAILED: %s\n' "${failed[@]}"; fi
[[ $fail -eq 0 ]]
