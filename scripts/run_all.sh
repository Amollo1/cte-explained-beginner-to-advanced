#!/usr/bin/env bash
# Runs every examples.sql (must succeed) and every exercise solution NN-NN.sql
# (must succeed AND match its .expected file).
#   ./scripts/run_all.sh            run the checks
#   ./scripts/run_all.sh --update   regenerate .expected files (review the diff!)
set -uo pipefail
cd "$(dirname "$0")/.."

export PGHOST="${PGHOST:-localhost}" PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"  PGDATABASE="${PGDATABASE:-cte_lab}"
UPDATE=0; [[ "${1:-}" == "--update" ]] && UPDATE=1
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -A -F '|')
pass=0; fail=0; err=$(mktemp)

for f in $(ls [0-9][0-9]-*/examples.sql 2>/dev/null | sort); do
  if "${PSQL[@]}" -f "$f" >/dev/null 2>"$err"; then
    echo "PASS  $f"; ((pass++))
  else
    echo "FAIL  $f"; sed 's/^/      /' "$err"; ((fail++))
  fi
done

for f in $(ls [0-9][0-9]-*/[0-9][0-9]-[0-9][0-9].sql 2>/dev/null | sort); do
  exp="${f%.sql}.expected"
  if ! out=$("${PSQL[@]}" -f "$f" 2>"$err"); then
    echo "FAIL  $f (SQL error)"; sed 's/^/      /' "$err"; ((fail++)); continue
  fi
  if [[ $UPDATE -eq 1 ]]; then
    if printf '%s\n' "$out" > "$exp"; then echo "WROTE $exp"; ((pass++)); else echo "FAIL  cannot write $exp"; ((fail++)); fi
  elif [[ -f "$exp" ]] && diff -u "$exp" <(printf '%s\n' "$out") >/dev/null; then
    echo "PASS  $f"; ((pass++))
  else
    echo "FAIL  $f (output differs from $exp)"
    [[ -f "$exp" ]] && diff -u "$exp" <(printf '%s\n' "$out") | head -20
    ((fail++))
  fi
done

rm -f "$err"
echo "----"; echo "passed: $pass   failed: $fail"
[[ $fail -eq 0 ]]
