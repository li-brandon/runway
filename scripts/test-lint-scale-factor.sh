#!/bin/sh
# Runs lint-scale-factor.sh on its fixtures. The pass fixtures must be clean. The fail fixtures must
# produce exactly the file:line list stated by each file's `// Expected violations: <lines>` comment.
#
# Prints PASS or FAIL for each check. Exits 0 if all pass, 1 otherwise.

scripts="$(dirname "$0")"
lint="$scripts/lint-scale-factor.sh"
fixtures="$scripts/lint-scale-factor-fixtures"
failed=0

pass() {
  echo "PASS: $1"
}

fail() {
  echo "FAIL: $1"
  failed=1
}

# Prints the sorted file:line list from the lint output on stdin.
locations() {
  cut -d : -f 1,2 | LC_ALL=C sort
}

# Prints the sorted file:line list stated by the fixtures, or a NO-EXPECTATION entry for a file
# that doesn't state one.
expected_locations() {
  (
    cd -- "$fixtures/fail" || exit 2
    find Runway -type f -name '*.swift' -exec awk '
      function finish() {
        if (file != "" && !found) print file ":NO-EXPECTATION"
      }
      FNR == 1 { finish(); file = FILENAME; found = 0 }
      /^\/\/ Expected violations:/ {
        found = 1
        sub(/^\/\/ Expected violations:/, "")
        n = split($0, lines, /[ ,]+/)
        for (i = 1; i <= n; i++) if (lines[i] != "") print file ":" lines[i]
      }
      END { finish() }
    ' {} +
  ) | LC_ALL=C sort
}

output="$(sh "$lint" "$fixtures/pass" 2>/dev/null)"
status=$?
if [ "$status" -eq 0 ] && [ -z "$output" ]; then
  pass "pass fixtures are clean"
else
  fail "pass fixtures: expected exit 0 and no output, got exit $status"
  printf '%s\n' "$output"
fi

output="$(sh "$lint" "$fixtures/fail" 2>/dev/null)"
status=$?
if [ "$status" -eq 1 ]; then
  pass "fail fixtures exit 1"
else
  fail "fail fixtures: expected exit 1, got exit $status"
fi

actual="$(printf '%s\n' "$output" | locations)"
expected="$(expected_locations)"
if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
  pass "fail fixtures report exactly the expected lines"
else
  fail "fail fixtures: reported lines differ from expected"
  echo "--- expected"
  printf '%s\n' "$expected"
  echo "--- actual"
  printf '%s\n' "$actual"
fi

sh "$lint" "$fixtures/does-not-exist" >/dev/null 2>&1
status=$?
if [ "$status" -eq 2 ]; then
  pass "missing root exits 2"
else
  fail "missing root: expected exit 2, got exit $status"
fi

exit "$failed"
