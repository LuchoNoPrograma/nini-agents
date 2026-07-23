#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${BASH_COVERAGE_OUTPUT:-$REPO_ROOT/tests/coverage/out/bash}"
MINIMUM_PERCENT="${BASH_COVERAGE_MINIMUM:-95}"
BASELINE="${COVERAGE_BASELINE:-HEAD^}"
CHANGED_REPORT="$REPO_ROOT/tests/coverage/out/bash-changed-lines.json"

command -v kcov >/dev/null 2>&1 || {
  echo "kcov is required for Bash coverage." >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required to enforce the Bash coverage threshold." >&2
  exit 2
}

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
kcov \
  --bash-method=DEBUG \
  --include-path="$REPO_ROOT/multi-cli,$REPO_ROOT/lib,$REPO_ROOT/scripts" \
  "$OUTPUT_DIR" \
  "$REPO_ROOT/tests/run-bats.sh"

SUMMARY="$(find "$OUTPUT_DIR" -name coverage.json -type f -print -quit)"
[ -n "$SUMMARY" ] || {
  echo "kcov did not write coverage.json under $OUTPUT_DIR." >&2
  exit 1
}
python3 - "$SUMMARY" "$MINIMUM_PERCENT" <<'PY'
import json
import sys
from pathlib import Path

summary_path = Path(sys.argv[1])
minimum = float(sys.argv[2])
summary = json.loads(summary_path.read_text(encoding="utf-8"))
percent = float(summary["percent_covered"])
if percent < minimum:
    raise SystemExit(f"Bash coverage gate FAILED: {percent:.2f}% is below {minimum:.2f}%.")
print(f"Bash coverage gate passed: {percent:.2f}% >= {minimum:.2f}%.")
PY

python3 "$SCRIPT_DIR/check_changed_coverage.py" \
  --repo "$REPO_ROOT" \
  --baseline "$BASELINE" \
  --coverage-root "$OUTPUT_DIR" \
  --minimum "$MINIMUM_PERCENT" \
  --output "$CHANGED_REPORT" \
  --pathspec multi-cli \
  --pathspec 'lib/*.sh' \
  --pathspec 'scripts/*.sh'

echo "Bash coverage report: $OUTPUT_DIR/index.html"
echo "Changed-line report: $CHANGED_REPORT"
