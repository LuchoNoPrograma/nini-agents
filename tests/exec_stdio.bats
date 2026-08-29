#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  export MULTICLI_TOOLS_DIR="$MULTICLI_SCRATCH/tools"
  export MULTICLI_OVERRIDE_BINARY="$MULTICLI_SCRATCH/stdio-probe"
  export EXEC_CAPTURE="$MULTICLI_SCRATCH/exec-capture.json"
  export GLOBAL_FIXTURE_TOKEN="parent-secret"
  mkdir -p "$MULTICLI_TOOLS_DIR/fixture"
  cp "$BATS_TEST_DIRNAME/../ai-tools/codex/adapter.json" \
    "$MULTICLI_TOOLS_DIR/fixture/adapter.json"
  jq \
    '.id="fixture"
     | .displayName="Fixture CLI"
     | .binary.windows=["fixture.exe"]
     | .binary.macos=["fixture"]
     | .binary.linux=["fixture"]
     | .isolation.env={"FIXTURE_HOME":"{runtimeRoot}"}
     | .isolation.clearEnv=["GLOBAL_FIXTURE_TOKEN"]
     | .isolation.args=["-c", "sqlite_home=\"{sharedStateRoot}\""]
     | .sharedCredentialState.root=".shared/fixture/mcp"
     | .normalState.root.windows="%USERPROFILE%\\.fixture"
     | .normalState.root.macos="$HOME/.fixture"
     | .normalState.root.linux="$HOME/.fixture"' \
    "$MULTICLI_TOOLS_DIR/fixture/adapter.json" > "$MULTICLI_TOOLS_DIR/fixture/updated.json"
  mv "$MULTICLI_TOOLS_DIR/fixture/updated.json" "$MULTICLI_TOOLS_DIR/fixture/adapter.json"

  cat > "$MULTICLI_OVERRIDE_BINARY" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
IFS= read -r request
jq -n \
  --arg runtime "${FIXTURE_HOME:-}" \
  --arg inherited "${GLOBAL_FIXTURE_TOKEN:-}" \
  --arg profile "${MULTICLI_PROFILE_ID:-}" \
  '{runtime:$runtime,inherited:$inherited,profile:$profile,args:$ARGS.positional}' \
  --args -- "$@" > "$EXEC_CAPTURE"
printf '%s\n' "$request"
printf 'child-stderr\n' >&2
exit "${PROBE_EXIT_CODE:-0}"
PROBE
  chmod +x "$MULTICLI_OVERRIDE_BINARY"

  multicli new fixture/account-a --no-seed >/dev/null
}

teardown() {
  unset MULTICLI_OVERRIDE_BINARY EXEC_CAPTURE GLOBAL_FIXTURE_TOKEN PROBE_EXIT_CODE
  teardown_scratch
}

@test "matrix: exec keeps stdout clean while preserving stdio, overlay env, and enforced arguments (+1 related)" {
  # Case 1: exec keeps stdout clean while preserving stdio, overlay env, and enforced arguments
  local stdout="$MULTICLI_SCRATCH/stdout"
  local stderr="$MULTICLI_SCRATCH/stderr"
  local request='{"jsonrpc":"2.0","id":1,"method":"initialize"}'

  printf '%s\n' "$request" | \
    "$MULTICLI_BIN" exec fixture/account-a -- app-server --stdio >"$stdout" 2>"$stderr"

  [ "$(cat "$stdout")" = "$request" ]
  [ "$(cat "$stderr")" = "child-stderr" ]
  local runtime="$MULTICLI_HOME/fixture/account-a/.runtime"
  local shared="$HOME/.fixture"
  run jq -e \
    --arg runtime "$runtime" \
    --arg shared "$shared" \
    '.runtime == $runtime
     and .inherited == ""
     and (.profile | test("^[a-f0-9-]{36}$"))
     and .args == ["app-server", "--stdio", "-c", ("sqlite_home=\"" + $shared + "\"")]' \
    "$EXEC_CAPTURE"
  [ "$status" -eq 0 ]

  teardown
  setup

  # Case 2: exec replaces the Bash wrapper and propagates the child exit code
  local pid_probe="$MULTICLI_SCRATCH/pid-probe"
  local child_pid_file="$MULTICLI_SCRATCH/child.pid"
  cat > "$pid_probe" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" > "${CHILD_PID_FILE:?}"
sleep 0.1
PROBE
  chmod +x "$pid_probe"
  export MULTICLI_OVERRIDE_BINARY="$pid_probe"
  export CHILD_PID_FILE="$child_pid_file"

  "$MULTICLI_BIN" exec fixture/account-a >/dev/null 2>"$MULTICLI_SCRATCH/pid-stderr" &
  local launcher_pid=$!
  local attempts=0
  while [ ! -s "$child_pid_file" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -s "$child_pid_file" ]
  [ "$(cat "$child_pid_file")" = "$launcher_pid" ]
  wait "$launcher_pid"

  export MULTICLI_OVERRIDE_BINARY="$MULTICLI_SCRATCH/stdio-probe"
  export PROBE_EXIT_CODE=23
  local status=0
  printf 'request\n' | "$MULTICLI_BIN" exec fixture/account-a \
    >"$MULTICLI_SCRATCH/exit-stdout" 2>"$MULTICLI_SCRATCH/exit-stderr" || status=$?
  [ "$status" -eq 23 ]
  [ "$(cat "$MULTICLI_SCRATCH/exit-stdout")" = "request" ]
  [ "$(cat "$MULTICLI_SCRATCH/exit-stderr")" = "child-stderr" ]
}

@test "the next launch recovers a credential atomically replaced during exec" {
  local atomic_probe="$MULTICLI_SCRATCH/atomic-auth-probe"
  cat > "$atomic_probe" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
replacement="${FIXTURE_HOME}/.auth.json.replacement.$$"
printf '%s\n' '{"synthetic":"exec-login"}' > "$replacement"
chmod 600 "$replacement"
mv -f "$replacement" "${FIXTURE_HOME}/auth.json"
PROBE
  chmod +x "$atomic_probe"
  export MULTICLI_OVERRIDE_BINARY="$atomic_probe"

  "$MULTICLI_BIN" exec fixture/account-a

  local noop_probe="$MULTICLI_SCRATCH/noop-probe"
  cat > "$noop_probe" <<'PROBE'
#!/usr/bin/env bash
exit 0
PROBE
  chmod +x "$noop_probe"
  export MULTICLI_OVERRIDE_BINARY="$noop_probe"
  run multicli launch fixture/account-a

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  local profile_auth="$MULTICLI_HOME/fixture/account-a/auth/auth.json"
  local runtime_auth="$MULTICLI_HOME/fixture/account-a/.runtime/auth.json"
  [ "$(jq -r '.synthetic' "$profile_auth")" = "exec-login" ]
  [ -L "$runtime_auth" ]
  [ "$runtime_auth" -ef "$profile_auth" ]
}

@test "matrix: exec rejects detached or non-file-overlay adapters before spawning (+1 related)" {
  # Case 1: exec rejects detached or non-file-overlay adapters before spawning
  jq '.isolation.mode="detached"' "$MULTICLI_TOOLS_DIR/fixture/adapter.json" \
    > "$MULTICLI_TOOLS_DIR/fixture/updated.json"
  mv "$MULTICLI_TOOLS_DIR/fixture/updated.json" "$MULTICLI_TOOLS_DIR/fixture/adapter.json"

  run multicli exec fixture/account-a

  [ "$status" -eq 1 ]
  [ -z "$output" ] || [[ "$output" == *"requires a foreground"* ]]
  [ ! -f "$EXEC_CAPTURE" ]

  jq '.isolation.mode="foreground" | .account.mechanism="inseparable" | .account.reason="fixture"' \
    "$MULTICLI_TOOLS_DIR/fixture/adapter.json" > "$MULTICLI_TOOLS_DIR/fixture/updated.json"
  mv "$MULTICLI_TOOLS_DIR/fixture/updated.json" "$MULTICLI_TOOLS_DIR/fixture/adapter.json"

  run multicli exec fixture/account-a

  [ "$status" -eq 1 ]
  [[ "$output" == *"requires accountOverlay/fileOverlay"* ]]
  [ ! -f "$EXEC_CAPTURE" ]

  teardown
  setup

  # Case 2: exec preserves stdout-clean legacy whole-root compatibility while launch keeps its notice
  mkdir -p "$MULTICLI_HOME/fixture/legacy"
  local request='{"jsonrpc":"2.0","id":2}'

  printf '%s\n' "$request" | "$MULTICLI_BIN" exec fixture/legacy \
    >"$MULTICLI_SCRATCH/legacy-stdout" 2>"$MULTICLI_SCRATCH/legacy-stderr"

  [ "$(cat "$MULTICLI_SCRATCH/legacy-stdout")" = "$request" ]
  [ "$(cat "$MULTICLI_SCRATCH/legacy-stderr")" = "child-stderr" ]
  [ "$(jq -r '.runtime' "$EXEC_CAPTURE")" = "$MULTICLI_HOME/fixture/legacy" ]

  run bash -c "printf 'request\\n' | '$MULTICLI_BIN' launch fixture/legacy"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Launching Fixture CLI profile 'fixture/legacy'"* ]]
}
