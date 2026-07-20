#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  # shellcheck source=../lib/credential-store.sh
  source "$MULTICLI_REPO_ROOT/lib/credential-store.sh"
  TOOLS_ROOT="$MULTICLI_SCRATCH/tools"
  mkdir -p "$TOOLS_ROOT/secretcli"
  export USERPROFILE="$HOME"
  export APPDATA="$HOME/AppData/Roaming"
  export LOCALAPPDATA="$HOME/AppData/Local"
  export MULTICLI_TOOLS_DIR="$TOOLS_ROOT"
  export MULTICLI_OVERRIDE_BINARY="$MULTICLI_SCRATCH/capture-child"
  export CAPTURE_OUTPUT="$MULTICLI_SCRATCH/capture.json"
  cat > "$MULTICLI_OVERRIDE_BINARY" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
jq -n --arg home "${SECRETCLI_HOME:-}" --arg token "${SECRETCLI_TOKEN:-}" '{home:$home,token:$token}' > "$CAPTURE_OUTPUT"
PROBE
  chmod +x "$MULTICLI_OVERRIDE_BINARY"
  cat > "$TOOLS_ROOT/secretcli/adapter.json" <<'JSON'
{
  "schemaVersion": 2,
  "id": "secretcli",
  "displayName": "Secret CLI",
  "kind": "cli",
  "binary": { "windows": ["secretcli.exe"], "macos": ["secretcli"], "linux": ["secretcli"] },
  "isolation": {
    "strategy": "accountOverlay",
    "mode": "foreground",
    "env": { "SECRETCLI_HOME": "{sharedStateRoot}" },
    "clearEnv": []
  },
  "account": {
    "mechanism": "processSecret",
    "credentialFiles": [],
    "credentialPrecedence": ["SECRETCLI_TOKEN"],
    "logoutScope": "process",
    "secret": { "environmentVariable": "SECRETCLI_TOKEN" }
  },
  "normalState": {
    "root": { "windows": "%USERPROFILE%/.secretcli", "macos": "$HOME/.secretcli", "linux": "$HOME/.secretcli" },
    "sharedPaths": ["config.toml"],
    "sessionPaths": ["sessions"],
    "filePaths": ["config.toml"],
    "unsafePaths": []
  },
  "concurrency": { "level": "multiWriter", "singletonScope": "none" },
  "support": {
    "windows": { "level": "experimental", "reason": "Fixture only." },
    "macos": { "level": "experimental", "reason": "Fixture only." },
    "linux": { "level": "experimental", "reason": "Fixture only." }
  },
  "versionCommand": ["--version"]
}
JSON
  MULTICLI_TEST_TARGET=""
}

teardown() {
  if [ -n "$MULTICLI_TEST_TARGET" ]; then
    mc_cred_clear "$MULTICLI_TEST_TARGET" 2>/dev/null || true
  fi
  unset MULTICLI_TOOLS_DIR MULTICLI_OVERRIDE_BINARY CAPTURE_OUTPUT
  teardown_scratch
}

@test "auth set/status/clear round-trips a profile secret in the OS store" {
  run multicli new secretcli/account-a --no-seed
  [ "$status" -eq 0 ]

  run bash -c "printf 'token-account-a\n' | '$MULTICLI_BIN' auth set secretcli/account-a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stored credential for secretcli/account-a."* ]]

  run multicli auth status secretcli/account-a
  [ "$status" -eq 0 ]
  [[ "$output" == *"Credential present"* ]]

  local profile_id
  profile_id="$(jq -r '.profileId' "$MULTICLI_HOME/secretcli/account-a/.profile.json")"
  MULTICLI_TEST_TARGET="multi-cli/secretcli/$profile_id/SECRETCLI_TOKEN"
  [ "$(mc_cred_get "$MULTICLI_TEST_TARGET")" = "token-account-a" ]

  run multicli auth clear secretcli/account-a
  [ "$status" -eq 0 ]
  run multicli auth status secretcli/account-a
  [ "$status" -eq 1 ]
  [[ "$output" == *"No credential stored"* ]]
  MULTICLI_TEST_TARGET=""
}

@test "process-secret launch injects only the profile credential into the child" {
  run multicli new secretcli/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli new secretcli/account-b --no-seed
  [ "$status" -eq 0 ]
  run bash -c "printf 'token-account-a\n' | '$MULTICLI_BIN' auth set secretcli/account-a"
  [ "$status" -eq 0 ]
  run bash -c "printf 'token-account-b\n' | '$MULTICLI_BIN' auth set secretcli/account-b"
  [ "$status" -eq 0 ]
  MULTICLI_TEST_TARGET="multi-cli/secretcli/$(jq -r '.profileId' "$MULTICLI_HOME/secretcli/account-a/.profile.json")/SECRETCLI_TOKEN"

  run multicli launch secretcli/account-a
  [ "$status" -eq 0 ]
  [ "$(jq -r '.token' "$CAPTURE_OUTPUT")" = "token-account-a" ]
  local captured_home
  captured_home="$(cygpath "$(jq -r '.home' "$CAPTURE_OUTPUT")")"
  [ "$captured_home" = "$HOME/.secretcli" ]

  run multicli launch secretcli/account-b
  [ "$status" -eq 0 ]
  [ "$(jq -r '.token' "$CAPTURE_OUTPUT")" = "token-account-b" ]

  mc_cred_clear "multi-cli/secretcli/$(jq -r '.profileId' "$MULTICLI_HOME/secretcli/account-b/.profile.json")/SECRETCLI_TOKEN" 2>/dev/null || true
}

@test "launch without a stored credential fails with the auth set hint" {
  run multicli new secretcli/account-a --no-seed
  [ "$status" -eq 0 ]

  run multicli launch secretcli/account-a

  [ "$status" -eq 1 ]
  [[ "$output" == *"multi-cli auth set secretcli/account-a"* ]]
}

@test "auth rejects tools that do not use process-secret credentials" {
  run multicli auth status codex/anything

  [ "$status" -eq 1 ]
  [[ "$output" == *"does not use a process-secret credential"* ]]
}
