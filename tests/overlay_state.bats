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
  '{runtime:$runtime,inherited:$inherited,profile:$profile}' > "$CAPTURE_OUTPUT"
PROBE
  chmod +x "$MULTICLI_OVERRIDE_BINARY"
  write_fixture_adapter
}

teardown() {
  unset MULTICLI_TOOLS_DIR MULTICLI_OVERRIDE_BINARY CAPTURE_OUTPUT GLOBAL_FIXTURE_TOKEN
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

  run multicli doctor --deep
  [ "$status" -eq 0 ]
  [[ "$output" != *"unexpected runtime file"* ]]
}

@test "launch without schema-v2 metadata aborts with a clear message instead of dying silently" {
  mkdir -p "$MULTICLI_HOME/fixture/legacy"
  run multicli launch fixture/legacy
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing schema-v2 metadata"* ]]
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
