#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  export USERPROFILE="$HOME"
  export APPDATA="$HOME/AppData/Roaming"
  export LOCALAPPDATA="$HOME/AppData/Local"
  mkdir -p "$MULTICLI_TOOLS_DIR/codex"
  cat > "$MULTICLI_TOOLS_DIR/codex/adapter.json" <<'JSON'
{
  "schemaVersion": 2,
  "id": "codex",
  "displayName": "OpenAI Codex CLI",
  "kind": "cli",
  "binary": {"windows":["codex"],"macos":["codex"],"linux":["codex"]},
  "isolation": {"strategy":"accountOverlay","mode":"foreground","env":{"CODEX_HOME":"{runtimeRoot}"},"clearEnv":[]},
  "account": {"mechanism":"fileOverlay","credentialFiles":["auth.json"],"credentialPrecedence":["auth.json"],"logoutScope":"profile"},
  "normalState": {"root":{"windows":"%USERPROFILE%\\.codex","macos":"$HOME/.codex","linux":"$HOME/.codex"},"sharedPaths":["config.toml"],"sessionPaths":[],"filePaths":["config.toml"],"unsafePaths":[]},
  "concurrency": {"level":"multiWriter","singletonScope":"none"},
  "support": {"windows":{"level":"supported"},"macos":{"level":"supported"},"linux":{"level":"supported"}}
}
JSON
  export MULTICLI_OVERRIDE_BINARY="$MULTICLI_SCRATCH/fake-codex"
  cat > "$MULTICLI_OVERRIDE_BINARY" <<'FAKE_CODEX'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = "--strict-config" ]
[ "${2:-}" = "--version" ]
[ -f "${CODEX_HOME:?}/config.toml" ]
grep -q '^default_permissions = ":' "$CODEX_HOME/config.toml"
grep -q '^approval_policy = "' "$CODEX_HOME/config.toml"
! grep -q '^sandbox_mode[[:space:]]*=' "$CODEX_HOME/config.toml"
! grep -q '^\[sandbox_workspace_write\]' "$CODEX_HOME/config.toml"
FAKE_CODEX
  chmod +x "$MULTICLI_OVERRIDE_BINARY"
}

teardown() {
  unset MULTICLI_OVERRIDE_BINARY
  teardown_scratch
}

@test "permissions set full-access persists one shared Codex policy atomically" {
  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/config.toml" <<'TOML'
# keep this comment
model = "gpt-5"
sandbox_mode = "workspace-write"
approval_policy = "on-request"

[sandbox_workspace_write]
network_access = true

[features]
network_proxy = true
TOML

  run multicli permissions set full-access

  [ "$status" -eq 0 ]
  [[ "$output" == *"full-access"* ]]
  grep -qxF 'default_permissions = ":danger-full-access"' "$HOME/.codex/config.toml"
  grep -qxF 'approval_policy = "never"' "$HOME/.codex/config.toml"
  grep -qxF '# keep this comment' "$HOME/.codex/config.toml"
  grep -qxF 'model = "gpt-5"' "$HOME/.codex/config.toml"
  grep -qxF '[features]' "$HOME/.codex/config.toml"
  grep -qxF 'network_proxy = true' "$HOME/.codex/config.toml"
  ! grep -q '^sandbox_mode[[:space:]]*=' "$HOME/.codex/config.toml"
  ! grep -q '^\[sandbox_workspace_write\]' "$HOME/.codex/config.toml"
  [ "$(stat -c '%a' "$HOME/.codex/config.toml" 2>/dev/null || stat -f '%Lp' "$HOME/.codex/config.toml")" = 600 ]
}

@test "permissions presets persist their sandbox and approval pair" {
  local preset expected_profile expected_approval
  for preset in read-only workspace full-access; do
    case "$preset" in
      read-only) expected_profile=':read-only'; expected_approval='on-request' ;;
      workspace) expected_profile=':workspace'; expected_approval='on-request' ;;
      full-access) expected_profile=':danger-full-access'; expected_approval='never' ;;
    esac
    run multicli permissions set "$preset"
    [ "$status" -eq 0 ]
    grep -qxF "default_permissions = \"$expected_profile\"" "$HOME/.codex/config.toml"
    grep -qxF "approval_policy = \"$expected_approval\"" "$HOME/.codex/config.toml"
  done
}

@test "permissions show reports the shared preset without changing config" {
  run multicli permissions set workspace
  [ "$status" -eq 0 ]
  local before
  before="$(cksum "$HOME/.codex/config.toml")"

  run multicli permissions show

  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: workspace"* ]]
  [[ "$output" == *"approval: on-request"* ]]
  [[ "$output" == *"shared Codex profiles"* ]]
  [ "$(cksum "$HOME/.codex/config.toml")" = "$before" ]
}

@test "permissions refuses duplicate top-level keys without changing config" {
  mkdir -p "$HOME/.codex"
  printf '%s\n' 'approval_policy = "never"' 'approval_policy = "on-request"' > "$HOME/.codex/config.toml"
  local before
  before="$(cksum "$HOME/.codex/config.toml")"

  run multicli permissions set workspace

  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate top-level 'approval_policy'"* ]]
  [ "$(cksum "$HOME/.codex/config.toml")" = "$before" ]
}

@test "permissions refuses a linked config file" {
  mkdir -p "$HOME/.codex"
  printf 'model = "outside"\n' > "$MULTICLI_SCRATCH/outside.toml"
  ln -s "$MULTICLI_SCRATCH/outside.toml" "$HOME/.codex/config.toml"

  run multicli permissions set full-access

  [ "$status" -ne 0 ]
  [[ "$output" == *"config.toml is a link"* ]]
  [ "$(cat "$MULTICLI_SCRATCH/outside.toml")" = 'model = "outside"' ]
}
