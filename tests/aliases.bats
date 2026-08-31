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
  local short_alias_file="$MULTICLI_HOME/bin/work"
  [ -f "$alias_file" ]
  [ -f "$short_alias_file" ]
  # No backslash-escaping inside the quoted paths: bash would pass the
  # backslashes through literally and the exec target would not exist.
  run grep -F '\' "$alias_file"
  [ "$status" -eq 1 ]
  [[ "$(cat "$alias_file")" == *"exec \"$spaced/nini-agents\" launch \"codex/work\" \"\$@\""* ]]
  grep -Fq "export MULTICLI_HOME=$MULTICLI_HOME" "$alias_file"
  cmp -s "$alias_file" "$short_alias_file"
  bash -n "$alias_file"
  bash -n "$short_alias_file"
}

@test "alias creation rejects a canonical symlink without changing its target" {
  local outside="$MULTICLI_SCRATCH/outside"
  mkdir -p "$MULTICLI_HOME/bin"
  printf 'keep me\n' > "$outside"
  ln -s "$outside" "$MULTICLI_HOME/bin/codex-work"

  run bash -c "
    set -- help
    source '$MULTICLI_BIN' >/dev/null 2>&1
    create_shell_alias codex work
  "

  [ "$status" -ne 0 ]
  [ -L "$MULTICLI_HOME/bin/codex-work" ]
  [ "$(cat "$outside")" = "keep me" ]
  [ ! -e "$MULTICLI_HOME/bin/work" ]
}
