#!/usr/bin/env bats
# Real-execution tests for the legacy -> schema-v2 migration engine in
# lib/migration.sh. No mocks: every test builds a real legacy profile tree and
# a real schema-v2 fixture adapter under a scratch HOME, then invokes the
# engine functions directly (the `nini-agents migrate` dispatch is wired into the
# launcher separately).

load helpers/common

setup() {
  setup_scratch
  TOOLS_ROOT="$MULTICLI_SCRATCH/tools"
  mkdir -p "$TOOLS_ROOT/fixture"
  export USERPROFILE="$HOME"
  export APPDATA="$HOME/AppData/Roaming"
  export LOCALAPPDATA="$HOME/AppData/Local"
  SHARED_ROOT="$HOME/.fixture"
  write_fixture_adapter
  source_engine
}

# Load the engine with the REAL launcher context. The launcher resolves its
# imports through BASH_SOURCE, so sourcing works independently of Bats' $0.
# This yields the genuine launcher helpers instead of test reimplementations.
source_engine() {
  set -- help
  # shellcheck disable=SC1090
  source "$MULTICLI_BIN" >/dev/null 2>&1
  TOOLS_DIR="$MULTICLI_TOOLS_DIR"
  BASE="$MULTICLI_HOME"
}

teardown() {
  teardown_scratch
}

write_fixture_adapter() {
  cat > "$TOOLS_ROOT/fixture/adapter.json" <<'JSON'
{
  "schemaVersion": 2,
  "id": "fixture",
  "displayName": "Fixture CLI",
  "kind": "cli",
  "binary": {
    "windows": ["fixture.exe"],
    "macos": ["fixture"],
    "linux": ["fixture"]
  },
  "isolation": {
    "strategy": "accountOverlay",
    "mode": "foreground",
    "env": { "FIXTURE_HOME": "{runtimeRoot}" },
    "clearEnv": []
  },
  "account": {
    "mechanism": "fileOverlay",
    "credentialFiles": ["auth.json", "keys/token.json"],
    "credentialPrecedence": ["auth.json"],
    "logoutScope": "profile"
  },
  "normalState": {
    "root": {
      "windows": "%USERPROFILE%\\.fixture",
      "macos": "$HOME/.fixture",
      "linux": "$HOME/.fixture"
    },
    "sharedPaths": ["config.toml", "agents", "plugins"],
    "sessionPaths": ["sessions", "history.jsonl"],
    "filePaths": ["config.toml", "history.jsonl"],
    "unsafePaths": []
  },
  "concurrency": {
    "level": "multiWriter",
    "singletonScope": "none"
  },
  "support": {
    "windows": { "level": "supported", "reason": "Fixture only." },
    "macos": { "level": "supported", "reason": "Fixture only." },
    "linux": { "level": "supported", "reason": "Fixture only." }
  },
  "install": "https://example.test/install",
  "versionCommand": ["--version"]
}
JSON
}

mutate_adapter() {
  jq "$1" "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/adapter.json.tmp"
  mv "$TOOLS_ROOT/fixture/adapter.json.tmp" "$TOOLS_ROOT/fixture/adapter.json"
}

# A realistic legacy profile: credentials (one nested), shared/session state,
# and a .cli launcher marker.
make_legacy_profile() {
  local pdir="$MULTICLI_HOME/fixture/$1"
  mkdir -p "$pdir/keys" "$pdir/agents/reviewer" "$pdir/sessions/2026/06"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'nested-token\n' > "$pdir/keys/token.json"
  printf 'profile-config\n' > "$pdir/config.toml"
  printf 'agent\n' > "$pdir/agents/reviewer/agent.md"
  printf 'rollout\n' > "$pdir/sessions/2026/06/rollout.jsonl"
  printf 'shared-history\n' > "$pdir/history.jsonl"
  : > "$pdir/.cli"
}

seed_shared_root() {
  mkdir -p "$SHARED_ROOT"
  printf 'shared-config\n' > "$SHARED_ROOT/config.toml"
  printf 'shared-history\n' > "$SHARED_ROOT/history.jsonl"
}

# Newline-separated, sorted relative path set of a tree (dirs included).
list_tree() {
  (cd "$1" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort)
}

# Stable filesystem identity without reading file content. Credential moves
# must preserve this value and keep a single hardlink.
file_identity() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"
}

# Directory link that works without admin privileges: POSIX symlink, Windows
# directory junction via PowerShell (same mechanism the runtime uses).
make_dir_link() {
  local target="$1" link="$2"
  if ! _multicli_is_windows; then
    ln -s "$target" "$link" 2>/dev/null && [ -L "$link" ]
    return
  fi
  powershell.exe -NoProfile -Command \
    "New-Item -ItemType Junction -Path '$(cygpath -w "$link")' -Target '$(cygpath -w "$target")' | Out-Null" \
    >/dev/null 2>&1
  [ -L "$link" ]
}

make_dir_readonly() {
  local dir="$1"
  if _multicli_is_windows; then
    MSYS_NO_PATHCONV=1 icacls "$(cygpath -w "$dir")" /deny "$USERNAME:(OI)(CI)(W)" >/dev/null
  else
    chmod a-w "$dir"
  fi
}

make_dir_writable() {
  local dir="$1"
  if _multicli_is_windows; then
    MSYS_NO_PATHCONV=1 icacls "$(cygpath -w "$dir")" /remove:d "$USERNAME" >/dev/null
  else
    chmod u+w "$dir"
  fi
}

# 1. Dry run prints the exact plan (moves, merges, conflicts) and writes
#    nothing: no metadata, no journal, no auth dir, shared root untouched.
@test "dry run reports the exact plan and writes nothing" {
  make_legacy_profile work
  seed_shared_root

  run cmd_migrate fixture/work --dry-run

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [ "$status" -eq 0 ]
  [[ "$output" == *"Migration plan for fixture/work (legacy-isolated -> accountOverlay):"* ]]
  [[ "$output" == *"  move credential auth.json -> auth/auth.json"* ]]
  [[ "$output" == *"  move credential keys/token.json -> auth/keys/token.json"* ]]
  [[ "$output" == *"  merge shared agents -> $SHARED_ROOT/agents"* ]]
  [[ "$output" == *"  merge session sessions -> $SHARED_ROOT/sessions"* ]]
  [[ "$output" == *"  skip config.toml (conflict: content differs; use --prefer-profile to override)"* ]]
  [[ "$output" == *"  remove duplicate history.jsonl (shared root already has identical content)"* ]]
  [[ "$output" == *"  keep launcher metadata .cli"* ]]
  [[ "$output" == *"  write .profile.json (schemaVersion 2, mode accountOverlay)"* ]]
  [[ "$output" == *"Dry run -- no changes written."* ]]

  local pdir="$MULTICLI_HOME/fixture/work"
  [ ! -e "$pdir/.profile.json" ]
  [ ! -e "$pdir/.migration-journal.json" ]
  [ ! -e "$pdir/auth" ]
  [ -f "$pdir/auth.json" ]
  [ -f "$pdir/config.toml" ]
  [ "$(cat "$SHARED_ROOT/config.toml" | tr -d '\r')" = "shared-config" ]
}

# 2. A dry run against a profile whose shared root does not exist yet must not
#    create it.
@test "dry run does not create the shared state root" {
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir/agents"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'agent\n' > "$pdir/agents/agent.md"
  [ ! -e "$SHARED_ROOT" ]

  run cmd_migrate fixture/work --dry-run

  [ "$status" -eq 0 ]
  [ ! -e "$SHARED_ROOT" ]
}

# 3. Unknown entries -- top-level or nested inside a declaration-ancestor
#    directory -- abort the migration listing every offender. Nothing moves.
@test "unknown top-level and nested entries refuse the migration, listing them" {
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir/keys"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'nested-token\n' > "$pdir/keys/token.json"
  printf 'rogue\n' > "$pdir/keys/rogue.txt"
  printf 'mystery\n' > "$pdir/mystery.txt"

  run cmd_migrate fixture/work --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot migrate fixture/work: legacy profile contains entries the adapter does not declare:"* ]]
  [[ "$output" == *"  unknown: keys/rogue.txt"* ]]
  [[ "$output" == *"  unknown: mystery.txt"* ]]
  [[ "$output" == *"No changes were made."* ]]
  [ -f "$pdir/mystery.txt" ]
  [ -f "$pdir/keys/rogue.txt" ]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/.profile.json" ]
  [ ! -e "$pdir/.migration-journal.json" ]
  [ ! -e "$SHARED_ROOT" ]
}

@test "preserve-unknown dry run plans inactive recovery and writes nothing" {
  local pdir="$MULTICLI_HOME/fixture/work" auth_before unknown_before
  mkdir -p "$pdir/keys" "$pdir/tmp"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'nested-token\n' > "$pdir/keys/token.json"
  printf 'rogue\n' > "$pdir/keys/rogue.txt"
  printf 'temporary\n' > "$pdir/tmp/item"
  auth_before="$(file_identity "$pdir/auth.json")"
  unknown_before="$(file_identity "$pdir/keys/rogue.txt")"

  run cmd_migrate fixture/work --dry-run --preserve-unknown

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [[ "$output" == *"  preserve unknown state keys/rogue.txt in inactive recovery (--preserve-unknown)"* ]]
  [[ "$output" == *"  preserve unknown state tmp in inactive recovery (--preserve-unknown)"* ]]
  [[ "$output" == *"Dry run -- no changes written."* ]]
  [ "$(file_identity "$pdir/auth.json")" = "$auth_before" ]
  [ "$(file_identity "$pdir/keys/rogue.txt")" = "$unknown_before" ]
  [ ! -e "$pdir/auth/auth.json" ]
  [ ! -e "$MULTICLI_HOME/.inactive" ]
  [ ! -e "$pdir/.migration-journal.json" ]
}

@test "preserve-unknown apply renames objects inactive and keeps credential identity" {
  local pdir="$MULTICLI_HOME/fixture/work"
  local inactive="$MULTICLI_HOME/.inactive/migrations/fixture/work/unknown-state"
  local auth_before unknown_before
  mkdir -p "$pdir/tmp"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'artifact\n' > "$pdir/custom.txt"
  printf 'temporary\n' > "$pdir/tmp/item"
  auth_before="$(file_identity "$pdir/auth.json")"
  unknown_before="$(file_identity "$pdir/custom.txt")"

  run cmd_migrate fixture/work --preserve-unknown

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [ ! -e "$pdir/auth.json" ]
  [ "$(file_identity "$pdir/auth/auth.json")" = "$auth_before" ]
  [ ! -e "$pdir/custom.txt" ]
  [ "$(file_identity "$inactive/custom.txt")" = "$unknown_before" ]
  [ -f "$inactive/tmp/item" ]
  run jq -e '(.status == "completed") and .preserveUnknown == true and (.action | contains("--preserve-unknown")) and ([.operations[] | select(.op == "preserve-unknown" and .status == "done")] | length) == 2' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
}

@test "preserve-unknown participates in automatic rollback" {
  local pdir="$MULTICLI_HOME/fixture/work" auth_before unknown_before
  mkdir -p "$pdir/tmp"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'temporary\n' > "$pdir/tmp/item"
  auth_before="$(file_identity "$pdir/auth.json")"
  unknown_before="$(file_identity "$pdir/tmp/item")"
  runtime_write_profile_metadata() { return 9; }

  run cmd_migrate fixture/work --preserve-unknown

  [ "$status" -eq 1 ]
  [[ "$output" == *"Automatic rollback restored the legacy layout"* ]]
  [ "$(file_identity "$pdir/auth.json")" = "$auth_before" ]
  [ "$(file_identity "$pdir/tmp/item")" = "$unknown_before" ]
  [ ! -e "$pdir/auth/auth.json" ]
  [ ! -e "$MULTICLI_HOME/.inactive" ]
  run jq -e '.status == "rolled_back" and .preserveUnknown == true and (.action | contains("--preserve-unknown")) and ([.operations[] | select(.op == "preserve-unknown" and .status == "rolled-back")] | length) == 1' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
}

@test "preserve-unknown never overrides unsafe declarations" {
  mutate_adapter '.normalState.unsafePaths = ["forbidden"]'
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'unsafe\n' > "$pdir/forbidden"
  printf 'unknown\n' > "$pdir/mystery.txt"

  run cmd_migrate fixture/work --dry-run --preserve-unknown

  [ "$status" -eq 1 ]
  [[ "$output" == *"  unsafe: forbidden"* ]]
  [[ "$output" != *"Migration plan for"* ]]
  [ -f "$pdir/auth.json" ]
  [ -f "$pdir/forbidden" ]
  [ -f "$pdir/mystery.txt" ]
  [ ! -e "$MULTICLI_HOME/.inactive" ]
}

# Current Codex SQLite databases remain declared direct session state for the
# runtime, while migration preserves each legacy family member inactive.
@test "modern Codex SQLite family is preserved inactive in a dry-run" {
  local pdir="$MULTICLI_HOME/codex/modern"
  mkdir -p "$TOOLS_ROOT/codex" "$pdir" "$HOME/.codex"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$TOOLS_ROOT/codex/adapter.json"
  printf 'synthetic-token\n' > "$pdir/auth.json"
  printf 'synthetic-state\n' > "$pdir/state_5.sqlite"
  printf 'synthetic-shm\n' > "$pdir/state_5.sqlite-shm"
  printf 'synthetic-wal\n' > "$pdir/state_5.sqlite-wal"
  printf 'default-state\n' > "$HOME/.codex/state_5.sqlite"

  run cmd_migrate codex/modern --dry-run

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [[ "$output" == *"preserve profile state state_5.sqlite in inactive recovery"* ]]
  [[ "$output" == *"preserve profile state state_5.sqlite-shm in inactive recovery"* ]]
  [[ "$output" == *"preserve profile state state_5.sqlite-wal in inactive recovery"* ]]
  [[ "$output" != *"merge session state_5.sqlite"* ]]
  [ "$(cat "$HOME/.codex/state_5.sqlite" | tr -d '\r')" = default-state ]
  [ -f "$pdir/auth.json" ]
  [ -f "$pdir/state_5.sqlite-wal" ]
  [ ! -e "$pdir/auth/auth.json" ]
  [ ! -e "$MULTICLI_HOME/.inactive" ]
  [ ! -e "$pdir/.profile.json" ]
  [ ! -e "$pdir/.migration-journal.json" ]
}

# MCP OAuth is shared across schema-v2 profiles. Legacy entries are never
# imported into the active shared store: dry-run plans same-volume preservation
# under inactive recovery without following or printing link targets.
@test "modern Codex MCP OAuth state plans inactive preservation without writes" {
  local pdir="$MULTICLI_HOME/codex/modern"
  local outside="$MULTICLI_SCRATCH/synthetic-mcp" auth_before
  mkdir -p "$TOOLS_ROOT/codex" "$pdir" "$outside/locks"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$TOOLS_ROOT/codex/adapter.json"
  printf 'synthetic-token\n' > "$pdir/auth.json"
  printf '{"synthetic":"legacy"}\n' > "$outside/credentials.json"
  ln -s "$outside/credentials.json" "$pdir/.credentials.json"
  ln -s "$outside/locks" "$pdir/mcp-oauth-locks"
  auth_before="$(file_identity "$pdir/auth.json")"

  run cmd_migrate codex/modern --dry-run

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [[ "$output" == *"preserve shared credential .credentials.json in inactive recovery"* ]]
  [[ "$output" == *"preserve shared credential mcp-oauth-locks in inactive recovery"* ]]
  [[ "$output" != *"$outside"* ]]
  [[ "$output" == *"Dry run -- no changes written."* ]]
  [ "$(file_identity "$pdir/auth.json")" = "$auth_before" ]
  [ -L "$pdir/.credentials.json" ]
  [ -L "$pdir/mcp-oauth-locks" ]
  [ ! -e "$pdir/auth/auth.json" ]
  [ ! -e "$MULTICLI_HOME/.inactive" ]
  [ ! -e "$MULTICLI_HOME/.shared/codex/mcp" ]
  [ ! -e "$pdir/.profile.json" ]
  [ ! -e "$pdir/.migration-journal.json" ]
}

@test "modern Codex reconstructible runtime state and MCP backups are classified without writes" {
  local pdir="$MULTICLI_HOME/codex/modern"
  mkdir -p "$TOOLS_ROOT/codex" "$pdir/cache" "$pdir/shell_snapshots" "$pdir/thread-writer-locks"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$TOOLS_ROOT/codex/adapter.json"
  printf 'synthetic-token\n' > "$pdir/auth.json"
  printf 'runtime-cache\n' > "$pdir/cache/item"
  printf 'models\n' > "$pdir/models_cache.json"
  printf 'version\n' > "$pdir/version.json"
  : > "$pdir/.sandbox_migration"
  printf 'snapshot\n' > "$pdir/shell_snapshots/shell"
  printf 'lock\n' > "$pdir/thread-writer-locks/writer"
  printf 'backup\n' > "$pdir/.credentials.json.before-test"
  mkdir -p "$pdir/mcp-oauth-locks.before-test"

  run cmd_migrate codex/modern --dry-run

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [[ "$output" == *"preserve runtime state .sandbox_migration in inactive recovery"* ]]
  [[ "$output" == *"preserve runtime state cache in inactive recovery"* ]]
  [[ "$output" == *"preserve runtime state models_cache.json in inactive recovery"* ]]
  [[ "$output" == *"preserve runtime state version.json in inactive recovery"* ]]
  [[ "$output" == *"merge session shell_snapshots"* ]]
  [[ "$output" == *"preserve profile state thread-writer-locks in inactive recovery"* ]]
  [[ "$output" == *"preserve shared credential .credentials.json.before-test in inactive recovery"* ]]
  [[ "$output" == *"preserve shared credential mcp-oauth-locks.before-test in inactive recovery"* ]]
  [ -f "$pdir/.credentials.json.before-test" ]
  [ -d "$pdir/cache" ]
  [ ! -e "$MULTICLI_HOME/.inactive" ]
  [ ! -e "$pdir/.migration-journal.json" ]
}

@test "Codex residue classification keeps only the six unproven paths unknown" {
  local pdir="$MULTICLI_HOME/codex/modern"
  mkdir -p "$TOOLS_ROOT/codex" "$pdir/cache" "$pdir/shell_snapshots" "$pdir/thread-writer-locks" \
    "$pdir/mcp-oauth-locks.before-shared-supabase-20260721T202703Z" "$pdir/.tmp" "$pdir/tmp"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$TOOLS_ROOT/codex/adapter.json"
  printf 'synthetic-token\n' > "$pdir/auth.json"
  : > "$pdir/.sandbox_migration"
  : > "$pdir/models_cache.json"
  : > "$pdir/version.json"
  : > "$pdir/.credentials.json.before-shared-supabase-20260721T202703Z"
  : > "$pdir/.personality_migration"
  : > "$pdir/config.toml.bak-20260704"
  : > "$pdir/config.toml.bak-20260705-516-workaround"
  : > "$pdir/gpt-5.5-no-intermediary-updates.md"

  run cmd_migrate codex/modern --dry-run

  [ "$status" -eq 1 ]
  for rel in .personality_migration .tmp tmp config.toml.bak-20260704 \
    config.toml.bak-20260705-516-workaround gpt-5.5-no-intermediary-updates.md; do
    [[ "$output" == *"  unknown: $rel"* ]]
  done
  [[ "$output" != *"unknown: .sandbox_migration"* ]]
  [[ "$output" != *"unknown: cache"* ]]
  [[ "$output" != *"unknown: models_cache.json"* ]]
  [[ "$output" != *"unknown: version.json"* ]]
  [[ "$output" != *"unknown: shell_snapshots"* ]]
  [[ "$output" != *"unknown: thread-writer-locks"* ]]
  [[ "$output" != *"unknown: .credentials.json.before-shared-supabase-20260721T202703Z"* ]]
  [[ "$output" != *"unknown: mcp-oauth-locks.before-shared-supabase-20260721T202703Z"* ]]
  [ ! -e "$pdir/.migration-journal.json" ]
  [ ! -e "$MULTICLI_HOME/.inactive" ]
}

@test "apply preserves legacy MCP OAuth link objects inactive and leaves targets untouched" {
  local pdir="$MULTICLI_HOME/codex/modern"
  local outside="$MULTICLI_SCRATCH/synthetic-mcp"
  local inactive="$MULTICLI_HOME/.inactive/migrations/codex/modern/shared-credentials"
  local runtime_inactive="$MULTICLI_HOME/.inactive/migrations/codex/modern/runtime-state"
  local profile_state_inactive="$MULTICLI_HOME/.inactive/migrations/codex/modern/profile-state"
  mkdir -p "$TOOLS_ROOT/codex" "$pdir" "$outside/locks" "$pdir/mcp-oauth-locks.before-test" "$pdir/cache" "$pdir/thread-writer-locks"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$TOOLS_ROOT/codex/adapter.json"
  printf 'synthetic-token\n' > "$pdir/auth.json"
  printf '{"synthetic":"legacy"}\n' > "$outside/credentials.json"
  printf 'lock-target\n' > "$outside/locks/owner"
  ln -s "$outside/credentials.json" "$pdir/.credentials.json"
  ln -s "$outside/locks" "$pdir/mcp-oauth-locks"
  printf 'backup\n' > "$pdir/.credentials.json.before-test"
  printf 'backup-lock\n' > "$pdir/mcp-oauth-locks.before-test/owner"
  printf 'generated\n' > "$pdir/cache/item"
  printf 'generated\n' > "$pdir/version.json"
  printf 'db\n' > "$pdir/state_5.sqlite"
  printf 'shm\n' > "$pdir/state_5.sqlite-shm"
  printf 'wal\n' > "$pdir/state_5.sqlite-wal"
  printf 'lock\n' > "$pdir/thread-writer-locks/writer"

  run cmd_migrate codex/modern

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [ -L "$inactive/.credentials.json" ]
  [ -L "$inactive/mcp-oauth-locks" ]
  [ -f "$inactive/.credentials.json.before-test" ]
  [ -d "$inactive/mcp-oauth-locks.before-test" ]
  [ -f "$runtime_inactive/cache/item" ]
  [ -f "$runtime_inactive/version.json" ]
  [ -f "$profile_state_inactive/state_5.sqlite" ]
  [ -f "$profile_state_inactive/state_5.sqlite-shm" ]
  [ -f "$profile_state_inactive/state_5.sqlite-wal" ]
  [ -f "$profile_state_inactive/thread-writer-locks/writer" ]
  [ ! -e "$pdir/.credentials.json" ]
  [ ! -e "$pdir/mcp-oauth-locks" ]
  run jq -er '.synthetic' "$outside/credentials.json"
  [ "$status" -eq 0 ]
  [ "$output" = legacy ]
  [ "$(cat "$outside/locks/owner" | tr -d '\r')" = lock-target ]
  [ -f "$pdir/auth/auth.json" ]
  [ ! -e "$pdir/auth.json" ]
  [ -f "$pdir/.profile.json" ]
  [ ! -e "$MULTICLI_HOME/.shared/codex/mcp" ]
  run jq -e '([.operations[] | select(.op == "preserve-shared-credential" and .status == "done")] | length) == 4 and ([.operations[] | select(.op == "preserve-runtime-state" and .status == "done")] | length) == 2 and ([.operations[] | select(.op == "preserve-profile-state" and .status == "done")] | length) == 4' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
}

@test "failed migration restores legacy MCP OAuth links from inactive recovery" {
  local pdir="$MULTICLI_HOME/codex/modern"
  local outside="$MULTICLI_SCRATCH/synthetic-mcp"
  mkdir -p "$TOOLS_ROOT/codex" "$pdir" "$outside/locks" "$pdir/cache" "$pdir/thread-writer-locks"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$TOOLS_ROOT/codex/adapter.json"
  printf 'synthetic-token\n' > "$pdir/auth.json"
  printf '{}\n' > "$outside/credentials.json"
  ln -s "$outside/credentials.json" "$pdir/.credentials.json"
  ln -s "$outside/locks" "$pdir/mcp-oauth-locks"
  printf 'generated\n' > "$pdir/cache/item"
  printf 'backup\n' > "$pdir/.credentials.json.before-test"
  printf 'db\n' > "$pdir/state_5.sqlite"
  printf 'wal\n' > "$pdir/state_5.sqlite-wal"
  printf 'lock\n' > "$pdir/thread-writer-locks/writer"
  runtime_write_profile_metadata() { return 9; }

  run cmd_migrate codex/modern

  [ "$status" -eq 1 ] || printf 'unexpected status %s: %s\n' "$status" "$output" >&3
  [[ "$output" == *"Automatic rollback restored the legacy layout"* ]] || printf '%s\n' "$output" >&3
  [ "$status" -eq 1 ]
  [[ "$output" == *"Automatic rollback restored the legacy layout"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/auth/auth.json" ]
  [ -L "$pdir/.credentials.json" ]
  [ -L "$pdir/mcp-oauth-locks" ]
  [ -f "$pdir/cache/item" ]
  [ -f "$pdir/.credentials.json.before-test" ]
  [ -f "$pdir/state_5.sqlite" ]
  [ -f "$pdir/state_5.sqlite-wal" ]
  [ -f "$pdir/thread-writer-locks/writer" ]
  [ ! -e "$MULTICLI_HOME/.inactive" ]
  [ ! -e "$pdir/.profile.json" ]
  run jq -er '.status == "rolled_back"' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
}

@test "linked inactive recovery boundary refuses shared credential migration before writes" {
  mutate_adapter '.sharedCredentialState={
    root:".shared/fixture/oauth",
    entries:[{path:"oauth-cache",kind:"jsonObjectFile"}],
    legacyMigration:"preserveInactive"
  }'
  local pdir="$MULTICLI_HOME/fixture/work"
  local outside="$MULTICLI_SCRATCH/outside-inactive"
  mkdir -p "$pdir" "$outside"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf '{}\n' > "$pdir/oauth-cache"
  make_dir_link "$outside" "$MULTICLI_HOME/.inactive" || skip "directory links unavailable on this host"

  run cmd_migrate fixture/work --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"inactive shared-credential recovery root crosses a link"* ]]
  [ -f "$pdir/auth.json" ]
  [ -f "$pdir/oauth-cache" ]
  [ -z "$(find "$outside" -mindepth 1 -print -quit)" ]
  [ ! -e "$pdir/auth" ]
  [ ! -e "$pdir/.migration-journal.json" ]
}

# 4. An entry that matches both a credential and a shared-state declaration is
#    ambiguous and refuses the migration.
@test "entries overlapping credential and shared declarations refuse the migration" {
  mutate_adapter '.account.credentialFiles = ["auth.json", "vault/token.json"]
    | .normalState.sharedPaths += ["vault/settings.json"]
    | .normalState.filePaths += ["vault/settings.json"]'
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir/vault"
  printf 'token\n' > "$pdir/vault/token.json"
  printf 'settings\n' > "$pdir/vault/settings.json"

  run cmd_migrate fixture/work --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"  overlap: vault (matches both credential and shared-state declarations)"* ]]
  [[ "$output" == *"No changes were made."* ]]
  [ -f "$pdir/vault/token.json" ]
  [ ! -e "$pdir/.profile.json" ]
  [ ! -e "$SHARED_ROOT" ]
}

# 5. Apply: credentials move into auth/ preserving subpaths, shared/session
#    state merges into the native root, emptied directories are pruned, and
#    .profile.json plus a completed journal are written.
@test "apply moves credentials preserving subpaths, merges state, prunes emptied dirs, writes metadata and journal" {
  make_legacy_profile work
  seed_shared_root

  local pdir="$MULTICLI_HOME/fixture/work"
  local auth_identity
  auth_identity="$(file_identity "$pdir/auth.json")"

  run cmd_migrate fixture/work

  [ "$status" -eq 0 ]
  [[ "$output" == *"Migrated fixture/work to schema-v2 (accountOverlay)."* ]]

  [ "$(cat "$pdir/auth/auth.json" | tr -d '\r')" = "profile-token" ]
  [ "$(file_identity "$pdir/auth/auth.json")" = "$auth_identity" ]
  [ "$(file_nlink "$pdir/auth/auth.json")" -eq 1 ]
  [ ! -e "$pdir/auth.json" ]
  [ ! -e "$pdir/.migration.lock" ]
  [ ! -e "$pdir/.migration-rollback" ]
  [ "$(cat "$pdir/auth/keys/token.json" | tr -d '\r')" = "nested-token" ]
  run jq -er '.schemaVersion == 2 and .adapterId == "fixture" and .mode == "accountOverlay" and (.profileId | test("^[a-f0-9-]{36}$"))' "$pdir/.profile.json"
  [ "$status" -eq 0 ]
  run jq -er '.status == "completed"' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]

  # shared/session state landed in the native root; identical history was not
  # duplicated; the conflicting config stayed with the shared root.
  [ "$(cat "$SHARED_ROOT/agents/reviewer/agent.md" | tr -d '\r')" = "agent" ]
  [ "$(cat "$SHARED_ROOT/sessions/2026/06/rollout.jsonl" | tr -d '\r')" = "rollout" ]
  [ "$(cat "$SHARED_ROOT/history.jsonl" | tr -d '\r')" = "shared-history" ]
  [ "$(cat "$SHARED_ROOT/config.toml" | tr -d '\r')" = "shared-config" ]
  [ ! -e "$pdir/history.jsonl" ]
  [ -f "$pdir/config.toml" ]

  # emptied directories were removed
  [ ! -e "$pdir/agents" ]
  [ ! -e "$pdir/sessions" ]
  [ ! -e "$pdir/keys" ]

  # exact profile file set after migration
  [ "$(list_tree "$pdir")" = "$(printf '%s\n' \
    .cli .migration-journal.json .profile.json \
    auth auth/auth.json auth/keys auth/keys/token.json \
    config.toml)" ]
  # exact shared root file set after migration
  [ "$(list_tree "$SHARED_ROOT")" = "$(printf '%s\n' \
    agents agents/reviewer agents/reviewer/agent.md \
    config.toml history.jsonl \
    sessions sessions/2026 sessions/2026/06 sessions/2026/06/rollout.jsonl)" ]
}

# 6. Conflicting shared content is skipped and reported by default; an
#    explicit --prefer-profile makes the profile win.
@test "conflicts skip and report by default; --prefer-profile overrides the shared root" {
  local pdir_a="$MULTICLI_HOME/fixture/work"
  local pdir_b="$MULTICLI_HOME/fixture/work2"
  mkdir -p "$pdir_a" "$pdir_b"
  printf 'token-a\n' > "$pdir_a/auth.json"
  printf 'profile-config\n' > "$pdir_a/config.toml"
  printf 'token-b\n' > "$pdir_b/auth.json"
  printf 'profile-b-config\n' > "$pdir_b/config.toml"
  mkdir -p "$SHARED_ROOT"
  printf 'shared-config\n' > "$SHARED_ROOT/config.toml"

  run cmd_migrate fixture/work
  [ "$status" -eq 0 ]
  [[ "$output" == *"  skip config.toml (conflict: content differs; use --prefer-profile to override)"* ]]
  [ "$(cat "$SHARED_ROOT/config.toml" | tr -d '\r')" = "shared-config" ]
  [ "$(cat "$pdir_a/config.toml" | tr -d '\r')" = "profile-config" ]

  run cmd_migrate fixture/work2 --prefer-profile
  [ "$status" -eq 0 ]
  [[ "$output" == *"  replace config.toml -> $SHARED_ROOT/config.toml (--prefer-profile: content differs)"* ]]
  [ "$(cat "$SHARED_ROOT/config.toml" | tr -d '\r')" = "profile-b-config" ]
  [ ! -e "$pdir_b/config.toml" ]
}

# 7. A type mismatch (profile file vs shared directory and vice versa) is a
#    conflict too: skipped by default, replaced with --prefer-profile.
@test "type mismatches skip by default and are replaced with --prefer-profile" {
  local pdir_a="$MULTICLI_HOME/fixture/work"
  local pdir_b="$MULTICLI_HOME/fixture/work2"
  mkdir -p "$pdir_a" "$pdir_b" "$SHARED_ROOT/agents"
  printf 'token-a\n' > "$pdir_a/auth.json"
  printf 'just-a-file\n' > "$pdir_a/agents"
  printf 'token-b\n' > "$pdir_b/auth.json"
  printf 'just-a-file-b\n' > "$pdir_b/agents"
  printf 'existing\n' > "$SHARED_ROOT/agents/existing.md"

  run cmd_migrate fixture/work
  [ "$status" -eq 0 ]
  [[ "$output" == *"  skip agents (conflict: shared root has a directory where the profile has a file"* ]]
  [ -f "$pdir_a/agents" ]
  [ -f "$SHARED_ROOT/agents/existing.md" ]

  run cmd_migrate fixture/work2 --prefer-profile
  [ "$status" -eq 0 ]
  [ -f "$SHARED_ROOT/agents" ]
  [ "$(cat "$SHARED_ROOT/agents" | tr -d '\r')" = "just-a-file-b" ]
  [ ! -e "$pdir_b/agents" ]
}

# 8. Legacy --shared profiles: symlinked entries are recognized and left in
#    place as shared links; nested links inside merged directories are skipped,
#    never copied.
@test "legacy shared links stay in place; nested links inside merged dirs are skipped" {
  mkdir -p "$SHARED_ROOT/plugins" "$SHARED_ROOT/agents" "$SHARED_ROOT/outside-dir"
  printf 'plugin\n' > "$SHARED_ROOT/plugins/plugin.md"
  printf 'existing\n' > "$SHARED_ROOT/agents/existing.md"
  printf 'outside\n' > "$SHARED_ROOT/outside-dir/note.md"

  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir/agents"
  : > "$pdir/.shared"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'local\n' > "$pdir/agents/local.md"
  make_dir_link "$SHARED_ROOT/plugins" "$pdir/plugins" || skip "directory links unavailable on this host"
  make_dir_link "$SHARED_ROOT/outside-dir" "$pdir/agents/linkdir" || skip "directory links unavailable on this host"

  run cmd_migrate fixture/work

  [ "$status" -eq 0 ]
  [[ "$output" == *"  keep shared link plugins (existing link retained)"* ]]
  [[ "$output" != *"target:"* ]]
  [[ "$output" == *"  skip nested link agents/linkdir"* ]]
  [ -L "$pdir/plugins" ]
  [ -L "$pdir/agents/linkdir" ]
  # the link target was not copied or moved anywhere
  [ "$(list_tree "$SHARED_ROOT/plugins")" = "plugin.md" ]
  # the real file inside agents merged into the shared root
  [ "$(cat "$SHARED_ROOT/agents/local.md" | tr -d '\r')" = "local" ]
  [ "$(cat "$SHARED_ROOT/agents/existing.md" | tr -d '\r')" = "existing" ]
  [ ! -e "$SHARED_ROOT/agents/linkdir" ]
  [ "$(list_tree "$pdir")" = "$(printf '%s\n' \
    .migration-journal.json .profile.json .shared \
    agents agents/linkdir \
    auth auth/auth.json auth/keys auth/keys/token.json \
    plugins)" ]
}

# 9. A failure mid-apply restores every completed move before returning. The
#    journal remains as non-secret evidence and a clean re-run can start over.
@test "failure rolls back to the legacy layout and a re-run starts cleanly" {
  mkdir -p "$SHARED_ROOT"
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir/agents"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'agent\n' > "$pdir/agents/agent.md"
  make_dir_readonly "$SHARED_ROOT"

  run cmd_migrate fixture/work

  [ "$status" -eq 1 ]
  [[ "$output" == *"Migration failed"* ]]
  [[ "$output" == *".migration-journal.json"* ]]
  [ ! -e "$pdir/.profile.json" ]
  # the journal records the failed operation and the automatic rollback
  run jq -er '.status == "rolled_back"' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
  run jq -er '[.operations[] | select(.op == "move-credential") | .status] == ["rolled-back"]' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
  run jq -er '[.operations[] | select(.op == "merge-move") | .status] == ["failed"]' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
  run jq -er '[.operations[] | select(.status == "pending")] | length > 0' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
  # the credential is back at its original path; no duplicate or staging
  # credential remains after rollback.
  [ "$(cat "$pdir/auth.json" | tr -d '\r')" = "profile-token" ]
  [ ! -e "$pdir/auth/auth.json" ]
  [ -f "$pdir/agents/agent.md" ]
  [ ! -e "$SHARED_ROOT/agents" ]
  [ ! -e "$pdir/.migration.lock" ]
  [ ! -e "$pdir/.migration-rollback" ]

  make_dir_writable "$SHARED_ROOT"
  run cmd_migrate fixture/work

  [ "$status" -eq 0 ]
  [ "$(cat "$SHARED_ROOT/agents/agent.md" | tr -d '\r')" = "agent" ]
  run jq -er '.schemaVersion == 2 and .adapterId == "fixture" and .mode == "accountOverlay"' "$pdir/.profile.json"
  [ "$status" -eq 0 ]
  run jq -er '.status == "completed"' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
  [ "$(list_tree "$pdir")" = "$(printf '%s\n' \
    .migration-journal.json .profile.json \
    auth auth/auth.json auth/keys auth/keys/token.json)" ]
}

@test "active or indeterminate tool processes refuse apply before writing" {
  local pdir="$MULTICLI_HOME/fixture/work"
  make_legacy_profile work

  migration_process_probe() { return 0; }
  run cmd_migrate fixture/work

  [ "$status" -eq 1 ]
  [[ "$output" == *"active process"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/auth" ]
  [ ! -e "$pdir/.migration-journal.json" ]
  [ ! -e "$pdir/.migration.lock" ]

  migration_process_probe() { return 2; }
  run cmd_migrate fixture/work

  [ "$status" -eq 1 ]
  [[ "$output" == *"could not prove that tool processes are stopped"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/auth" ]
  [ ! -e "$pdir/.migration-journal.json" ]
  [ ! -e "$pdir/.migration.lock" ]
}

@test "exclusive migration lock and a process appearing after lock both refuse without moving credentials" {
  local pdir="$MULTICLI_HOME/fixture/work"
  make_legacy_profile work
  mkdir "$pdir/.migration.lock"

  run cmd_migrate fixture/work

  [ "$status" -eq 1 ]
  [[ "$output" == *"migration is already locked"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/auth" ]
  [ ! -e "$pdir/.migration-journal.json" ]

  rmdir "$pdir/.migration.lock"
  local probe_calls=0
  migration_process_probe() {
    probe_calls=$((probe_calls + 1))
    [ "$probe_calls" -eq 1 ] && return 1
    return 0
  }
  run cmd_migrate fixture/work

  [ "$status" -eq 1 ]
  [[ "$output" == *"process appeared while acquiring the migration lock"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/auth" ]
  [ ! -e "$pdir/.migration-journal.json" ]
  [ ! -e "$pdir/.migration.lock" ]
}

@test "production process probe detects a synthetic process using the profile environment" {
  local pdir="$MULTICLI_HOME/fixture/work"
  make_legacy_profile work
  env FIXTURE_HOME="$pdir" sleep 30 &
  local fixture_pid=$!

  run cmd_migrate fixture/work
  kill "$fixture_pid" 2>/dev/null || true
  wait "$fixture_pid" 2>/dev/null || true

  [ "$status" -eq 1 ]
  [[ "$output" == *"active process"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/auth" ]
  [ ! -e "$pdir/.migration-journal.json" ]
}

@test "failure after prefer-profile replacement restores credentials and shared state" {
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir" "$SHARED_ROOT"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'profile-config\n' > "$pdir/config.toml"
  printf 'shared-config\n' > "$SHARED_ROOT/config.toml"
  runtime_write_profile_metadata() { return 9; }

  run cmd_migrate fixture/work --prefer-profile

  [ "$status" -eq 1 ]
  [[ "$output" == *"Automatic rollback restored the legacy layout"* ]]
  [ "$(cat "$pdir/auth.json" | tr -d '\r')" = "profile-token" ]
  [ ! -e "$pdir/auth/auth.json" ]
  [ "$(cat "$pdir/config.toml" | tr -d '\r')" = "profile-config" ]
  [ "$(cat "$SHARED_ROOT/config.toml" | tr -d '\r')" = "shared-config" ]
  [ ! -e "$pdir/.profile.json" ]
  [ ! -e "$pdir/.migration.lock" ]
  [ ! -e "$pdir/.migration-rollback" ]
  run jq -er '.status == "rolled_back"' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
}

@test "hardlinked credentials refuse during planning before any write" {
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir"
  printf 'profile-token\n' > "$pdir/auth.json"
  make_hardlink "$pdir/auth.json" "$pdir/auth-alias.json" || skip "hardlinks unavailable on this host"
  mutate_adapter '.normalState.sharedPaths += ["auth-alias.json"] | .normalState.filePaths += ["auth-alias.json"]'

  run cmd_migrate fixture/work

  [ "$status" -eq 1 ]
  [[ "$output" == *"credential 'auth.json' is a hardlink"* ]]
  [ -f "$pdir/auth.json" ]
  [ -f "$pdir/auth-alias.json" ]
  [ ! -e "$pdir/auth" ]
  [ ! -e "$pdir/.migration-journal.json" ]
  [ ! -e "$pdir/.migration.lock" ]
}

@test "linked or cross-volume credential destinations refuse before any write" {
  local pdir="$MULTICLI_HOME/fixture/work"
  local outside="$MULTICLI_SCRATCH/outside-auth"
  mkdir -p "$pdir" "$outside"
  printf 'profile-token\n' > "$pdir/auth.json"
  make_dir_link "$outside" "$pdir/auth" || skip "directory links unavailable on this host"

  run cmd_migrate fixture/work --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"credential destination 'auth/auth.json' crosses a link"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$outside/auth.json" ]
  [ ! -e "$pdir/.migration-journal.json" ]

  rm "$pdir/auth"
  mkdir "$pdir/auth"
  migration_file_device() {
    case "$1" in
      "$pdir/auth") printf 'synthetic-other-volume\n' ;;
      *) printf 'synthetic-profile-volume\n' ;;
    esac
  }

  run cmd_migrate fixture/work --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"credential 'auth.json' and its destination are on different volumes"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/auth/auth.json" ]
  [ ! -e "$pdir/.migration-journal.json" ]
}

@test "linked shared destinations and stale control files refuse even dry-run" {
  local pdir="$MULTICLI_HOME/fixture/work"
  local outside="$MULTICLI_SCRATCH/outside-shared"
  mkdir -p "$pdir/agents" "$SHARED_ROOT" "$outside"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'agent\n' > "$pdir/agents/agent.md"
  make_dir_link "$outside" "$SHARED_ROOT/agents" || skip "directory links unavailable on this host"

  run cmd_migrate fixture/work --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"shared-state destination 'agents' crosses a link"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$outside/agent.md" ]
  [ ! -e "$pdir/.migration-journal.json" ]

  rm "$SHARED_ROOT/agents"
  : > "$pdir/.migration-journal.json.tmp"

  run cmd_migrate fixture/work --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"unfinished migration control artifact '.migration-journal.json.tmp'"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/auth" ]
}

@test "stale recovery artifacts block even dry-run until explicitly inspected" {
  local pdir="$MULTICLI_HOME/fixture/work"
  make_legacy_profile work
  mkdir "$pdir/.migration-rollback"

  run cmd_migrate fixture/work --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"recovery artifacts already exist"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/auth" ]
  [ ! -e "$pdir/.migration-journal.json" ]
  [ ! -e "$pdir/.migration.lock" ]
}

@test "handled failure removes a shared root created by the failed migration" {
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir"
  printf 'profile-token\n' > "$pdir/auth.json"
  [ ! -e "$SHARED_ROOT" ]
  runtime_write_profile_metadata() { return 9; }

  run cmd_migrate fixture/work

  [ "$status" -eq 1 ]
  [[ "$output" == *"Automatic rollback restored the legacy layout"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/auth" ]
  [ ! -e "$SHARED_ROOT" ]
  [ ! -e "$pdir/.migration-rollback" ]
  run jq -er '.status == "rolled_back"' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
}

@test "a cross-volume state move fails and rolls the credential back without copying" {
  local pdir="$MULTICLI_HOME/fixture/work"
  local real_device
  mkdir -p "$pdir" "$SHARED_ROOT"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'profile-config\n' > "$pdir/config.toml"
  real_device="$(stat -c %d "$pdir" 2>/dev/null || stat -f %d "$pdir")"
  migration_file_device() {
    case "$1" in
      "$pdir/config.toml") printf 'synthetic-state-volume\n' ;;
      *) printf '%s\n' "$real_device" ;;
    esac
  }

  run cmd_migrate fixture/work

  [ "$status" -eq 1 ]
  [[ "$output" == *"Automatic rollback restored the legacy layout"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/auth" ]
  [ -f "$pdir/config.toml" ]
  [ ! -e "$SHARED_ROOT/config.toml" ]
  [ ! -e "$pdir/.migration-rollback" ]
  run jq -er '.status == "rolled_back"' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
}

@test "an unprovable rollback preserves artifacts and marks rollback_failed" {
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir/agents" "$SHARED_ROOT"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'agent\n' > "$pdir/agents/agent.md"
  make_dir_readonly "$SHARED_ROOT"
  migration_rollback_ops() { return 1; }

  run cmd_migrate fixture/work
  make_dir_writable "$SHARED_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Automatic rollback could not prove"* ]]
  [[ "$output" == *"Do not launch this profile"* ]]
  [ ! -e "$pdir/auth.json" ]
  [ -f "$pdir/auth/auth.json" ]
  [ ! -e "$pdir/.migration.lock" ]
  run jq -er '.status == "rollback_failed"' "$pdir/.migration-journal.json"
  [ "$status" -eq 0 ]
}

# 10. Applying an already-migrated profile is a no-op success and changes
#     nothing.
@test "second apply is an idempotent no-op success" {
  make_legacy_profile work
  seed_shared_root
  run cmd_migrate fixture/work
  [ "$status" -eq 0 ]
  local pdir="$MULTICLI_HOME/fixture/work"
  local before_profile before_shared
  before_profile="$(list_tree "$pdir")"
  before_shared="$(list_tree "$SHARED_ROOT")"

  run cmd_migrate fixture/work

  [ "$status" -eq 0 ]
  [[ "$output" == *"Profile 'fixture/work' is already schema-v2 (accountOverlay); nothing to do."* ]]
  [ "$(list_tree "$pdir")" = "$before_profile" ]
  [ "$(list_tree "$SHARED_ROOT")" = "$before_shared" ]
}

# 11. Adapters whose account boundary is an OS credential store cannot be
#     migrated file-based; the refusal says to keep the legacy profile.
@test "osUserCredentialStore adapters are refused with a clear error" {
  mutate_adapter '.account.mechanism = "osUserCredentialStore"'
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir"
  printf 'profile-token\n' > "$pdir/auth.json"

  run cmd_migrate fixture/work

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot migrate fixture/work: adapter 'fixture' uses 'osUserCredentialStore' credentials."* ]]
  [[ "$output" == *"keep the legacy profile."* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/.profile.json" ]
}

# 12. Inseparable adapters keep their truthful limitation and are refused.
@test "inseparable adapters are refused with the adapter reason" {
  mutate_adapter '.account.mechanism = "inseparable" | .account.reason = "Auth and chats share one database."'
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir"
  printf 'profile-token\n' > "$pdir/auth.json"

  run cmd_migrate fixture/work

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot migrate fixture/work: adapter 'fixture' is marked inseparable (Auth and chats share one database.)"* ]]
  [ -f "$pdir/auth.json" ]
  [ ! -e "$pdir/.profile.json" ]
}

# 13. processSecret adapters migrate the filesystem parts and must demand
#     `nini-agents auth set` afterwards.
@test "processSecret adapters migrate filesystem state and demand auth set afterwards" {
  mutate_adapter '.account.mechanism = "processSecret"
    | .account.credentialFiles = []
    | .account.secret = { "environmentVariable": "FIXTURE_TOKEN" }'
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir/sessions"
  printf 'profile-config\n' > "$pdir/config.toml"
  printf 'session\n' > "$pdir/sessions/s.jsonl"
  printf 'history\n' > "$pdir/history.jsonl"

  run cmd_migrate fixture/work

  [ "$status" -eq 0 ]
  [[ "$output" == *"Migrated fixture/work to schema-v2 (accountOverlay)."* ]]
  [[ "$output" == *"Run: nini-agents auth set fixture/work before launching."* ]]
  [ "$(cat "$SHARED_ROOT/config.toml" | tr -d '\r')" = "profile-config" ]
  [ "$(cat "$SHARED_ROOT/sessions/s.jsonl" | tr -d '\r')" = "session" ]
  [ "$(cat "$SHARED_ROOT/history.jsonl" | tr -d '\r')" = "history" ]
  run jq -er '.schemaVersion == 2 and .mode == "accountOverlay"' "$pdir/.profile.json"
  [ "$status" -eq 0 ]
  [ "$(list_tree "$pdir")" = "$(printf '%s\n' .migration-journal.json .profile.json)" ]
}

# 14. A credential target that already exists with different content is never
#     overwritten -- the migration refuses even with --prefer-profile.
@test "credential target conflicts are never overwritten" {
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir/auth"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'different-token\n' > "$pdir/auth/auth.json"

  run cmd_migrate fixture/work --prefer-profile

  [ "$status" -eq 1 ]
  [[ "$output" == *"credential target 'auth/auth.json' already exists with different content; refusing to overwrite credentials."* ]]
  [ "$(cat "$pdir/auth.json" | tr -d '\r')" = "profile-token" ]
  [ "$(cat "$pdir/auth/auth.json" | tr -d '\r')" = "different-token" ]
  [ ! -e "$pdir/.profile.json" ]
  [ ! -e "$pdir/.migration-journal.json" ]
}

# 15. A profile directory whose shared-root counterpart is a FILE is a type
#     conflict too: skipped by default, replaced with --prefer-profile.
@test "profile directory conflicting with a shared-root file skips by default and replaces with --prefer-profile" {
  local pdir_a="$MULTICLI_HOME/fixture/work"
  local pdir_b="$MULTICLI_HOME/fixture/work2"
  mkdir -p "$pdir_a/agents" "$pdir_b/agents" "$SHARED_ROOT"
  printf 'token-a\n' > "$pdir_a/auth.json"
  printf 'agent-a\n' > "$pdir_a/agents/a.md"
  printf 'token-b\n' > "$pdir_b/auth.json"
  printf 'agent-b\n' > "$pdir_b/agents/b.md"
  printf 'root-file\n' > "$SHARED_ROOT/agents"

  run cmd_migrate fixture/work
  [ "$status" -eq 0 ]
  [[ "$output" == *"  skip agents (conflict: shared root has a file where the profile has a directory; use --prefer-profile to override)"* ]]
  [ -f "$pdir_a/agents/a.md" ]
  [ "$(cat "$SHARED_ROOT/agents" | tr -d '\r')" = "root-file" ]

  run cmd_migrate fixture/work2 --prefer-profile
  [ "$status" -eq 0 ]
  [ -d "$SHARED_ROOT/agents" ]
  [ "$(cat "$SHARED_ROOT/agents/b.md" | tr -d '\r')" = "agent-b" ]
  [ ! -e "$pdir_b/agents" ]
}

# 16. Credential lookalikes hiding inside shared directories are never merged
#     into the shared root -- neither when the merge runs per-file (existing
#     target) nor when the fresh target would otherwise move the directory whole.
@test "credential lookalikes inside shared dirs are skipped in per-file and whole-dir merges" {
  mkdir -p "$SHARED_ROOT/agents"
  printf 'existing\n' > "$SHARED_ROOT/agents/existing.md"
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir/agents" "$pdir/sessions"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'local\n' > "$pdir/agents/local.md"
  printf 'decoy\n' > "$pdir/agents/token.json"
  printf 'session\n' > "$pdir/sessions/real.jsonl"
  printf 'decoy\n' > "$pdir/sessions/auth.json"

  run cmd_migrate fixture/work

  [ "$status" -eq 0 ]
  [[ "$output" == *"  skip agents/token.json (name matches a declared credential; left in profile)"* ]]
  [[ "$output" == *"  skip sessions/auth.json (name matches a declared credential; left in profile)"* ]]
  [ "$(cat "$SHARED_ROOT/agents/local.md" | tr -d '\r')" = "local" ]
  [ "$(cat "$SHARED_ROOT/agents/existing.md" | tr -d '\r')" = "existing" ]
  [ "$(cat "$SHARED_ROOT/sessions/real.jsonl" | tr -d '\r')" = "session" ]
  [ ! -e "$SHARED_ROOT/agents/token.json" ]
  [ ! -e "$SHARED_ROOT/sessions/auth.json" ]
  [ -f "$pdir/agents/token.json" ]
  [ -f "$pdir/sessions/auth.json" ]
}

# 17. A credential that is already migrated with identical content is
#     deduplicated, never treated as a conflict.
@test "identical already-migrated credential is deduplicated, not moved" {
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir/auth"
  printf 'same-token\n' > "$pdir/auth.json"
  printf 'same-token\n' > "$pdir/auth/auth.json"

  run cmd_migrate fixture/work

  [ "$status" -eq 0 ]
  [[ "$output" == *"  remove duplicate credential auth.json (already migrated)"* ]]
  [ ! -e "$pdir/auth.json" ]
  [ "$(cat "$pdir/auth/auth.json" | tr -d '\r')" = "same-token" ]
  run jq -er '.schemaVersion == 2 and .adapterId == "fixture"' "$pdir/.profile.json"
  [ "$status" -eq 0 ]
}

# 18. Hardlinked files inside shared directories are skipped, never merged --
#     the same credential-leak guard the session copier applies.
@test "hardlinked files inside shared dirs are skipped, never merged" {
  mkdir -p "$SHARED_ROOT"
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir/agents"
  printf 'profile-token\n' > "$pdir/auth.json"
  printf 'linked\n' > "$pdir/agents/linked.md"
  make_hardlink "$pdir/agents/linked.md" "$pdir/agents/hard.md" || skip "hardlinks unavailable on this host"

  run cmd_migrate fixture/work

  [ "$status" -eq 0 ]
  [[ "$output" == *"  skip nested link agents/hard.md (hardlinked file left in profile)"* ]]
  [[ "$output" == *"  skip nested link agents/linked.md (hardlinked file left in profile)"* ]]
  [ ! -e "$SHARED_ROOT/agents" ]
  [ -f "$pdir/agents/hard.md" ]
}

# 19. A credential entry that is a link refuses the migration -- linked
#     credentials never enter the profile boundary.
@test "credential entries that are links refuse the migration" {
  mutate_adapter '.account.credentialFiles = ["auth.json", "vault"]'
  mkdir -p "$SHARED_ROOT/vault-real"
  local pdir="$MULTICLI_HOME/fixture/work"
  mkdir -p "$pdir"
  printf 'profile-token\n' > "$pdir/auth.json"
  make_dir_link "$SHARED_ROOT/vault-real" "$pdir/vault" || skip "directory links unavailable on this host"

  run cmd_migrate fixture/work --dry-run

  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot migrate fixture/work: credential 'vault' is a link."* ]]
  [[ "$output" == *"No changes were made."* ]]
  [ ! -e "$pdir/.profile.json" ]
  [ ! -e "$pdir/auth" ]
}

# 20. The migrated profile launches through the existing accountOverlay
#     runtime: credentials come from the profile boundary, normal state from
#     the shared root.
@test "migrated profile launches through the accountOverlay runtime" {
  make_legacy_profile work
  seed_shared_root
  run cmd_migrate fixture/work
  [ "$status" -eq 0 ]

  export MULTICLI_OVERRIDE_BINARY="$MULTICLI_SCRATCH/capture-child"
  export CAPTURE_OUTPUT="$MULTICLI_SCRATCH/capture.json"
  cat > "$MULTICLI_OVERRIDE_BINARY" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
jq -n --arg home "${FIXTURE_HOME:-}" '{home:$home}' > "$CAPTURE_OUTPUT"
PROBE
  chmod +x "$MULTICLI_OVERRIDE_BINARY"

  run cmd_launch fixture/work

  [ "$status" -eq 0 ]
  local runtime_root expected_root
  runtime_root="$(jq -r '.home' "$CAPTURE_OUTPUT")"
  expected_root="$MULTICLI_HOME/fixture/work/.runtime"
  # MSYS converts env values that look like paths to Windows form for the
  # child; compare canonical forms rather than spellings.
  if _multicli_is_windows; then
    [ "$(cygpath -w "$runtime_root")" = "$(cygpath -w "$expected_root")" ]
  else
    [ "$runtime_root" = "$expected_root" ]
  fi
  [ "$(cat "$runtime_root/auth.json" | tr -d '\r')" = "profile-token" ]
  [ "$(cat "$runtime_root/keys/token.json" | tr -d '\r')" = "nested-token" ]
  [ "$(cat "$runtime_root/history.jsonl" | tr -d '\r')" = "shared-history" ]
  [ "$(cat "$runtime_root/config.toml" | tr -d '\r')" = "shared-config" ]
  [ -f "$runtime_root/agents/reviewer/agent.md" ]
}

# 21. A journal update serializes the complete frozen plan in one jq process.
#     Per-op jq loops made large real profiles increasingly slow after every op.
@test "large migration journals use one jq serialization and remain complete" {
  local journal="$MULTICLI_SCRATCH/journal.json"
  local counter="$MULTICLI_SCRATCH/jq-calls"
  local real_jq i
  real_jq="$(command -v jq)"
  : > "$counter"
  MIGRATION_OPS=()
  for ((i=0; i<600; i++)); do
    migration_add_op preserve-unknown "unknown/$i" "/from/$i" "/to/$i" "note $i"
  done
  jq() {
    printf x >> "$counter"
    command "$real_jq" "$@"
  }

  run migration_journal_write "$journal" running fixture work "$SHARED_ROOT" false

  [ "$status" -eq 0 ]
  [ "$(wc -c < "$counter" | tr -d ' ')" -eq 1 ]
  run "$real_jq" -e '
    .status == "running"
    and .preserveUnknown == true
    and (.operations | length) == 600
    and .operations[0] == {
      op:"preserve-unknown", rel:"unknown/0", from:"/from/0", to:"/to/0",
      status:"pending", note:"note 0"
    }
    and .operations[599].rel == "unknown/599"
  ' "$journal"
  [ "$status" -eq 0 ]
}

# 22. Atomic publication means a failed serializer cannot replace the last
#     valid journal with an empty or partial temporary file.
@test "journal serialization failure preserves the previous valid journal" {
  local journal="$MULTICLI_SCRATCH/journal.json"
  local before
  printf '{"status":"before"}\n' > "$journal"
  before="$(cat "$journal")"
  MIGRATION_OPS=()
  jq() {
    printf '{"partial":'
    return 42
  }

  run migration_journal_write "$journal" running fixture work "$SHARED_ROOT" false

  [ "$status" -ne 0 ]
  [ "$(cat "$journal")" = "$before" ]
  [ ! -e "$journal.tmp" ]
}
