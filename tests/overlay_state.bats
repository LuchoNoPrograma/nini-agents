#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  TOOLS_ROOT="$MULTICLI_SCRATCH/tools"
  mkdir -p "$TOOLS_ROOT/fixture"
  export USERPROFILE="$HOME"
  export APPDATA="$HOME/AppData/Roaming"
  export LOCALAPPDATA="$HOME/AppData/Local"
  export MULTICLI_TOOLS_DIR="$TOOLS_ROOT"
  export PATH="$MULTICLI_HOME/bin:$PATH"
  export MULTICLI_OVERRIDE_BINARY="$MULTICLI_SCRATCH/capture-child"
  export CAPTURE_OUTPUT="$MULTICLI_SCRATCH/capture.json"
  cat > "$MULTICLI_OVERRIDE_BINARY" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
jq -n \
  --arg runtime "${FIXTURE_HOME:-}" \
  --arg inherited "${GLOBAL_FIXTURE_TOKEN:-}" \
  --arg profile "${MULTICLI_PROFILE_ID:-}" \
  '{runtime:$runtime,inherited:$inherited,profile:$profile,args:$ARGS.positional}' \
  --args -- "$@" > "$CAPTURE_OUTPUT"
PROBE
  chmod +x "$MULTICLI_OVERRIDE_BINARY"
  write_fixture_adapter
}

teardown() {
  unset MULTICLI_TOOLS_DIR MULTICLI_OVERRIDE_BINARY CAPTURE_OUTPUT GLOBAL_FIXTURE_TOKEN MULTICLI_PROFILE_ID
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
    "clearEnv": ["GLOBAL_FIXTURE_TOKEN"]
  },
  "account": {
    "mechanism": "fileOverlay",
    "credentialFiles": ["auth.json"],
    "credentialPrecedence": ["auth.json"],
    "logoutScope": "profile"
  },
  "normalState": {
    "root": {
      "windows": "%USERPROFILE%\\.fixture",
      "macos": "$HOME/.fixture",
      "linux": "$HOME/.fixture"
    },
    "sharedPaths": ["config.toml", "agents"],
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

@test "schema-v2 new creates stable metadata and account-only directories without copying normal state" {
  mkdir -p "$HOME/.fixture/sessions" "$HOME/.fixture/agents"
  printf 'shared\n' > "$HOME/.fixture/history.jsonl"

  run multicli new fixture/account-a --no-seed

  [ "$status" -eq 0 ]
  [ -f "$MULTICLI_HOME/fixture/account-a/.profile.json" ]
  [ -d "$MULTICLI_HOME/fixture/account-a/auth" ]
  [ ! -e "$MULTICLI_HOME/fixture/account-a/history.jsonl" ]
  run jq -er '.schemaVersion == 2 and .adapterId == "fixture" and (.profileId | test("^[a-f0-9-]{36}$"))' "$MULTICLI_HOME/fixture/account-a/.profile.json"
  [ "$status" -eq 0 ]
}

@test "concurrent launches leave a complete reusable runtime overlay" {
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  local first="$MULTICLI_SCRATCH/first.log"
  local second="$MULTICLI_SCRATCH/second.log"

  multicli launch fixture/account-a >"$first" 2>&1 &
  local first_pid=$!
  multicli launch fixture/account-a >"$second" 2>&1 &
  local second_pid=$!
  local first_status=0 second_status=0
  wait "$first_pid" || first_status=$?
  wait "$second_pid" || second_status=$?

  [ "$first_status" -eq 0 ]
  [ "$second_status" -eq 0 ]
  [ -f "$MULTICLI_HOME/fixture/account-a/.runtime/.runtime-manifest" ]
  [ -e "$MULTICLI_HOME/fixture/account-a/.runtime/config.toml" ]
  [ -e "$MULTICLI_HOME/fixture/account-a/.runtime/auth.json" ]

  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]
}

@test "file overlay keeps credentials per profile while linking normal state and sessions to one native root" {
  mkdir -p "$HOME/.fixture/sessions" "$HOME/.fixture/agents"
  printf 'shared-session\n' > "$HOME/.fixture/history.jsonl"
  printf 'shared-config\n' > "$HOME/.fixture/config.toml"
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli new fixture/account-b --no-seed
  [ "$status" -eq 0 ]

  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]
  local runtime_a
  runtime_a="$MULTICLI_HOME/fixture/account-a/.runtime"
  [ "$(jq -r '.inherited' "$CAPTURE_OUTPUT")" = "" ]
  [ -e "$runtime_a/history.jsonl" ]
  [ -e "$runtime_a/config.toml" ]
  [ -d "$runtime_a/sessions" ]
  [ -e "$runtime_a/auth.json" ]
  local history_a
  history_a="$(cat "$runtime_a/history.jsonl" | tr -d '\r')"
  [ "$history_a" = "shared-session" ]
  printf 'account-a\n' > "$runtime_a/auth.json"
  [ "$(cat "$MULTICLI_HOME/fixture/account-a/auth/auth.json" | tr -d '\r')" = "account-a" ]

  run multicli launch fixture/account-b
  [ "$status" -eq 0 ]
  local runtime_b
  runtime_b="$MULTICLI_HOME/fixture/account-b/.runtime"
  [ "$(cat "$runtime_b/history.jsonl" | tr -d '\r')" = "shared-session" ]
  [ ! -s "$runtime_b/auth.json" ]
  printf 'from-account-b\n' >> "$runtime_b/history.jsonl"
  grep -q 'from-account-b' "$HOME/.fixture/history.jsonl"
  [ "$(cat "$MULTICLI_HOME/fixture/account-a/auth/auth.json" | tr -d '\r')" = "account-a" ]
  [ "$runtime_a" != "$runtime_b" ]
}

@test "foreground launch persists an atomically replaced profile credential" {
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  cat > "$MULTICLI_OVERRIDE_BINARY" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
replacement="${FIXTURE_HOME}/.auth.json.replacement.$$"
printf '%s\n' '{"synthetic":"fresh-login"}' > "$replacement"
chmod 600 "$replacement"
mv -f "$replacement" "${FIXTURE_HOME}/auth.json"
PROBE
  chmod +x "$MULTICLI_OVERRIDE_BINARY"

  run multicli launch fixture/account-a

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  local profile_auth="$MULTICLI_HOME/fixture/account-a/auth/auth.json"
  local runtime_auth="$MULTICLI_HOME/fixture/account-a/.runtime/auth.json"
  run jq -er '.synthetic' "$profile_auth"
  [ "$status" -eq 0 ]
  [ "$output" = "fresh-login" ]
  [ -L "$runtime_auth" ]
  [ "$runtime_auth" -ef "$profile_auth" ]
}

@test "foreground launch persists a successful credential deletion as logout" {
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  local profile_auth="$MULTICLI_HOME/fixture/account-a/auth/auth.json"
  local runtime_auth="$MULTICLI_HOME/fixture/account-a/.runtime/auth.json"
  printf '%s\n' '{"synthetic":"signed-in"}' > "$profile_auth"
  cat > "$MULTICLI_OVERRIDE_BINARY" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
rm -f "${FIXTURE_HOME}/auth.json"
PROBE
  chmod +x "$MULTICLI_OVERRIDE_BINARY"

  run multicli launch fixture/account-a

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [ -f "$profile_auth" ]
  [ ! -s "$profile_auth" ]
  [ -L "$runtime_auth" ]
  [ "$runtime_auth" -ef "$profile_auth" ]
}

@test "foreground launch reconciles credentials while preserving a child failure status" {
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  cat > "$MULTICLI_OVERRIDE_BINARY" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
replacement="${FIXTURE_HOME}/.auth.json.replacement.$$"
printf '%s\n' '{"synthetic":"written-before-failure"}' > "$replacement"
chmod 600 "$replacement"
mv -f "$replacement" "${FIXTURE_HOME}/auth.json"
exit 37
PROBE
  chmod +x "$MULTICLI_OVERRIDE_BINARY"

  run multicli launch fixture/account-a

  [ "$status" -eq 37 ]
  local profile_auth="$MULTICLI_HOME/fixture/account-a/auth/auth.json"
  local runtime_auth="$MULTICLI_HOME/fixture/account-a/.runtime/auth.json"
  [ "$(jq -r '.synthetic' "$profile_auth")" = "written-before-failure" ]
  [ -L "$runtime_auth" ]
  [ "$runtime_auth" -ef "$profile_auth" ]
}

@test "credential reconciliation fails closed for an unexpected runtime symlink" {
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]
  local profile_auth="$MULTICLI_HOME/fixture/account-a/auth/auth.json"
  local runtime_auth="$MULTICLI_HOME/fixture/account-a/.runtime/auth.json"
  local outside="$MULTICLI_SCRATCH/outside-auth.json"
  printf '%s\n' '{"synthetic":"profile"}' > "$profile_auth"
  printf '%s\n' '{"synthetic":"outside"}' > "$outside"
  rm "$runtime_auth"
  ln -s "$outside" "$runtime_auth"

  run multicli launch fixture/account-a

  [ "$status" -ne 0 ]
  [[ "$output" == *"credential path auth.json is an unexpected link"* ]]
  [ "$(jq -r '.synthetic' "$profile_auth")" = "profile" ]
  [ "$(jq -r '.synthetic' "$outside")" = "outside" ]
}

@test "credential reconciliation fails closed for an unexpected runtime directory" {
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]
  local profile_auth="$MULTICLI_HOME/fixture/account-a/auth/auth.json"
  local runtime_auth="$MULTICLI_HOME/fixture/account-a/.runtime/auth.json"
  printf '%s\n' '{"synthetic":"profile"}' > "$profile_auth"
  rm "$runtime_auth"
  mkdir "$runtime_auth"

  run multicli launch fixture/account-a

  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime entry is not a regular file"* ]]
  [ "$(jq -r '.synthetic' "$profile_auth")" = "profile" ]
  [ -d "$runtime_auth" ]
}

@test "credential reconciliation fails closed for an unexpected POSIX hardlink" {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*|Windows*) skip "Windows uses a separate hardlink-target regression" ;;
  esac
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]
  local profile_auth="$MULTICLI_HOME/fixture/account-a/auth/auth.json"
  local runtime_auth="$MULTICLI_HOME/fixture/account-a/.runtime/auth.json"
  local outside="$MULTICLI_SCRATCH/outside-auth.json"
  local alias="$MULTICLI_SCRATCH/outside-auth.alias"
  printf '%s\n' '{"synthetic":"profile"}' > "$profile_auth"
  printf '%s\n' '{"synthetic":"outside"}' > "$outside"
  ln "$outside" "$alias"
  rm "$runtime_auth"
  ln "$outside" "$runtime_auth"

  run multicli launch fixture/account-a

  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime replacement has unexpected hardlinks"* ]]
  [ "$(jq -r '.synthetic' "$profile_auth")" = "profile" ]
  [ "$(jq -r '.synthetic' "$outside")" = "outside" ]
  [ "$outside" -ef "$alias" ]
}

@test "credential reconciliation refuses a linked parent of a nested runtime credential" {
  jq '.account.credentialFiles=["tokens/auth.json"] | .account.credentialPrecedence=["tokens/auth.json"]' \
    "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]
  local profile_auth="$MULTICLI_HOME/fixture/account-a/auth/tokens/auth.json"
  local runtime_parent="$MULTICLI_HOME/fixture/account-a/.runtime/tokens"
  local outside="$MULTICLI_SCRATCH/outside-tokens"
  printf '%s\n' '{"synthetic":"profile"}' > "$profile_auth"
  mkdir "$outside"
  rm "$runtime_parent/auth.json"
  rmdir "$runtime_parent"
  ln -s "$outside" "$runtime_parent"

  run multicli launch fixture/account-a

  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime credential"*"component"*"is a link"* ]]
  [ "$(jq -r '.synthetic' "$profile_auth")" = "profile" ]
  [ ! -e "$outside/auth.json" ]
}

@test "direct reconciliation rejects missing control roots and recovers a warm overlay" {
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]
  local manifest="$TOOLS_ROOT/fixture/adapter.json"
  local profile="$MULTICLI_HOME/fixture/account-a"
  local runtime="$profile/.runtime"
  local profile_auth="$profile/auth/auth.json"
  local runtime_auth="$runtime/auth.json"
  set -- help
  source "$MULTICLI_BIN" >/dev/null 2>&1

  rm "$runtime/.runtime-manifest"
  run runtime_reconcile_profile_credentials_locked "$manifest" "$profile" post 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"runtime manifest is missing or linked"* ]]
  runtime_expected_manifest "$manifest" > "$runtime/.runtime-manifest"

  rm "$runtime_auth"
  mv "$profile/auth" "$profile/auth-away"
  run runtime_reconcile_profile_credentials_locked "$manifest" "$profile" post 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"auth root"*"is missing or linked"* ]]
  mv "$profile/auth-away" "$profile/auth"
  runtime_link_path "$profile_auth" "$runtime_auth" "profile credential"

  local replacement="$runtime/.auth.json.replacement"
  printf '%s\n' '{"synthetic":"warm-recovery"}' > "$replacement"
  mv -f "$replacement" "$runtime_auth"
  run runtime_build_overlay_locked "$manifest" "$profile"

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [ "$(jq -r '.synthetic' "$profile_auth")" = "warm-recovery" ]
  [ -L "$runtime_auth" ]
  [ "$runtime_auth" -ef "$profile_auth" ]
}

@test "two profiles share one credential store while main auth remains profile-local" {
  jq '.sharedCredentialState={
    root:".shared/fixture/oauth",
    entries:[
      {path:".credentials.json",kind:"jsonObjectFile"},
      {path:"oauth-locks",kind:"directory"}
    ],
    legacyMigration:"preserveInactive"
  }' "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli new fixture/account-b --no-seed
  [ "$status" -eq 0 ]

  CAPTURE_OUTPUT="$MULTICLI_SCRATCH/account-a.json" multicli launch fixture/account-a &
  local first_pid=$!
  CAPTURE_OUTPUT="$MULTICLI_SCRATCH/account-b.json" multicli launch fixture/account-b &
  local second_pid=$!
  local first_status=0 second_status=0
  wait "$first_pid" || first_status=$?
  wait "$second_pid" || second_status=$?
  [ "$first_status" -eq 0 ]
  [ "$second_status" -eq 0 ]

  local store="$MULTICLI_HOME/.shared/fixture/oauth"
  local runtime_a="$MULTICLI_HOME/fixture/account-a/.runtime"
  local runtime_b="$MULTICLI_HOME/fixture/account-b/.runtime"
  [ -f "$store/.credentials.json" ]
  run jq -e 'type == "object" and length == 0' "$store/.credentials.json"
  [ "$status" -eq 0 ]
  [ -d "$store/oauth-locks" ]
  [ "$(stat -c '%a' "$store/.credentials.json" 2>/dev/null || stat -f '%Lp' "$store/.credentials.json")" = 600 ]
  [ "$(stat -c '%a' "$store/oauth-locks" 2>/dev/null || stat -f '%Lp' "$store/oauth-locks")" = 700 ]
  [ -L "$runtime_a/.credentials.json" ]
  [ -L "$runtime_b/.credentials.json" ]
  [ -L "$runtime_a/oauth-locks" ]
  [ -L "$runtime_b/oauth-locks" ]
  [ "$runtime_a/.credentials.json" -ef "$store/.credentials.json" ]
  [ "$runtime_b/.credentials.json" -ef "$store/.credentials.json" ]
  [ "$runtime_a/oauth-locks" -ef "$store/oauth-locks" ]
  [ "$runtime_b/oauth-locks" -ef "$store/oauth-locks" ]
  [ ! "$runtime_a/auth.json" -ef "$runtime_b/auth.json" ]

  printf '{"synthetic":"shared"}\n' > "$runtime_a/.credentials.json"
  run jq -er '.synthetic' "$runtime_b/.credentials.json"
  [ "$status" -eq 0 ]
  [ "$output" = shared ]
  printf 'account-a\n' > "$runtime_a/auth.json"
  [ ! -s "$runtime_b/auth.json" ]
  grep -qxF '.credentials.json' "$runtime_a/.runtime-manifest"
  grep -qxF 'oauth-locks' "$runtime_a/.runtime-manifest"

  run multicli doctor --deep
  [ "$status" -eq 0 ]
  [[ "$output" != *"wrong target"* ]]
}

@test "a warm overlay revalidates a replaced shared credential backing file" {
  jq '.sharedCredentialState={
    root:".shared/fixture/oauth",
    entries:[{path:".credentials.json",kind:"jsonObjectFile"}],
    legacyMigration:"preserveInactive"
  }' "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]

  local store="$MULTICLI_HOME/.shared/fixture/oauth/.credentials.json"
  local outside="$MULTICLI_SCRATCH/outside-credentials.json"
  printf '{}\n' > "$outside"
  rm "$store"
  ln -s "$outside" "$store"

  run multicli launch fixture/account-a

  [ "$status" -ne 0 ]
  [[ "$output" == *"links are not allowed in the backing store"* ]]
  [ -L "$store" ]
}

@test "shared credential initialization rejects an unexpected POSIX hardlink" {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*|Windows*) skip "Windows runtimes intentionally expose declared files through managed hardlinks" ;;
  esac
  jq '.sharedCredentialState={
    root:".shared/fixture/oauth",
    entries:[{path:".credentials.json",kind:"jsonObjectFile"}],
    legacyMigration:"preserveInactive"
  }' "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  mkdir -p "$MULTICLI_HOME/.shared/fixture/oauth"
  printf '{}\n' > "$MULTICLI_HOME/.shared/fixture/oauth/.credentials.json"
  ln "$MULTICLI_HOME/.shared/fixture/oauth/.credentials.json" "$MULTICLI_SCRATCH/unmanaged-alias"

  run multicli launch fixture/account-a

  [ "$status" -ne 0 ]
  [[ "$output" == *"unexpected hardlinks detected"* ]]
  [ ! -e "$MULTICLI_HOME/fixture/account-a/.runtime" ]
}

@test "shared credential initialization rejects a linked store component" {
  jq '.sharedCredentialState={
    root:".shared/fixture/oauth",
    entries:[{path:".credentials.json",kind:"jsonObjectFile"}],
    legacyMigration:"preserveInactive"
  }' "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  mkdir -p "$MULTICLI_HOME/.shared" "$MULTICLI_SCRATCH/outside"
  ln -s "$MULTICLI_SCRATCH/outside" "$MULTICLI_HOME/.shared/fixture"

  run multicli launch fixture/account-a

  [ "$status" -ne 0 ] || {
    printf 'unexpected success: %s\n' "$output" >&3
    find "$MULTICLI_HOME/.shared" -maxdepth 4 -printf '%y %p -> %l\n' >&3
  }
  [ "$status" -ne 0 ]
  [[ "$output" == *"shared credential store component"*"is a link"* ]]
  [ -L "$MULTICLI_HOME/.shared/fixture" ]
  [ ! -e "$MULTICLI_SCRATCH/outside/oauth/.credentials.json" ]
}

@test "Codex adapter links documented instructions rules and logs as shared normal state" {
  mkdir -p "$TOOLS_ROOT/codex" "$HOME/.codex/rules" "$HOME/.codex/log"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$TOOLS_ROOT/codex/adapter.json"
  printf 'global guidance\n' > "$HOME/.codex/AGENTS.md"
  printf 'prefix_rule(pattern=["git", "status"], decision="allow")\n' > "$HOME/.codex/rules/default.rules"
  printf 'shared log\n' > "$HOME/.codex/log/codex.log"

  run multicli new codex/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch codex/account-a
  [ "$status" -eq 0 ]

  local runtime_rules="$MULTICLI_HOME/codex/account-a/.runtime/rules"
  local runtime_agents="$MULTICLI_HOME/codex/account-a/.runtime/AGENTS.md"
  local runtime_log="$MULTICLI_HOME/codex/account-a/.runtime/log"
  [ -L "$runtime_rules" ]
  [ -L "$runtime_agents" ]
  [ -L "$runtime_log" ]
  [ "$(cat "$runtime_agents" | tr -d '\r')" = 'global guidance' ]
  [ "$(cat "$runtime_rules/default.rules" | tr -d '\r')" = 'prefix_rule(pattern=["git", "status"], decision="allow")' ]
  [ "$(cat "$runtime_log/codex.log" | tr -d '\r')" = 'shared log' ]
  run jq -e --arg root "$HOME/.codex" '.args == [
    "-c", "cli_auth_credentials_store=\"file\"",
    "-c", "mcp_oauth_credentials_store=\"file\"",
    "-c", ("sqlite_home=\"" + $root + "\"")
  ]' "$CAPTURE_OUTPUT"
  [ "$status" -eq 0 ]
  [ ! -e "$MULTICLI_HOME/codex/account-a/auth/rules" ]
  [ ! -e "$MULTICLI_HOME/codex/account-a/auth/AGENTS.md" ]
  [ ! -e "$MULTICLI_HOME/codex/account-a/auth/log" ]
}

@test "Hyper without the title-lock opt-in emits no private title protocol" {
  mkdir -p "$TOOLS_ROOT/codex" "$MULTICLI_HOME/codex/omega"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$TOOLS_ROOT/codex/adapter.json"

  run env TERM_PROGRAM=Hyper NINI_AGENTS_HYPER_TITLE_LOCK= "$MULTICLI_BIN" launch codex/omega

  [ "$status" -eq 0 ]
  [[ "$output" != *"__MULTICLI_TITLE_LOCK__"* ]]
  [[ "$output" != *"__MULTICLI_TITLE_UNLOCK__"* ]]
}

@test "opted-in Hyper locks each schema-v2 Codex profile title to its alias" {
  mkdir -p "$TOOLS_ROOT/codex"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$TOOLS_ROOT/codex/adapter.json"
  run multicli new codex/omega --no-seed
  [ "$status" -eq 0 ]
  run multicli new codex/nexo --no-seed
  [ "$status" -eq 0 ]

  local lock unlock
  lock="$(printf '\033]0;__MULTICLI_TITLE_LOCK__:omega\007')"
  unlock="$(printf '\033]0;__MULTICLI_TITLE_UNLOCK__\007')"
  run env TERM_PROGRAM=Hyper NINI_AGENTS_HYPER_TITLE_LOCK=1 "$MULTICLI_BIN" launch codex/omega
  [ "$status" -eq 0 ]
  [[ "$output" == *"$lock"*"$unlock"* ]]

  lock="$(printf '\033]0;__MULTICLI_TITLE_LOCK__:nexo\007')"
  run env TERM_PROGRAM=Hyper NINI_AGENTS_HYPER_TITLE_LOCK=1 "$MULTICLI_BIN" launch codex/nexo
  [ "$status" -eq 0 ]
  [[ "$output" == *"$lock"*"$unlock"* ]]
}

@test "opted-in Hyper title locking also covers a legacy whole-root Codex profile" {
  mkdir -p "$TOOLS_ROOT/codex" "$MULTICLI_HOME/codex/tienda"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$TOOLS_ROOT/codex/adapter.json"

  local lock unlock
  lock="$(printf '\033]0;__MULTICLI_TITLE_LOCK__:tienda\007')"
  unlock="$(printf '\033]0;__MULTICLI_TITLE_UNLOCK__\007')"
  run env TERM_PROGRAM=Hyper NINI_AGENTS_HYPER_TITLE_LOCK=1 "$MULTICLI_BIN" launch codex/tienda

  [ "$status" -eq 0 ]
  [[ "$output" == *"$lock"*"$unlock"* ]]
  [[ "$output" == *"legacy whole-root"* ]]
}

@test "account overlay keeps direct state outside runtime and appends expanded adapter args" {
  jq '.isolation.args=["-c", "sqlite_home=\"{sharedStateRoot}\""]
    | .normalState.sessionPaths += ["state_5.sqlite"]
    | .normalState.filePaths += ["state_5.sqlite"]
    | .normalState.directPaths=["state_5.sqlite"]' \
    "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"

  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch fixture/account-a --user-value -- prompt

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.fixture/state_5.sqlite" ]
  [ ! -e "$MULTICLI_HOME/fixture/account-a/.runtime/state_5.sqlite" ]
  run jq -e --arg root "$HOME/.fixture" \
    '.args == ["--user-value", "prompt", "-c", ("sqlite_home=\"" + $root + "\"")]' "$CAPTURE_OUTPUT"
  [ "$status" -eq 0 ]

  # The top-level CLI consumes its own `--`; exercise the runtime boundary
  # directly to prove enforced options stay before a tool-level delimiter.
  set -- help
  source "$MULTICLI_BIN" >/dev/null 2>&1
  run runtime_launch_account_overlay fixture "$MULTICLI_HOME/fixture/account-a" "$MULTICLI_OVERRIDE_BINARY" --direct -- prompt
  [ "$status" -eq 0 ]
  run jq -e --arg root "$HOME/.fixture" \
    '.args == ["--direct", "-c", ("sqlite_home=\"" + $root + "\""), "--", "prompt"]' "$CAPTURE_OUTPUT"
  [ "$status" -eq 0 ]
}

@test "launch clears inherited account variables without mutating the parent shell" {
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  export GLOBAL_FIXTURE_TOKEN='wrong-account-secret'

  run multicli launch fixture/account-a

  [ "$status" -eq 0 ]
  [ "$(jq -r '.inherited' "$CAPTURE_OUTPUT")" = "" ]
  [ "$GLOBAL_FIXTURE_TOKEN" = "wrong-account-secret" ]
}

@test "doctor --deep reports unexpected runtime files as adapter defects" {
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]

  printf 'rogue\n' > "$MULTICLI_HOME/fixture/account-a/.runtime/rogue.txt"
  run multicli doctor --deep
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected runtime file rogue.txt"* ]]
}

@test "doctor --deep is quiet when runtime contains only declared links" {
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]

  jq '.normalState.runtimePaths=["cache", "version.json"]' \
    "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"
  mkdir -p "$MULTICLI_HOME/fixture/account-a/.runtime/cache/nested"
  printf 'generated\n' > "$MULTICLI_HOME/fixture/account-a/.runtime/cache/nested/item"
  printf 'generated\n' > "$MULTICLI_HOME/fixture/account-a/.runtime/version.json"

  run multicli doctor --deep
  [ "$status" -eq 0 ]
  [[ "$output" != *"unexpected runtime file"* ]]
}

@test "launch rebuilds an existing runtime when the adapter shared root changes" {
  mkdir -p "$HOME/.fixture"
  printf 'old-root\n' > "$HOME/.fixture/config.toml"
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]
  [ "$(tr -d '\r' < "$MULTICLI_HOME/fixture/account-a/.runtime/config.toml")" = "old-root" ]

  mkdir -p "$HOME/.fixture-new"
  printf 'new-root\n' > "$HOME/.fixture-new/config.toml"
  jq '.normalState.root.windows="%USERPROFILE%\\.fixture-new" | .normalState.root.macos="$HOME/.fixture-new" | .normalState.root.linux="$HOME/.fixture-new"' \
    "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"

  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]
  [ "$(tr -d '\r' < "$MULTICLI_HOME/fixture/account-a/.runtime/config.toml")" = "new-root" ]
  [ "$MULTICLI_HOME/fixture/account-a/.runtime/config.toml" -ef "$HOME/.fixture-new/config.toml" ]
}

@test "doctor --deep understands runtimeSubdir and detects missing or misdirected links" {
  jq '.normalState.runtimeSubdir="state"' "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"
  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]

  local runtime="$MULTICLI_HOME/fixture/account-a/.runtime/state"
  run multicli doctor --deep
  [ "$status" -eq 0 ]
  [[ "$output" != *"wrong target"* ]]

  rm "$runtime/agents"
  run multicli doctor --deep
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing declared runtime path state/agents"* ]]

  run multicli launch fixture/account-a
  [ "$status" -eq 0 ]
  mkdir -p "$HOME/.fixture/wrong-agents"
  rm "$runtime/agents"
  ln -s "$HOME/.fixture/wrong-agents" "$runtime/agents"
  run multicli doctor --deep
  [ "$status" -eq 1 ]
  [[ "$output" == *"runtime link state/agents has the wrong target"* ]]
}

@test "legacy file-overlay launch keeps the whole root and does not migrate credentials" {
  local profile="$MULTICLI_HOME/fixture/legacy"
  local expected_auth="$MULTICLI_SCRATCH/legacy-auth.expected"
  mkdir -p "$profile"
  printf '%s\n' '{"fixtureCredential":"unchanged"}' > "$profile/auth.json"
  cp "$profile/auth.json" "$expected_auth"
  export GLOBAL_FIXTURE_TOKEN='wrong-account-secret'
  export MULTICLI_PROFILE_ID='stale-schema-v2-id'

  run multicli launch fixture/legacy

  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy whole-root"* ]]
  [ "$(jq -r '.runtime' "$CAPTURE_OUTPUT")" = "$profile" ]
  [ "$(jq -r '.inherited' "$CAPTURE_OUTPUT")" = "" ]
  [ "$(jq -r '.profile' "$CAPTURE_OUTPUT")" = "" ]
  cmp -s "$expected_auth" "$profile/auth.json"
  [ ! -e "$profile/.profile.json" ]
  [ ! -e "$profile/.runtime" ]
  [ ! -e "$profile/auth" ]
}

@test "legacy whole-root launch applies enforced adapter arguments inside the profile root" {
  jq '.isolation.args=["-c", "sqlite_home=\"{sharedStateRoot}\""]' \
    "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"
  local profile="$MULTICLI_HOME/fixture/legacy-args"
  mkdir -p "$profile"
  printf '{}\n' > "$profile/auth.json"

  run multicli launch fixture/legacy-args --user-value

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  run jq -e --arg root "$profile" \
    '.args == ["--user-value", "-c", ("sqlite_home=\"" + $root + "\"")]' "$CAPTURE_OUTPUT"
  [ "$status" -eq 0 ]
}

@test "legacy whole-root compatibility stays closed for process-secret adapters" {
  jq '.account = {
    "mechanism": "processSecret",
    "credentialFiles": [],
    "credentialPrecedence": ["FIXTURE_TOKEN"],
    "logoutScope": "process",
    "secret": {"environmentVariable": "FIXTURE_TOKEN"}
  }' "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"
  local profile="$MULTICLI_HOME/fixture/legacy-secret"
  mkdir -p "$profile"

  run multicli launch fixture/legacy-secret

  [ "$status" -eq 1 ]
  [[ "$output" == *"missing schema-v2 metadata"* ]]
  [ ! -e "$CAPTURE_OUTPUT" ]
  [ ! -e "$profile/.profile.json" ]
  [ ! -e "$profile/.runtime" ]
  [ ! -e "$profile/auth" ]
}

@test "invalid adapters fail before profile creation" {
  jq '.normalState.sharedPaths=["auth.json"]' "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/invalid.json"
  mv "$TOOLS_ROOT/fixture/invalid.json" "$TOOLS_ROOT/fixture/adapter.json"

  run multicli new fixture/account-a --no-seed

  [ "$status" -eq 1 ]
  [ ! -e "$MULTICLI_HOME/fixture/account-a" ]
  [[ "$output" == *"Invalid adapter 'fixture'"* ]]
}

@test "tools and doctor show supported-mode prerequisites" {
  jq '.support.windows.reason="requires --isolated whole-root" | .support.macos.reason="requires --isolated whole-root" | .support.linux.reason="requires --isolated whole-root"' "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"

  run multicli tools

  [ "$status" -eq 0 ]
  [[ "$output" == *"fixture"* ]]
  [[ "$output" == *"requires --isolated whole-root"* ]]

  run multicli doctor

  [ "$status" -eq 0 ]
  [[ "$output" == *"supported: requires --isolated whole-root"* ]]
}

@test "inseparable default profiles direct users to --isolated" {
  jq '.account={"mechanism":"inseparable","credentialFiles":[],"credentialPrecedence":[],"logoutScope":"user","reason":"Auth and sessions share one database."} | .support.linux.reason="requires --isolated whole-root"' \
    "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture/updated.json"
  mv "$TOOLS_ROOT/fixture/updated.json" "$TOOLS_ROOT/fixture/adapter.json"

  run multicli new fixture/account-a --no-seed
  [ "$status" -eq 0 ]

  run multicli launch fixture/account-a

  [ "$status" -eq 1 ]
  [[ "$output" == *"Create this profile with --isolated"* ]]
  [[ "$output" != *"legacy-isolated"* ]]
}
