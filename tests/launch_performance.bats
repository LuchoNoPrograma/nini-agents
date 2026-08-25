#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  export USERPROFILE="$HOME"
  export APPDATA="$HOME/AppData/Roaming"
  export LOCALAPPDATA="$HOME/AppData/Local"
  mkdir -p "$MULTICLI_TOOLS_DIR/codex"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$MULTICLI_TOOLS_DIR/codex/adapter.json"
  export MULTICLI_OVERRIDE_BINARY="$MULTICLI_SCRATCH/noop-codex"
  cat > "$MULTICLI_OVERRIDE_BINARY" <<'PROBE'
#!/usr/bin/env bash
exit 0
PROBE
  chmod +x "$MULTICLI_OVERRIDE_BINARY"
}

teardown() {
  unset MULTICLI_OVERRIDE_BINARY REAL_JQ JQ_TRACE
  teardown_scratch
}

@test "a warm Codex launch uses a bounded number of jq processes" {
  run multicli new codex/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch codex/account-a
  [ "$status" -eq 0 ]

  local real_jq trace fake_bin calls
  real_jq="$(command -v jq)"
  trace="$MULTICLI_SCRATCH/jq.trace"
  fake_bin="$MULTICLI_SCRATCH/counting-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/jq" <<'COUNTING_JQ'
#!/usr/bin/env bash
printf 'jq\n' >> "${JQ_TRACE:?}"
exec "${REAL_JQ:?}" "$@"
COUNTING_JQ
  chmod +x "$fake_bin/jq"

  run env PATH="$fake_bin:$PATH" REAL_JQ="$real_jq" JQ_TRACE="$trace" \
    "$MULTICLI_BIN" launch codex/account-a

  [ "$status" -eq 0 ]
  calls="$(wc -l < "$trace" | tr -d ' ')"
  [ "$calls" -le 12 ] || {
    printf 'warm launch spawned %s jq processes\n' "$calls" >&3
    return 1
  }
}

@test "the fast launch path still rejects a used traversal path" {
  run multicli new codex/account-a --no-seed
  [ "$status" -eq 0 ]
  run multicli launch codex/account-a
  [ "$status" -eq 0 ]

  jq '.normalState.sharedPaths=["../outside"] | .normalState.filePaths=[] | .normalState.directPaths=[] | .normalState.migrationPreservePaths=[]' \
    "$MULTICLI_TOOLS_DIR/codex/adapter.json" > "$MULTICLI_TOOLS_DIR/codex/updated.json"
  mv "$MULTICLI_TOOLS_DIR/codex/updated.json" "$MULTICLI_TOOLS_DIR/codex/adapter.json"

  run multicli launch codex/account-a

  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe shared state path '../outside'"* ]]
  [ ! -e "$HOME/outside" ]
}

@test "the fast launch path rejects credential and shared-state overlap before linking" {
  run multicli new codex/account-a --no-seed
  [ "$status" -eq 0 ]

  jq '.account.credentialFiles=["collision/auth.json"]
    | .normalState.sharedPaths=["collision"]
    | .normalState.sessionPaths=[]
    | .normalState.runtimePaths=[]
    | .normalState.filePaths=[]
    | .normalState.directPaths=[]
    | .normalState.migrationPreservePaths=[]
    | .normalState.unsafePaths=[]' \
    "$MULTICLI_TOOLS_DIR/codex/adapter.json" > "$MULTICLI_TOOLS_DIR/codex/updated.json"
  mv "$MULTICLI_TOOLS_DIR/codex/updated.json" "$MULTICLI_TOOLS_DIR/codex/adapter.json"

  run multicli launch codex/account-a

  [ "$status" -ne 0 ]
  [[ "$output" == *"credential path 'collision/auth.json' overlaps shared path 'collision'"* ]]
  [ ! -e "$HOME/.codex/collision" ]
  [ ! -e "$MULTICLI_HOME/codex/account-a/.runtime/collision" ]
}

@test "the fast launch path rejects unknown placeholders in enforced arguments" {
  run multicli new codex/account-a --no-seed
  [ "$status" -eq 0 ]

  jq '.isolation.args=["--state={outsideRoot}"]' \
    "$MULTICLI_TOOLS_DIR/codex/adapter.json" > "$MULTICLI_TOOLS_DIR/codex/updated.json"
  mv "$MULTICLI_TOOLS_DIR/codex/updated.json" "$MULTICLI_TOOLS_DIR/codex/adapter.json"

  run multicli launch codex/account-a

  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown placeholder '{outsideRoot}'"* ]]
}

@test "doctor keeps exhaustive semantic adapter validation off the launch path" {
  jq '.normalState.unsafePaths=["../unused"]' \
    "$MULTICLI_TOOLS_DIR/codex/adapter.json" > "$MULTICLI_TOOLS_DIR/codex/updated.json"
  mv "$MULTICLI_TOOLS_DIR/codex/updated.json" "$MULTICLI_TOOLS_DIR/codex/adapter.json"

  run multicli doctor

  [ "$status" -ne 0 ]
  [[ "$output" == *"codex adapter is invalid"* ]]
  [[ "$output" == *"unsafe path '../unused' must be a safe relative path"* ]]
}
