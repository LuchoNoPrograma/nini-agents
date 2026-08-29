#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  TOOLS_ROOT="$MULTICLI_SCRATCH/schema-tools"
  mkdir -p "$TOOLS_ROOT"
  VALIDATOR="$MULTICLI_REPO_ROOT/scripts/validate-adapters.sh"
}

teardown() {
  teardown_scratch
}

write_adapter() {
  local dir_name="$1" json="$2"
  mkdir -p "$TOOLS_ROOT/$dir_name"
  printf '%s\n' "$json" > "$TOOLS_ROOT/$dir_name/adapter.json"
}

valid_v2_adapter() {
  cat <<'JSON'
{
  "schemaVersion": 2,
  "id": "test-cli",
  "displayName": "Test CLI",
  "kind": "cli",
  "binary": {
    "windows": ["test-cli.exe"],
    "macos": ["test-cli"],
    "linux": ["test-cli"]
  },
  "isolation": {
    "strategy": "accountOverlay",
    "mode": "foreground",
    "env": { "TEST_HOME": "{runtimeRoot}" },
    "clearEnv": ["GLOBAL_TEST_TOKEN"]
  },
  "account": {
    "mechanism": "fileOverlay",
    "credentialFiles": ["auth.json"],
    "credentialPrecedence": ["auth.json"],
    "logoutScope": "profile"
  },
  "normalState": {
    "root": {
      "windows": "%USERPROFILE%\\.test-cli",
      "macos": "$HOME/.test-cli",
      "linux": "$HOME/.test-cli"
    },
    "sharedPaths": ["config.toml", "agents", "skills"],
    "sessionPaths": ["sessions", "history.jsonl"],
    "unsafePaths": ["cache/account.sqlite"]
  },
  "concurrency": {
    "level": "multiWriter",
    "singletonScope": "none"
  },
  "support": {
    "windows": { "level": "supported", "reason": "File overlay with profile-local auth.json." },
    "macos": { "level": "supported" },
    "linux": { "level": "supported" }
  },
  "install": "https://example.test/install",
  "versionCommand": ["--version"]
}
JSON
}

@test "matrix: validator accepts existing schema-v1 adapters for legacy compatibility (+1 related)" {
  # Case 1: validator accepts existing schema-v1 adapters for legacy compatibility
  write_adapter legacy '{"id":"legacy","displayName":"Legacy","kind":"cli","binary":{"windows":["legacy.exe"],"macos":["legacy"],"linux":["legacy"]},"isolation":{"strategy":"env","env":{"LEGACY_HOME":"{profileDir}"}},"share":{"systemHome":"$HOME/.legacy","linkable":["config"],"neverLink":["auth.json"]},"session":{"portable":true,"paths":["sessions"],"credentials":["auth.json"]},"status":"stable"}'

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Validated 1 adapter(s)"* ]]

  teardown
  setup

  # Case 2: validator accepts a complete schema-v2 account overlay
  write_adapter test-cli "$(valid_v2_adapter)"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Validated 1 adapter(s)"* ]]
}

@test "matrix: validator accepts shared credential state below the adapter-owned store (+1 related)" {
  # Case 1: validator accepts shared credential state below the adapter-owned store
  local adapter
  adapter="$(valid_v2_adapter | jq '.sharedCredentialState={
    root:".shared/test-cli/mcp",
    entries:[
      {path:".credentials.json",kind:"jsonObjectFile"},
      {path:"mcp-oauth-locks",kind:"directory"}
    ],
    legacyMigration:"preserveInactive"
  }')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 0 ]

  teardown
  setup

  # Case 2: validator accepts reconstructible runtime paths and dot-suffix credential backups
  local adapter
  adapter="$(valid_v2_adapter | jq '
    .normalState.runtimePaths=["runtime-cache", "models_cache.json"] |
    .sharedCredentialState={
      root:".shared/test-cli/mcp",
      entries:[
        {path:".credentials.json",kind:"jsonObjectFile"},
        {path:"mcp-oauth-locks",kind:"directory"}
      ],
      legacyMigration:"preserveInactive",
      legacyBackupPattern:"dotSuffix"
    }')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3
  [ "$status" -eq 0 ]
}

@test "matrix: validator rejects runtime paths overlapping state or credential backup namespaces (+3 related)" {
  # Case 1: validator rejects runtime paths overlapping state or credential backup namespaces
  local adapter
  adapter="$(valid_v2_adapter | jq '
    .normalState.runtimePaths=["sessions/cache", ".credentials.json.before-test"] |
    .sharedCredentialState={
      root:".shared/test-cli/mcp",
      entries:[{path:".credentials.json",kind:"jsonObjectFile"}],
      legacyMigration:"preserveInactive",
      legacyBackupPattern:"dotSuffix"
    }')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"session path 'sessions' overlaps runtime path 'sessions/cache'"* ]]
  [[ "$output" == *"shared credential path '.credentials.json' overlaps runtime path '.credentials.json.before-test'"* ]]

  teardown
  setup

  # Case 2: validator rejects shared credential roots outside the adapter-owned store
  local adapter
  adapter="$(valid_v2_adapter | jq '.sharedCredentialState={root:"test-cli/mcp",entries:[{path:"oauth.json",kind:"jsonObjectFile"}],legacyMigration:"preserveInactive"}')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"sharedCredentialState.root must be below '.shared/test-cli/'"* ]]

  teardown
  setup

  # Case 3: validator rejects invalid or overlapping shared credential entries
  local adapter
  adapter="$(valid_v2_adapter | jq '.sharedCredentialState={
    root:".shared/test-cli/mcp",
    entries:[
      {path:"oauth",kind:"secretFile"},
      {path:"oauth/locks",kind:"directory"}
    ],
    legacyMigration:"copy"
  }')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"shared credential kind 'secretFile' is not supported"* ]]
  [[ "$output" == *"shared credential path 'oauth' overlaps shared credential path 'oauth/locks'"* ]]
  [[ "$output" == *"sharedCredentialState.legacyMigration must be 'preserveInactive'"* ]]

  teardown
  setup

  # Case 4: validator rejects shared credential entries overlapping profile or normal state
  local adapter
  adapter="$(valid_v2_adapter | jq '.sharedCredentialState={
    root:".shared/test-cli/mcp",
    entries:[
      {path:"auth.json",kind:"jsonObjectFile"},
      {path:"sessions/oauth.json",kind:"jsonObjectFile"}
    ],
    legacyMigration:"preserveInactive"
  }')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"shared credential path 'auth.json' overlaps credential path 'auth.json'"* ]]
  [[ "$output" == *"shared credential path 'sessions/oauth.json' overlaps session path 'sessions'"* ]]
}

@test "object-field validation is deterministic under pipefail" {
  local manifest="$MULTICLI_SCRATCH/object-fields.json"
  printf '%s\n' '{"known":{}}' > "$manifest"

  run bash -c '
    set -o pipefail
    source "$1/lib/adapter-validation.sh"
    allowed="$(awk '\''BEGIN { print "known"; for (i = 0; i < 20000; i++) print "padding" i }'\'')"
    ADAPTER_VALIDATION_ERRORS=()
    validate_adapter_object_fields "$2" "." "$allowed" ""
    [ "${#ADAPTER_VALIDATION_ERRORS[@]}" -eq 0 ]
  ' _ "$MULTICLI_REPO_ROOT" "$manifest"

  [ "$status" -eq 0 ]
}

@test "matrix: JSON schema accepts the runtime subdirectory used by Command Code (+2 related)" {
  # Case 1: JSON schema accepts the runtime subdirectory used by Command Code
  run jq -e '
    .properties.normalState.properties.runtimeSubdir["$ref"] == "#/$defs/relativePath"
  ' "$MULTICLI_REPO_ROOT/schema/adapter.schema.json"

  [ "$status" -eq 0 ]

  teardown
  setup

  # Case 2: JSON schema exposes direct normal-state paths
  run jq -e '
    .properties.normalState.properties.directPaths.items["$ref"] == "#/$defs/relativePath" and
    .properties.normalState.properties.migrationPreservePaths.items["$ref"] == "#/$defs/relativePath" and
    .properties.normalState.properties.migrationActivatePaths.items["$ref"] == "#/$defs/relativePath"
  ' "$MULTICLI_REPO_ROOT/schema/adapter.schema.json"

  [ "$status" -eq 0 ]

  teardown
  setup

  # Case 3: JSON schema exposes shared credential state only to schema-v2 adapters
  run jq -e '
    .properties.sharedCredentialState.properties.root["$ref"] == "#/$defs/relativePath" and
    .properties.sharedCredentialState.properties.entries.minItems == 1 and
    .properties.sharedCredentialState.properties.legacyMigration.const == "preserveInactive" and
    .properties.sharedCredentialState.properties.legacyBackupPattern.const == "dotSuffix" and
    .properties.normalState.properties.runtimePaths.items["$ref"] == "#/$defs/relativePath" and
    .allOf[0].else.properties.sharedCredentialState == false
  ' "$MULTICLI_REPO_ROOT/schema/adapter.schema.json"

  [ "$status" -eq 0 ]
}

@test "Codex adapter isolates main auth and shares MCP OAuth state explicitly" {
  run jq -e '
    (.binary.macos | index("$HOME/.local/bin/codex")) != null and
    (.binary.linux | index("$HOME/.local/bin/codex")) != null and
    (.normalState.sharedPaths | index("rules")) != null and
    (.normalState.sharedPaths | index("AGENTS.md")) != null and
    (.normalState.sharedPaths | index("AGENTS.override.md")) != null and
    (.normalState.sharedPaths | index("log")) != null and
    (.normalState.filePaths | index("AGENTS.md")) != null and
    (.normalState.filePaths | index("AGENTS.override.md")) != null and
    .isolation.args == [
      "-c", "cli_auth_credentials_store=\"file\"",
      "-c", "mcp_oauth_credentials_store=\"file\"",
      "-c", "sqlite_home=\"{sharedStateRoot}\""
    ] and
    (.normalState.sessionPaths | index("state_5.sqlite")) != null and
    .normalState.runtimePaths == [
      ".sandbox_migration",
      "cache",
      "models_cache.json",
      "version.json"
    ] and
    (.normalState.sessionPaths | index("shell_snapshots")) != null and
    (.normalState.sessionPaths | index("thread-writer-locks")) != null and
    (.normalState.directPaths | index("state_5.sqlite")) != null and
    (.normalState.migrationPreservePaths | sort) == ((.normalState.directPaths + ["thread-writer-locks"]) | sort) and
    .normalState.migrationActivatePaths == [
      "config.toml", "hooks.json", "AGENTS.md", "AGENTS.override.md", "skills", "agents", "prompts", "mcp-configs", "plugins", "rules"
    ] and
    (.normalState.filePaths | index("state_5.sqlite")) != null and
    (.normalState.sharedPaths | index("installation_id")) != null and
    .sharedCredentialState == {
      root: ".shared/codex/mcp",
      entries: [
        {path: ".credentials.json", kind: "jsonObjectFile"},
        {path: "mcp-oauth-locks", kind: "directory"}
      ],
      legacyMigration: "preserveInactive",
      legacyBackupPattern: "dotSuffix"
    } and
    (.normalState.unsafePaths | index(".credentials.json")) == null and
    (.normalState.unsafePaths | index("mcp-oauth-locks")) == null and
    (.account.credentialFiles | index("rules")) == null and
    (.normalState.sessionPaths | index("rules")) == null
  ' "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json"

  [ "$status" -eq 0 ]
}

@test "Command Code adapter uses its documented user state directory as the shared root" {
  run jq -e '
    .normalState.runtimeSubdir == ".commandcode" and
    .normalState.root.windows == "%USERPROFILE%\\.commandcode" and
    .normalState.root.macos == "$HOME/.commandcode" and
    .normalState.root.linux == "$HOME/.commandcode"
  ' "$MULTICLI_REPO_ROOT/ai-tools/commandcode/adapter.json"

  [ "$status" -eq 0 ]
}

@test "Windows Bash resolves only AppX OS-user adapters" {
  local stub_bin="$MULTICLI_SCRATCH/bin"
  mkdir -p "$stub_bin" "$TOOLS_ROOT/codex-gui"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex-gui/adapter.json" "$TOOLS_ROOT/codex-gui/adapter.json"
  printf '#!/usr/bin/env bash\nprintf "appx:FixtureFamily!App\\n"\n' > "$stub_bin/powershell.exe"
  chmod +x "$stub_bin/powershell.exe"

  run env PATH="$stub_bin:$PATH" MULTICLI_PLATFORM=windows MULTICLI_TOOLS_DIR="$TOOLS_ROOT" \
    bash -c 'multicli_bin="$1"; set -- help; source "$multicli_bin" >/dev/null; find_adapter_binary codex-gui' _ "$MULTICLI_BIN"

  [ "$status" -eq 0 ]
  [ "$output" = "appx:FixtureFamily!App" ]

  jq '.account.mechanism = "fileOverlay"' "$TOOLS_ROOT/codex-gui/adapter.json" \
    > "$TOOLS_ROOT/codex-gui/adapter.tmp"
  mv "$TOOLS_ROOT/codex-gui/adapter.tmp" "$TOOLS_ROOT/codex-gui/adapter.json"

  run env PATH="$stub_bin:$PATH" MULTICLI_PLATFORM=windows MULTICLI_TOOLS_DIR="$TOOLS_ROOT" \
    bash -c 'multicli_bin="$1"; set -- help; source "$multicli_bin" >/dev/null; find_adapter_binary codex-gui' _ "$MULTICLI_BIN"

  [ "$status" -ne 0 ]

  jq '.account.mechanism = "osUserCredentialStore" | .binary.windows = ["uri:codex"]' \
    "$TOOLS_ROOT/codex-gui/adapter.json" > "$TOOLS_ROOT/codex-gui/adapter.tmp"
  mv "$TOOLS_ROOT/codex-gui/adapter.tmp" "$TOOLS_ROOT/codex-gui/adapter.json"

  run env PATH="$stub_bin:$PATH" MULTICLI_PLATFORM=windows MULTICLI_TOOLS_DIR="$TOOLS_ROOT" \
    bash -c 'multicli_bin="$1"; set -- help; source "$multicli_bin" >/dev/null; find_adapter_binary codex-gui' _ "$MULTICLI_BIN"

  [ "$status" -ne 0 ]
}

@test "matrix: validator rejects malformed JSON with the adapter path (+3 related)" {
  # Case 1: validator rejects malformed JSON with the adapter path
  write_adapter broken '{"id":"broken"'

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"broken/adapter.json: invalid JSON"* ]]

  teardown
  setup

  # Case 2: validator rejects a directory and adapter id mismatch
  write_adapter wrong-dir "$(valid_v2_adapter)"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"directory 'wrong-dir' does not match id 'test-cli'"* ]]

  teardown
  setup

  # Case 3: validator rejects unsafe adapter ids
  write_adapter 'bad id' '{"schemaVersion":2,"id":"bad id","displayName":"Bad","kind":"cli","binary":{"windows":["bad"],"macos":["bad"],"linux":["bad"]},"isolation":{"strategy":"accountOverlay","mode":"foreground"},"account":{"mechanism":"inseparable","reason":"combined state"},"normalState":{"root":{"windows":"x","macos":"x","linux":"x"},"sharedPaths":[],"sessionPaths":[],"unsafePaths":[]},"concurrency":{"level":"unsupported","singletonScope":"user"},"support":{"windows":{"level":"unsupported","reason":"combined state"},"macos":{"level":"unsupported","reason":"combined state"},"linux":{"level":"unsupported","reason":"combined state"}}}'

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"id must match"* ]]

  teardown
  setup

  # Case 4: validator rejects schema-v2 darwin binary keys
  local adapter
  adapter="$(valid_v2_adapter | jq 'del(.binary.macos) | .binary.darwin=["test-cli"]')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"binary uses unsupported platform key 'darwin'; use 'macos'"* ]]
}

@test "matrix: validator rejects credential paths overlapping normal state (+3 related)" {
  # Case 1: validator rejects credential paths overlapping normal state
  local adapter
  adapter="$(valid_v2_adapter | jq '.account.credentialFiles=["sessions/auth.json"] | .normalState.sessionPaths=["sessions"]')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"credential path 'sessions/auth.json' overlaps session path 'sessions'"* ]]

  teardown
  setup

  # Case 2: validator rejects shared paths overlapping session paths
  local adapter
  adapter="$(valid_v2_adapter | jq '.normalState.sharedPaths=["state"] | .normalState.sessionPaths=["state/sessions"]')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"shared path 'state' overlaps session path 'state/sessions'"* ]]

  teardown
  setup

  # Case 3: validator rejects file paths that are not declared as shared or session state
  local adapter
  adapter="$(valid_v2_adapter | jq '.normalState.filePaths=["undeclared.json"]')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"file path 'undeclared.json' must also be declared in sharedPaths or sessionPaths"* ]]

  teardown
  setup

  # Case 4: validator rejects direct paths that are not declared as shared or session state
  local adapter
  adapter="$(valid_v2_adapter | jq '.normalState.directPaths=["undeclared.sqlite"]')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"direct path 'undeclared.sqlite' must also be declared in sharedPaths or sessionPaths"* ]]
}

@test "matrix: validator accepts migration preserve paths only as declared shared or session state (+1 related)" {
  # Case 1: validator accepts migration preserve paths only as declared shared or session state
  local adapter
  adapter="$(valid_v2_adapter | jq '.normalState.migrationPreservePaths=["history.jsonl", "sessions"]')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3

  teardown
  setup

  # Case 2: validator rejects unsafe or undeclared migration preserve paths
  local adapter
  adapter="$(valid_v2_adapter | jq '.normalState.migrationPreservePaths=["../outside", "undeclared.sqlite"]')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"migration preserve path '../outside' must be a safe relative path"* ]]
  [[ "$output" == *"migration preserve path 'undeclared.sqlite' must also be declared in sharedPaths or sessionPaths"* ]]
}

@test "matrix: validator accepts migration activate paths only as declared shared or session state (+1 related)" {
  # Case 1: validator accepts migration activate paths only as declared shared or session state
  local adapter
  adapter="$(valid_v2_adapter | jq '.normalState.migrationActivatePaths=["config.toml", "agents", "sessions"]')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 0 ] || printf '%s\n' "$output" >&3

  teardown
  setup

  # Case 2: validator rejects unsafe or undeclared migration activate paths
  local adapter
  adapter="$(valid_v2_adapter | jq '.normalState.migrationActivatePaths=["../outside", "undeclared.sqlite"]')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"migration activate path '../outside' must be a safe relative path"* ]]
  [[ "$output" == *"migration activate path 'undeclared.sqlite' must also be declared in sharedPaths or sessionPaths"* ]]
}

@test "matrix: validator rejects parent traversal in declared state paths (+1 related)" {
  # Case 1: validator rejects parent traversal in declared state paths
  local adapter
  adapter="$(valid_v2_adapter | jq '.normalState.sharedPaths=["../outside"]')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"shared path '../outside' must be a safe relative path"* ]]

  teardown
  setup

  # Case 2: validator rejects unknown placeholders
  local adapter
  adapter="$(valid_v2_adapter | jq '.isolation.env.TEST_HOME="{mysteryRoot}"')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown placeholder '{mysteryRoot}'"* ]]
}

@test "matrix: validator requires a reason for unsupported support (+1 related)" {
  # Case 1: validator requires a reason for unsupported support
  local adapter
  adapter="$(valid_v2_adapter | jq '.support.windows={"level":"unsupported"}')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"support.windows.reason is required for level 'unsupported'"* ]]

  teardown
  setup

  # Case 2: validator accepts supported support without a reason
  local adapter
  adapter="$(valid_v2_adapter | jq 'del(.support.windows.reason)')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Validated 1 adapter(s)"* ]]
}

@test "matrix: validator rejects the retired experimental level with a clear message (+1 related)" {
  # Case 1: validator rejects the retired experimental level with a clear message
  local adapter
  adapter="$(valid_v2_adapter | jq '.support.windows={"level":"experimental","reason":"legacy"}')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"support.windows.level 'experimental' was retired; use 'supported' or 'unsupported'"* ]]

  teardown
  setup

  # Case 2: validator rejects retired evidenceId metadata
  local adapter
  adapter="$(valid_v2_adapter | jq '.evidenceId="EV-1"')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported top-level field 'evidenceId'"* ]]
}

@test "matrix: validator rejects unknown nested fields (+2 related)" {
  # Case 1: validator rejects unknown nested fields
  local adapter
  adapter="$(valid_v2_adapter | jq '.support.windows.note="not part of the contract"')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported field 'support.windows.note'"* ]]

  teardown
  setup

  # Case 2: validator rejects legacy fields in schema-v2
  local adapter
  adapter="$(valid_v2_adapter | jq '.status="stable"')"
  write_adapter test-cli "$adapter"

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported top-level field 'status'"* ]]

  teardown
  setup

  # Case 3: validator rejects unknown schema-v1 nested fields
  write_adapter legacy '{"id":"legacy","displayName":"Legacy","kind":"cli","binary":{"windows":["legacy"],"macos":["legacy"],"linux":["legacy"]},"isolation":{"strategy":"env","env":{"HOME":"{profileDir}"}},"share":{"systemHome":"$HOME/.legacy","linkable":["config"],"neverLink":["auth.json"],"note":"extra"},"status":"stable"}'

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported field 'share.note'"* ]]
}

@test "validator rejects v1 linkable and neverLink overlap" {
  write_adapter legacy '{"id":"legacy","displayName":"Legacy","kind":"cli","binary":{"windows":["legacy"],"macos":["legacy"],"linux":["legacy"]},"isolation":{"strategy":"env","env":{"HOME":"{profileDir}"}},"share":{"systemHome":"$HOME/.legacy","linkable":["auth.json"],"neverLink":["auth.json"]},"status":"stable"}'

  run bash "$VALIDATOR" "$TOOLS_ROOT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"share.linkable path 'auth.json' overlaps share.neverLink path 'auth.json'"* ]]
}

@test "platform normalization matches schema binary keys" {
  run bash -c "set -- help; source '$MULTICLI_BIN' >/dev/null 2>&1; MULTICLI_PLATFORM=darwin platform"
  [ "$status" -eq 0 ]
  [ "$output" = "macos" ]

  run bash -c "set -- help; source '$MULTICLI_BIN' >/dev/null 2>&1; MULTICLI_PLATFORM=windows platform"
  [ "$status" -eq 0 ]
  [ "$output" = "windows" ]
}
