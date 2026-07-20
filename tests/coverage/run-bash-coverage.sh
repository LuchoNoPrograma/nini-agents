#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${BASH_COVERAGE_OUTPUT:-$REPO_ROOT/tests/coverage/out/bash}"

command -v kcov >/dev/null 2>&1 || {
  echo "kcov is required for Bash coverage." >&2
  exit 2
}

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
kcov \
  --include-path="$REPO_ROOT/multi-cli,$REPO_ROOT/lib,$REPO_ROOT/scripts" \
  "$OUTPUT_DIR" \
  "$REPO_ROOT/tests/run-bats.sh"

echo "Bash coverage report: $OUTPUT_DIR/index.html"
