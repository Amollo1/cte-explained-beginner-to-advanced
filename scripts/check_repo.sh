#!/usr/bin/env bash
# Repository checks that need NO database. Run from anywhere:   bash scripts/check_repo.sh
# They catch the file-level mistakes that make the test run fail for reasons that have
# nothing to do with the SQL itself (a missing file, Windows line endings, a half-extracted zip).
set -uo pipefail
cd "$(dirname "$0")/.."

problems=0
note() { echo "PROBLEM: $*"; problems=$((problems + 1)); }

# 1. Every solution file has an expected-output file, and the other way round.
for f in $(ls [0-9][0-9]-*/[0-9][0-9]-[0-9][0-9].sql 2>/dev/null); do
  [[ -f "${f%.sql}.expected" ]] || note "missing expected-output file: ${f%.sql}.expected"
done
for f in $(ls [0-9][0-9]-*/[0-9][0-9]-[0-9][0-9].expected 2>/dev/null); do
  [[ -f "${f%.expected}.sql" ]] || note "expected-output file without a solution: $f"
done

# 2. Every module folder has its standard files and at least one solution.
modules=0
for d in [0-9][0-9]-*/; do
  d="${d%/}"; modules=$((modules + 1))
  for need in lesson.md examples.sql exercises.md; do
    [[ -f "$d/$need" ]] || note "$d is missing $need"
  done
  ls "$d"/[0-9][0-9]-[0-9][0-9].sql >/dev/null 2>&1 || note "$d has no solution files (NN-NN.sql)"
done

# 3. No Windows (CRLF) line endings in files the tests read.
while IFS= read -r f; do
  note "Windows (CRLF) line endings in $f"
done < <(grep -rlI $'\r' --include='*.sql' --include='*.expected' --include='*.sh' --include='*.yml' --include='*.md' . --exclude-dir=.git 2>/dev/null)

# 4. Files the test run depends on.
for need in scripts/run_all.sh data/schema_and_data.sql .github/workflows/test.yml; do
  [[ -f "$need" ]] || note "missing $need"
done

# 5. Practice-data safety: course SQL must never COMMIT, and every BEGIN must be matched by a ROLLBACK.
for f in [0-9][0-9]-*/*.sql; do
  [[ -f "$f" ]] || continue
  if grep -qiE '^[[:space:]]*COMMIT[[:space:]]*;' "$f"; then
    note "$f contains COMMIT; course SQL must never commit changes to the practice data"
  fi
  b=$(grep -ciE '^[[:space:]]*BEGIN[[:space:]]*;' "$f"); r=$(grep -ciE '^[[:space:]]*ROLLBACK[[:space:]]*;' "$f")
  [[ "$b" -eq "$r" ]] || note "$f has $b BEGIN and $r ROLLBACK statements; they must match"
done

sols=$(ls [0-9][0-9]-*/[0-9][0-9]-[0-9][0-9].sql 2>/dev/null | wc -l)
echo "Checked $modules module folders and $sols solution files."
if [[ $problems -eq 0 ]]; then echo "Repository check passed."; else echo "$problems problem(s) found."; exit 1; fi
