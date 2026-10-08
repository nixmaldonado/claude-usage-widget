#!/usr/bin/env bash
# Runs the usage parser on saved API responses and diffs against the expected
# output. A fixture without a .expected file must be rejected by the parser.
#   bash tests/run.sh /Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage
set -uo pipefail
[[ $# -eq 1 ]] || { echo "usage: tests/run.sh path/to/ClaudeUsage" >&2; exit 2; }
bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
cd "$(dirname "$0")/fixtures"

fail=0
for input in *.json; do
  name="${input%.json}"
  if [[ -f "$name.expected" ]]; then
    if diff -u "$name.expected" <("$bin" --parse "$input"); then
      echo "ok    $name"
    else
      echo "FAIL  $name"; fail=1
    fi
  elif "$bin" --parse "$input" >/dev/null 2>&1; then
    echo "FAIL  $name (should have been rejected)"; fail=1
  else
    echo "ok    $name (rejected)"
  fi
done
exit $fail
