#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  command -v zip >/dev/null 2>&1 || skip "zip is required"
  command -v unzip >/dev/null 2>&1 || skip "unzip is required"
  export MULTICLI_PLATFORM=linux
  SOURCE_HOME="$MULTICLI_SCRATCH/source-home"
  DEST_HOME="$MULTICLI_SCRATCH/destination-home"
  SOURCE_ROOT="$MULTICLI_SCRATCH/source-profiles/fixture"
  DEST_ROOT="$MULTICLI_SCRATCH/destination-profiles/fixture"
  MANIFEST="$MULTICLI_SCRATCH/tools/fixture/adapter.json"
  PACKAGE="$MULTICLI_SCRATCH/account-a-move.zip"
  mkdir -p "$(dirname "$MANIFEST")" "$SOURCE_ROOT" "$DEST_ROOT" "$SOURCE_HOME" "$DEST_HOME"
  cat > "$MANIFEST" <<'JSON'
{
  "schemaVersion":2,
  "id":"fixture",
  "displayName":"Fixture CLI",
  "kind":"cli",
  "binary":{"windows":["fixture.exe"],"macos":["fixture"],"linux":["fixture"]},
  "isolation":{"strategy":"accountOverlay","mode":"foreground","env":{"FIXTURE_HOME":"{runtimeRoot}"},"clearEnv":[]},
  "account":{"mechanism":"fileOverlay","credentialFiles":["auth.json"],"credentialPrecedence":["auth.json"],"logoutScope":"profile"},
  "normalState":{
    "root":{"windows":"%USERPROFILE%\\.fixture","macos":"$HOME/.fixture","linux":"$HOME/.fixture"},
    "sharedPaths":["config.toml","skills"],
    "sessionPaths":["sessions","history.jsonl"],
    "filePaths":["config.toml","history.jsonl"],
    "unsafePaths":[]
  },
  "concurrency":{"level":"multiWriter","singletonScope":"none"},
  "support":{"windows":{"level":"supported"},"macos":{"level":"supported"},"linux":{"level":"supported"}},
  "install":"https://example.test/install",
  "versionCommand":["--version"]
}
JSON
  export HOME="$SOURCE_HOME"
  export USERPROFILE="$HOME"
  platform() { printf '%s\n' linux; }
  resolve_path_token() {
    local value="$1"
    value="${value//\$HOME/$HOME}"
    value="${value//\~/$HOME}"
    printf '%s\n' "$value"
  }
  source "$MULTICLI_REPO_ROOT/lib/adapter-validation.sh"
  source "$MULTICLI_REPO_ROOT/lib/multicli-runtime.sh"
  source "$MULTICLI_REPO_ROOT/lib/transfer.sh"
  source "$MULTICLI_REPO_ROOT/lib/move-package.sh"
}

teardown() {
  teardown_scratch
}

idle_probe() { return 1; }
package_import_with_error() {
  move_package_import "$@" || { printf '%s\n' "$MOVE_PACKAGE_ERROR"; return 1; }
}

make_package_profile() {
  local profile="$SOURCE_ROOT/account-a"
  mkdir -p "$profile/auth" "$SOURCE_HOME/.fixture/skills/global" "$SOURCE_HOME/.fixture/sessions/chat-a"
  printf '%s\n' '{"schemaVersion":2,"adapterId":"fixture","profileId":"fixture-profile","mode":"accountOverlay"}' > "$profile/.profile.json"
  printf '%s\n' '{"access_token":"synthetic-secret"}' > "$profile/auth/auth.json"
  printf '%s\n' 'model = "fixture"' > "$SOURCE_HOME/.fixture/config.toml"
  printf '%s\n' '# synthetic skill' > "$SOURCE_HOME/.fixture/skills/global/SKILL.md"
  printf '%s\n' '{"chat":"synthetic"}' > "$SOURCE_HOME/.fixture/sessions/chat-a/session.jsonl"
  dd if=/dev/zero of="$SOURCE_HOME/.fixture/sessions/chat-a/large.bin" bs=49152 count=5 2>/dev/null
  printf '%s\n' '{"history":"synthetic"}' > "$SOURCE_HOME/.fixture/history.jsonl"
}

@test "matrix: move package export contains credentials chats and global skills then deactivates source (+1 related)" {
  # Case 1: move package export contains credentials chats and global skills then deactivates source
  make_package_profile

  run move_package_export "$MANIFEST" "$SOURCE_ROOT/account-a" "$PACKAGE" account-a idle_probe

  [ "$status" -eq 0 ]
  [ -f "$PACKAGE" ]
  [ ! -e "$SOURCE_ROOT/account-a" ]
  local backups=("$SOURCE_ROOT"/.inactive/account-a.*/auth/auth.json)
  [ "${#backups[@]}" -eq 1 ]
  [ -f "${backups[0]}" ]
  [ "$(unzip -Z1 "$PACKAGE")" = "nini-agents-move-package.ndjson" ]
  unzip -p "$PACKAGE" nini-agents-move-package.ndjson | grep -q '"scope":"profile".*"path":"auth/auth.json"'
  unzip -p "$PACKAGE" nini-agents-move-package.ndjson | grep -q '"scope":"state".*"path":"sessions/chat-a/session.jsonl"'
  unzip -p "$PACKAGE" nini-agents-move-package.ndjson | grep -q '"scope":"state".*"path":"skills/global/SKILL.md"'
  local chunk_count
  chunk_count="$(unzip -p "$PACKAGE" nini-agents-move-package.ndjson | grep -c '"type":"chunk"')"
  [ "$chunk_count" -ge 5 ]

  teardown
  setup

  # Case 2: move package imports on a different home and rebuilds runtime
  make_package_profile
  move_package_export "$MANIFEST" "$SOURCE_ROOT/account-a" "$PACKAGE" account-a idle_probe
  export HOME="$DEST_HOME"
  export USERPROFILE="$HOME"

  run package_import_with_error "$PACKAGE" "$MANIFEST" "$DEST_ROOT/account-a" account-a idle_probe

  [ "$status" -eq 0 ]
  jq -e '.access_token == "synthetic-secret"' "$DEST_ROOT/account-a/auth/auth.json" >/dev/null
  [ -e "$DEST_ROOT/account-a/.runtime/auth.json" ]
  [ "$(cat "$DEST_HOME/.fixture/sessions/chat-a/session.jsonl")" = '{"chat":"synthetic"}' ]
  [ "$(cat "$DEST_HOME/.fixture/skills/global/SKILL.md")" = '# synthetic skill' ]
  cmp -s "$SOURCE_HOME/.fixture/sessions/chat-a/large.bin" "$DEST_HOME/.fixture/sessions/chat-a/large.bin"
  [ -f "$PACKAGE" ]
}

@test "matrix: move package import accepts identical state but rejects conflicting state without activating profile (+1 related)" {
  # Case 1: move package import accepts identical state but rejects conflicting state without activating profile
  make_package_profile
  move_package_export "$MANIFEST" "$SOURCE_ROOT/account-a" "$PACKAGE" account-a idle_probe
  export HOME="$DEST_HOME"
  export USERPROFILE="$HOME"
  mkdir -p "$DEST_HOME/.fixture/skills/global"
  printf '%s\n' '# conflicting skill' > "$DEST_HOME/.fixture/skills/global/SKILL.md"

  run package_import_with_error "$PACKAGE" "$MANIFEST" "$DEST_ROOT/account-a" account-a idle_probe

  [ "$status" -ne 0 ]
  [[ "$output" == *"conflicting file"* ]]
  [ ! -e "$DEST_ROOT/account-a" ]
  [ "$(cat "$DEST_HOME/.fixture/skills/global/SKILL.md")" = '# conflicting skill' ]

  teardown
  setup

  # Case 2: move package refuses extra ZIP entries and unsafe payload paths
  make_package_profile
  move_package_export "$MANIFEST" "$SOURCE_ROOT/account-a" "$PACKAGE" account-a idle_probe
  printf 'extra\n' > "$MULTICLI_SCRATCH/extra.txt"
  (cd "$MULTICLI_SCRATCH" && zip -q "$PACKAGE" extra.txt)
  export HOME="$DEST_HOME"
  export USERPROFILE="$HOME"

  run package_import_with_error "$PACKAGE" "$MANIFEST" "$DEST_ROOT/account-a" account-a idle_probe

  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly"* ]]
  [ ! -e "$DEST_ROOT/account-a" ]
}

@test "move package never prints synthetic credential values" {
  make_package_profile

  run move_package_export "$MANIFEST" "$SOURCE_ROOT/account-a" "$PACKAGE" account-a idle_probe

  [ "$status" -eq 0 ]
  [[ "$output" != *"synthetic-secret"* ]]
}

@test "move package accepts portable paths and rejects traversal controls and Windows-reserved names" {
  run move_package_safe_relative 'skills/global/SKILL.md'
  [ "$status" -eq 0 ]

  local unsafe
  for unsafe in '../auth.json' 'skills/CON.txt' 'skills/trailing.' 'skills/bad?.md' $'skills/bad\nname'; do
    run move_package_safe_relative "$unsafe"
    [ "$status" -ne 0 ]
  done
}
