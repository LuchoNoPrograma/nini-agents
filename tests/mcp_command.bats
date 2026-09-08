#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$MULTICLI_TOOLS_DIR/codex/adapter.json"
  export MULTICLI_OVERRIDE_BINARY="$MULTICLI_SCRATCH/codex-probe"
  export MCP_CAPTURE="$MULTICLI_SCRATCH/mcp-capture.json"
  cat > "$MULTICLI_OVERRIDE_BINARY" <<'PROBE'
#!/usr/bin/env python3
import json
import os
import pathlib
import sys

args = sys.argv[1:]
options = {}
command = []
index = 0
while index < len(args):
    if args[index] == '-c':
        key, value = args[index + 1].split('=', 1)
        options[key] = value.strip('"')
        index += 2
    else:
        command.append(args[index])
        index += 1
root = pathlib.Path(os.environ['CODEX_HOME'])
pathlib.Path(os.environ['MCP_CAPTURE']).write_text(json.dumps({
    'home': str(root), 'options': options, 'command': command,
    'inherited_sqlite': os.environ.get('CODEX_SQLITE_HOME'),
}))
if options.get('mcp_oauth_credentials_store') != 'file':
    sys.exit(91)
if options.get('cli_auth_credentials_store') != 'file':
    sys.exit(92)
credentials = root / '.credentials.json'
if command[:2] == ['mcp', 'login']:
    # Only synthetic credentials. Model a vendor write to the resolved store.
    state = json.loads(credentials.read_text()) if credentials.exists() else {}
    state[command[2]] = {'synthetic': True}
    credentials.write_text(json.dumps(state))
    print('login complete')
elif command[:2] == ['mcp', 'get'] and command[2] == 'missing':
    print('server not found', file=sys.stderr)
    sys.exit(23)
else:
    state = json.loads(credentials.read_text()) if credentials.exists() else {}
    if not state.get('figma', {}).get('synthetic'):
        sys.exit(93)
    print('authorized')
PROBE
  chmod +x "$MULTICLI_OVERRIDE_BINARY"
  multicli new codex/account-a --no-seed >/dev/null
}

teardown() {
  unset MULTICLI_OVERRIDE_BINARY MCP_CAPTURE
  teardown_scratch
}

@test "MCP login survives a fresh launch and is visible from another account overlay" {
  local shared="$MULTICLI_HOME/.shared/codex/mcp/.credentials.json"
  local primary="$MULTICLI_HOME/codex/account-a/auth/auth.json"
  printf '%s\n' '{"synthetic":"primary-account-a"}' > "$primary"

  run multicli mcp codex/account-a login figma --scopes 'scope-a,scope-b'
  [ "$status" -eq 0 ]
  [ "$output" = 'login complete' ]
  [ "$(jq -r '.figma.synthetic' "$shared")" = true ]
  [ "$(jq -r '.synthetic' "$primary")" = primary-account-a ]
  [ ! -e "$HOME/.codex/.credentials.json" ]
  [ "$MULTICLI_HOME/codex/account-a/.runtime/.credentials.json" -ef "$shared" ]
  run jq -e '.command == ["mcp", "login", "figma", "--scopes", "scope-a,scope-b"]' "$MCP_CAPTURE"
  [ "$status" -eq 0 ]

  run multicli launch codex/account-a
  [ "$status" -eq 0 ]
  [[ "$output" == *authorized* ]]

  multicli new codex/account-b --no-seed >/dev/null
  run multicli mcp codex/account-b -- list --json
  [ "$status" -eq 0 ]
  [ "$output" = authorized ]
  [ "$MULTICLI_HOME/codex/account-b/.runtime/.credentials.json" -ef "$shared" ]
  [ ! -s "$MULTICLI_HOME/codex/account-b/auth/auth.json" ]
  run jq -e '.command == ["mcp", "list", "--json"]' "$MCP_CAPTURE"
  [ "$status" -eq 0 ]
}

@test "MCP commands keep adapter credential policy despite inherited home and user overrides" {
  run env CODEX_HOME="$MULTICLI_SCRATCH/unrelated" CODEX_SQLITE_HOME="$MULTICLI_SCRATCH/unrelated-db" \
    "$MULTICLI_BIN" mcp codex/account-a login figma -c 'mcp_oauth_credentials_store="keyring"'
  [ "$status" -eq 0 ]
  run jq -e --arg runtime "$MULTICLI_HOME/codex/account-a/.runtime" --arg shared "$HOME/.codex" \
    '.home == $runtime and .inherited_sqlite == null
     and .options.mcp_oauth_credentials_store == "file"
     and .options.cli_auth_credentials_store == "file"
     and .options.sqlite_home == $shared' "$MCP_CAPTURE"
  [ "$status" -eq 0 ]
  [ ! -e "$MULTICLI_SCRATCH/unrelated" ]
}

@test "MCP failures preserve child stderr and exit code" {
  local result=0
  "$MULTICLI_BIN" mcp codex/account-a get missing \
    >"$MULTICLI_SCRATCH/stdout" 2>"$MULTICLI_SCRATCH/stderr" || result=$?
  [ "$result" -eq 23 ]
  [ ! -s "$MULTICLI_SCRATCH/stdout" ]
  [ "$(cat "$MULTICLI_SCRATCH/stderr")" = 'server not found' ]
}

@test "MCP rejects missing arguments and other tools before spawning" {
  run multicli mcp
  [ "$status" -eq 1 ]
  [[ "$output" == *Usage:* ]]
  run multicli mcp codex/account-a --
  [ "$status" -eq 1 ]
  [[ "$output" == *Usage:* ]]
  run multicli mcp cursor/account-a list
  [ "$status" -eq 1 ]
  [[ "$output" == *'requires a Codex profile'* ]]
  [ ! -f "$MCP_CAPTURE" ]
}

@test "MCP preserves the separate credential boundary of isolated profiles" {
  multicli new codex/private --isolated --no-seed >/dev/null
  run multicli mcp codex/private login figma
  [ "$status" -eq 0 ]
  run multicli launch codex/private
  [ "$status" -eq 0 ]
  [[ "$output" == *authorized* ]]
  [ ! -e "$MULTICLI_HOME/.shared/codex/mcp/.credentials.json" ]
  [ -f "$MULTICLI_HOME/codex/private/.credentials.json" ]
  run multicli mcp codex/account-a list
  [ "$status" -eq 93 ]
}
