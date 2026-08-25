#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  export USERPROFILE="$HOME"
  export APPDATA="$HOME/AppData/Roaming"
  export LOCALAPPDATA="$HOME/AppData/Local"
  mkdir -p "$MULTICLI_TOOLS_DIR/codex" "$MULTICLI_SCRATCH/local/codex" "$MULTICLI_SCRATCH/remote/codex" "$MULTICLI_SCRATCH/fake-bin"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$MULTICLI_TOOLS_DIR/codex/adapter.json"

  cat > "$MULTICLI_SCRATCH/fake-bin/nini-agents" <<WRAPPER
#!/usr/bin/env bash
exec "$MULTICLI_BIN" "\$@"
WRAPPER
  chmod +x "$MULTICLI_SCRATCH/fake-bin/nini-agents"
  cat > "$MULTICLI_SCRATCH/fake-bin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
[ "$#" -gt 0 ] || exit 2
shift
command_line="$*"
exec bash -c "$command_line"
FAKE_SSH
  chmod +x "$MULTICLI_SCRATCH/fake-bin/ssh"

  cat > "$MULTICLI_SCRATCH/fake-copy" <<'FAKE_COPY'
#!/usr/bin/env bash
set -euo pipefail
direction=$1
source=$2
ssh_target=$3
destination=$4
[ "$ssh_target" = fixture-remote ]
[ "$direction" = to-remote ] || [ "$direction" = from-remote ]
cp -pR -- "$source"/. "$destination"/
rm -rf -- "$destination/.runtime"
if [ "${NINI_AGENTS_TEST_TAMPER_COPY:-0}" = 1 ]; then
  printf 'tampered\n' >> "$destination/config.toml"
fi
FAKE_COPY
  chmod +x "$MULTICLI_SCRATCH/fake-copy"

  export PATH="$MULTICLI_SCRATCH/fake-bin:$PATH"
  export NINI_AGENTS_SSH_COMMAND="$MULTICLI_SCRATCH/fake-bin/ssh"
  export NINI_AGENTS_TEST_REMOTE_COPY_COMMAND="$MULTICLI_SCRATCH/fake-copy"
  export NINI_AGENTS_DEVICES_CONFIG="$MULTICLI_SCRATCH/devices.conf"
  cat > "$NINI_AGENTS_DEVICES_CONFIG" <<CONFIG
this_device|mint
profiles_home|$MULTICLI_SCRATCH/local
device|ubuntu|fixture-remote|$MULTICLI_SCRATCH/remote
CONFIG
}

teardown() {
  unset NINI_AGENTS_SSH_COMMAND NINI_AGENTS_TEST_REMOTE_COPY_COMMAND NINI_AGENTS_TEST_TAMPER_COPY NINI_AGENTS_TEST_FAIL_BACKUP_DISCARD NINI_AGENTS_DEVICES_CONFIG
  teardown_scratch
}

make_legacy_profile() {
  local root="$1" name="${2:-account-a}"
  mkdir -p "$root/$name"
  printf '{"tokens":{"access_token":"fixture-secret"}}\n' > "$root/$name/auth.json"
  printf 'model = "fixture"\n' > "$root/$name/config.toml"
}

@test "public move dry-run proves one owner without creating transaction artifacts" {
  make_legacy_profile "$MULTICLI_SCRATCH/local/codex"

  run multicli move codex/account-a ubuntu --dry-run

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [[ "$output" == *"no files were copied or activated"* ]]
  [ -d "$MULTICLI_SCRATCH/local/codex/account-a" ]
  [ ! -e "$MULTICLI_SCRATCH/remote/codex/account-a" ]
  [ ! -e "$MULTICLI_SCRATCH/remote/codex/.staging" ]
}

@test "device registry list status and doctor use the same Nini endpoint" {
  make_legacy_profile "$MULTICLI_SCRATCH/local/codex"

  run multicli devices list codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"account-a"* ]]

  run multicli devices status codex/account-a
  [ "$status" -eq 0 ]
  [[ "$output" == *"mint: active"* ]]
  [[ "$output" == *"ubuntu: absent"* ]]

  run multicli devices doctor codex
  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [[ "$output" == *"ubuntu: ready"* ]]
}

@test "remote endpoint uses the standard user-local launcher outside SSH PATH" {
  mkdir -p "$HOME/.local/bin"
  mv "$MULTICLI_SCRATCH/fake-bin/nini-agents" "$HOME/.local/bin/nini-agents"

  run env PATH=/usr/bin:/bin "$MULTICLI_BIN" devices doctor codex

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [[ "$output" == *"ubuntu: ready"* ]]
}

@test "public move performs a verified round trip and never prunes prior backups" {
  make_legacy_profile "$MULTICLI_SCRATCH/local/codex"
  printf '{}\n' > "$MULTICLI_SCRATCH/local/codex/account-a/.credentials.json.before-migration"

  run multicli move codex/account-a ubuntu
  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [ ! -e "$MULTICLI_SCRATCH/local/codex/account-a" ]
  [ -f "$MULTICLI_SCRATCH/remote/codex/account-a/auth.json" ]
  [ -f "$MULTICLI_SCRATCH/remote/codex/account-a/.credentials.json.before-migration" ]
  [ "$(find "$MULTICLI_SCRATCH/local/codex/.inactive" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1 ]
  grep -q 'nini-agents' "$MULTICLI_SCRATCH/remote/bin/codex-account-a"
  ! grep -q 'multi-cli' "$MULTICLI_SCRATCH/remote/bin/codex-account-a"

  run multicli move codex/account-a mint
  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [ -f "$MULTICLI_SCRATCH/local/codex/account-a/auth.json" ]
  [ ! -e "$MULTICLI_SCRATCH/remote/codex/account-a" ]
  [ "$(find "$MULTICLI_SCRATCH/local/codex/.inactive" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(find "$MULTICLI_SCRATCH/remote/codex/.inactive" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1 ]
  cmp -s "$MULTICLI_SCRATCH/local/codex/account-a/auth.json" "$MULTICLI_SCRATCH/remote/codex/.inactive"/*/auth.json
}

@test "public move can discard only its verified source backup" {
  make_legacy_profile "$MULTICLI_SCRATCH/local/codex"
  mkdir -p "$MULTICLI_SCRATCH/local/codex/.inactive/prior.keep"
  printf 'keep\n' > "$MULTICLI_SCRATCH/local/codex/.inactive/prior.keep/sentinel"

  run multicli move codex/account-a ubuntu --discard-source-backup

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [[ "$output" == *"source backup was discarded"* ]]
  [ ! -e "$MULTICLI_SCRATCH/local/codex/account-a" ]
  [ -f "$MULTICLI_SCRATCH/remote/codex/account-a/auth.json" ]
  [ ! -e "$MULTICLI_SCRATCH/remote/codex/.staging" ]
  [ -f "$MULTICLI_SCRATCH/local/codex/.inactive/prior.keep/sentinel" ]
  [ -z "$(find "$MULTICLI_SCRATCH/local/codex/.inactive" -mindepth 1 -maxdepth 1 -type d -name 'account-a.*' -print -quit)" ]

  mkdir -p "$MULTICLI_SCRATCH/remote/codex/.inactive/prior.keep"
  printf 'keep remote\n' > "$MULTICLI_SCRATCH/remote/codex/.inactive/prior.keep/sentinel"
  run multicli move codex/account-a mint --discard-source-backup

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [[ "$output" == *"source backup was discarded"* ]]
  [ -f "$MULTICLI_SCRATCH/local/codex/account-a/auth.json" ]
  [ ! -e "$MULTICLI_SCRATCH/remote/codex/account-a" ]
  [ ! -e "$MULTICLI_SCRATCH/local/codex/.staging" ]
  [ -f "$MULTICLI_SCRATCH/remote/codex/.inactive/prior.keep/sentinel" ]
  [ -z "$(find "$MULTICLI_SCRATCH/remote/codex/.inactive" -mindepth 1 -maxdepth 1 -type d -name 'account-a.*' -print -quit)" ]
}

@test "backup discard failure reports an active destination and keeps recovery" {
  make_legacy_profile "$MULTICLI_SCRATCH/local/codex"
  export NINI_AGENTS_TEST_FAIL_BACKUP_DISCARD=1

  run multicli move codex/account-a ubuntu --discard-source-backup

  [ "$status" -ne 0 ]
  [[ "$output" == *"backup_cleanup_failed"* ]]
  [[ "$output" == *"destination_active"* ]]
  [ ! -e "$MULTICLI_SCRATCH/local/codex/account-a" ]
  [ -f "$MULTICLI_SCRATCH/remote/codex/account-a/auth.json" ]
  [ "$(find "$MULTICLI_SCRATCH/local/codex/.inactive" -mindepth 1 -maxdepth 1 -type d -name 'account-a.*' | wc -l | tr -d ' ')" -eq 1 ]
  [ ! -e "$MULTICLI_SCRATCH/local/codex/.move-lock.account-a" ]
  [ ! -e "$MULTICLI_SCRATCH/remote/codex/.move-lock.account-a" ]
}

@test "public move JSON returns only the stable non-secret result envelope" {
  make_legacy_profile "$MULTICLI_SCRATCH/local/codex"

  run multicli --json move codex/account-a ubuntu --dry-run

  [ "$status" -eq 0 ]
  run jq -e '
    .schemaVersion == 1 and .command == "move" and .ok == true and
    .data == {code:"dry_run",state:"validated",format:"legacy"} and .error == null
  ' <<< "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"account-a"* ]]
  [[ "$output" != *"auth.json"* ]]
  [[ "$output" != *"fixture-secret"* ]]
  [[ "$output" != *"$MULTICLI_SCRATCH"* ]]
}

@test "integrity mismatch preserves the active source and rejected staging" {
  make_legacy_profile "$MULTICLI_SCRATCH/local/codex"
  export NINI_AGENTS_TEST_TAMPER_COPY=1

  run multicli move codex/account-a ubuntu

  [ "$status" -ne 0 ]
  [[ "$output" == *"integrity_mismatch"* ]]
  [ -d "$MULTICLI_SCRATCH/local/codex/account-a" ]
  [ ! -e "$MULTICLI_SCRATCH/remote/codex/account-a" ]
  [ "$(find "$MULTICLI_SCRATCH/remote/codex/.staging" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a live Codex profile process blocks movement before staging" {
  make_legacy_profile "$MULTICLI_SCRATCH/local/codex"
  env CODEX_HOME="$MULTICLI_SCRATCH/local/codex/account-a" sleep 30 &
  local busy_pid=$!

  run multicli move codex/account-a ubuntu --dry-run

  kill "$busy_pid" 2>/dev/null || true
  wait "$busy_pid" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"process_active"* ]]
  [ ! -e "$MULTICLI_SCRATCH/remote/codex/.staging" ]
}

@test "schema-v2 movement excludes and rebuilds runtime on the destination" {
  run env MULTICLI_HOME="$MULTICLI_SCRATCH/local" "$MULTICLI_BIN" new codex/account-v2 --no-seed
  [ "$status" -eq 0 ]
  printf '{"tokens":{"access_token":"fixture-v2"}}\n' > "$MULTICLI_SCRATCH/local/codex/account-v2/auth/auth.json"
  run env MULTICLI_HOME="$MULTICLI_SCRATCH/local" MULTICLI_OVERRIDE_BINARY=/usr/bin/true "$MULTICLI_BIN" launch codex/account-v2
  [ "$status" -eq 0 ]
  [ -d "$MULTICLI_SCRATCH/local/codex/account-v2/.runtime" ]

  run multicli move codex/account-v2 ubuntu

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [ -f "$MULTICLI_SCRATCH/remote/codex/account-v2/.profile.json" ]
  [ -d "$MULTICLI_SCRATCH/remote/codex/account-v2/.runtime" ]
  [ -f "$MULTICLI_SCRATCH/remote/codex/account-v2/.runtime/.runtime-manifest" ]
  cmp -s "$MULTICLI_SCRATCH/local/codex/.inactive"/*/auth/auth.json "$MULTICLI_SCRATCH/remote/codex/account-v2/auth/auth.json"
}

@test "migrated account-overlay state and expected shared links move safely" {
  local profile="$MULTICLI_SCRATCH/local/codex/account-v2"
  local shared_root="$HOME/.codex"
  run env MULTICLI_HOME="$MULTICLI_SCRATCH/local" "$MULTICLI_BIN" new codex/account-v2 --no-seed
  [ "$status" -eq 0 ]
  printf '{"tokens":{"access_token":"fixture-v2"}}\n' > "$profile/auth/auth.json"
  mkdir -p "$profile/sessions" "$shared_root"
  printf 'session\n' > "$profile/sessions/session.jsonl"
  printf 'shared config\n' > "$shared_root/config.toml"
  ln -s "$shared_root/config.toml" "$profile/config.toml"
  : > "$profile/.shared"
  printf '{"status":"completed","operations":[]}\n' > "$profile/.migration-journal.json"

  run multicli move codex/account-v2 ubuntu

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [ -f "$MULTICLI_SCRATCH/remote/codex/account-v2/.migration-journal.json" ]
  [ -f "$MULTICLI_SCRATCH/remote/codex/account-v2/.shared" ]
  [ -f "$MULTICLI_SCRATCH/remote/codex/account-v2/sessions/session.jsonl" ]
  [ ! -e "$MULTICLI_SCRATCH/remote/codex/account-v2/config.toml" ]
  local backup
  for backup in "$MULTICLI_SCRATCH/local/codex/.inactive"/*; do break; done
  [ -L "$backup/config.toml" ]
  [ "$(readlink "$backup/config.toml")" = "$shared_root/config.toml" ]
  [ "$(cat "$shared_root/config.toml" | tr -d '\r')" = "shared config" ]
}

@test "migrated account-overlay state still rejects an external link" {
  local profile="$MULTICLI_SCRATCH/local/codex/account-v2"
  run env MULTICLI_HOME="$MULTICLI_SCRATCH/local" "$MULTICLI_BIN" new codex/account-v2 --no-seed
  [ "$status" -eq 0 ]
  printf '{"tokens":{"access_token":"fixture-v2"}}\n' > "$profile/auth/auth.json"
  mkdir -p "$MULTICLI_SCRATCH/outside"
  ln -s "$MULTICLI_SCRATCH/outside" "$profile/skills"
  printf '{"status":"completed","operations":[]}\n' > "$profile/.migration-journal.json"

  run multicli move codex/account-v2 ubuntu --dry-run

  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe_link"* ]]
  [ -d "$profile" ]
  [ ! -e "$MULTICLI_SCRATCH/remote/codex/.staging" ]
}

@test "completed migration journal permits pruning its exact nested external link" {
  local profile="$MULTICLI_SCRATCH/local/codex/account-v2"
  local outside="$MULTICLI_SCRATCH/outside-skill"
  run env MULTICLI_HOME="$MULTICLI_SCRATCH/local" "$MULTICLI_BIN" new codex/account-v2 --no-seed
  [ "$status" -eq 0 ]
  printf '{"tokens":{"access_token":"fixture-v2"}}\n' > "$profile/auth/auth.json"
  mkdir -p "$profile/skills" "$outside"
  printf 'external sentinel\n' > "$outside/SKILL.md"
  ln -s "$outside" "$profile/skills/custom"
  printf '%s\n' '{"status":"completed","operations":[{"op":"skip-link","rel":"skills/custom","status":"skipped"}]}' > "$profile/.migration-journal.json"

  run multicli move codex/account-v2 ubuntu

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [ ! -e "$MULTICLI_SCRATCH/remote/codex/account-v2/skills/custom" ]
  [ "$(cat "$outside/SKILL.md" | tr -d '\r')" = "external sentinel" ]
  local backup
  for backup in "$MULTICLI_SCRATCH/local/codex/.inactive"/*; do break; done
  [ -L "$backup/skills/custom" ]
  [ "$(readlink "$backup/skills/custom")" = "$outside" ]
}

@test "duplicate active owners fail closed before staging" {
  make_legacy_profile "$MULTICLI_SCRATCH/local/codex"
  make_legacy_profile "$MULTICLI_SCRATCH/remote/codex"

  run multicli --json move codex/account-a ubuntu

  [ "$status" -eq 1 ]
  run jq -e '.ok == false and .error.code == "ownership_unproven" and .error.details.state == "preflight_rejected"' <<< "$output"
  [ "$status" -eq 0 ]
  [ ! -e "$MULTICLI_SCRATCH/remote/codex/.staging" ]
}
