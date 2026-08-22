#!/usr/bin/env bats
# Real-execution tests for the shell aliases `nini-agents new` writes into
# $MULTICLI_HOME/bin. The launcher path can live under a directory with
# spaces, so the generated exec line must quote it, not backslash-escape it
# inside double quotes (a backslash-space is literal inside "...").

load helpers/common

setup() {
  setup_scratch
}

teardown() {
  teardown_scratch
}

@test "alias script execs the launcher correctly when the repo path contains spaces" {
  local spaced="$MULTICLI_SCRATCH/dir with spaces"
  bash -c "
    set -- help
    source '$MULTICLI_BIN' >/dev/null 2>&1
    SCRIPT_DIR='$spaced'
    create_shell_alias codex work
  "
  local alias_file="$MULTICLI_HOME/bin/codex-work"
  [ -f "$alias_file" ]
  # No backslash-escaping inside the quoted paths: bash would pass the
  # backslashes through literally and the exec target would not exist.
  run grep -F '\' "$alias_file"
  [ "$status" -eq 1 ]
  [[ "$(cat "$alias_file")" == *"exec \"$spaced/nini-agents\" launch \"codex/work\" \"\$@\""* ]]
  bash -n "$alias_file"
}
