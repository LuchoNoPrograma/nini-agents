#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${BASH_COVERAGE_OUTPUT:-$REPO_ROOT/tests/coverage/out/bash}"
MINIMUM_PERCENT="${BASH_COVERAGE_MINIMUM:-95}"
BASELINE="${COVERAGE_BASELINE:-HEAD^}"
CHANGED_REPORT="$REPO_ROOT/tests/coverage/out/bash-changed-lines.json"

command -v bashcov >/dev/null 2>&1 || {
  echo "bashcov is required for Bash coverage." >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required to enforce the Bash coverage threshold." >&2
  exit 2
}

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
(
  cd "$REPO_ROOT"
  bashcov --root "$REPO_ROOT" -- "$REPO_ROOT/tests/run-bats.sh"
)

SUMMARY="$OUTPUT_DIR/.resultset.json"
[ -f "$SUMMARY" ] || {
  echo "bashcov did not write $SUMMARY." >&2
  exit 1
}
COBERTURA="$OUTPUT_DIR/cobertura.xml"
python3 "$SCRIPT_DIR/simplecov_to_cobertura.py" \
  --input "$SUMMARY" \
  --repo "$REPO_ROOT" \
  --output "$COBERTURA" \
  --pathspec multi-cli \
  --pathspec 'lib/*.sh' \
  --pathspec 'scripts/*.sh'

python3 "$SCRIPT_DIR/check_changed_coverage.py" \
  --repo "$REPO_ROOT" \
  --baseline "$BASELINE" \
  --coverage-root "$COBERTURA" \
  --minimum "$MINIMUM_PERCENT" \
  --output "$CHANGED_REPORT" \
  --pathspec multi-cli \
  --pathspec 'lib/*.sh' \
  --pathspec 'scripts/*.sh'

python3 - "$COBERTURA" "$MINIMUM_PERCENT" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
minimum = float(sys.argv[2])
lines = root.findall(".//line")
executable = len(lines)
covered = sum(int(float(line.get("hits", "0"))) > 0 for line in lines)
if executable == 0:
    raise SystemExit("Bash coverage gate FAILED: no production lines were analyzed.")
percent = 100.0 * covered / executable
if percent < minimum:
    raise SystemExit(f"Bash coverage gate FAILED: {percent:.2f}% is below {minimum:.2f}%.")
print(f"Bash coverage gate passed: {percent:.2f}% >= {minimum:.2f}%.")
PY

echo "Bash coverage report: $OUTPUT_DIR/index.html"
echo "Changed-line report: $CHANGED_REPORT"
