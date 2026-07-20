#!/usr/bin/env bats
# Real-execution tests for scripts/uninstall.sh. install.sh writes a regular
# launcher FILE (not a symlink) at MULTICLI_BIN_LINK; uninstall must remove
# that file as well as legacy symlinks, and leave foreign files alone.

load helpers/common

setup() {
  setup_scratch
  export MULTICLI_INSTALL_DIR="$MULTICLI_SCRATCH/install"
  export MULTICLI_BIN_LINK="$MULTICLI_SCRATCH/bin/multi-cli"
  export MULTICLI_HOME="$MULTICLI_SCRATCH/profiles-removed"
  mkdir -p "$(dirname "$MULTICLI_BIN_LINK")"
}

teardown() {
  unset MULTICLI_INSTALL_DIR MULTICLI_BIN_LINK
  teardown_scratch
}

# Run the uninstaller, declining the install-dir and profile-dir prompts.
run_uninstall() {
  printf 'n\nn\n' | bash "$MULTICLI_REPO_ROOT/scripts/uninstall.sh"
}

@test "uninstall removes the regular-file launcher written by install.sh" {
  printf '#!/usr/bin/env bash\nexec "%s/multi-cli" "$@"\n' "$MULTICLI_INSTALL_DIR" > "$MULTICLI_BIN_LINK"
  chmod +x "$MULTICLI_BIN_LINK"

  run run_uninstall

  [ "$status" -eq 0 ]
  [ ! -e "$MULTICLI_BIN_LINK" ]
}

@test "uninstall removes a symlink launcher" {
  local target="$MULTICLI_SCRATCH/install/multi-cli"
  mkdir -p "$MULTICLI_SCRATCH/install"
  printf '#!/usr/bin/env bash\nexec "/opt/multi-cli/multi-cli" "$@"\n' > "$target"
  ln -s "$target" "$MULTICLI_BIN_LINK" 2>/dev/null
  [ -L "$MULTICLI_BIN_LINK" ] || skip "host has no real symlinks (MSYS ln -s copies)"

  run run_uninstall

  [ "$status" -eq 0 ]
  [ ! -e "$MULTICLI_BIN_LINK" ]
}

@test "uninstall leaves an unrelated file at the launcher path alone" {
  printf 'echo unrelated\n' > "$MULTICLI_BIN_LINK"

  run run_uninstall

  [ "$status" -eq 0 ]
  [ -f "$MULTICLI_BIN_LINK" ]
}
