#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  mkdir -p "$MULTICLI_HOME/codex/work/auth" "$MULTICLI_HOME/cursor/personal"
  printf '%s\n' '{"schemaVersion":2,"profileId":null,"adapterId":"codex","mode":"accountOverlay"}' \
    > "$MULTICLI_HOME/codex/work/.profile.json"
  printf '%s\n' '{"fixtureOnly":true}' > "$MULTICLI_HOME/codex/work/auth/auth.json"
  printf '%s\n' 'ordinary-state' > "$MULTICLI_HOME/cursor/personal/state.txt"
  mkdir -p "$MULTICLI_HOME/.templates/plain"
  printf '%s\n' 'template-state' > "$MULTICLI_HOME/.templates/plain/config.toml"
}

teardown() {
  teardown_scratch
}

assert_envelope() {
  local expected_command="$1"
  printf '%s' "$output" | jq -e --arg command "$expected_command" '
    .schemaVersion == 1 and .command == $command and
    (.ok | type == "boolean") and has("data") and has("error")
  ' >/dev/null
}

assert_no_private_data() {
  [[ "$output" != *"$MULTICLI_SCRATCH"* ]]
  [[ "$output" != *"profileId"* ]]
  [[ "$output" != *"fixtureOnly"* ]]
  [[ "$output" != *"auth.json"* ]]
}

@test "version JSON v1 is stable in prefix and suffix forms" {
  run multicli --json version
  [ "$status" -eq 0 ]
  assert_envelope version
  printf '%s' "$output" | jq -e '.ok and .error == null and .data == {product:"nini-agents",version:"1.0.0"}' >/dev/null

  run multicli version --json
  [ "$status" -eq 0 ]
  assert_envelope version
}

@test "matrix: list and status expose safe profile summaries only (+1 related)" {
  # Case 1: list and status expose safe profile summaries only
  run multicli list --json
  [ "$status" -eq 0 ]
  assert_envelope list
  printf '%s' "$output" | jq -e '
    .data.count == 2 and
    (.data.profiles | any(.tool == "codex" and .name == "work" and .schemaVersion == 2)) and
    (.data.profiles | any(.tool == "cursor" and .name == "personal" and .schemaVersion == 1)) and
    (.data.profiles | all((.sizeBytes | type) == "number"))
  ' >/dev/null
  assert_no_private_data

  run multicli --json status codex
  [ "$status" -eq 0 ]
  assert_envelope status
  printf '%s' "$output" | jq -e '.data.count == 1 and .data.profiles[0].tool == "codex"' >/dev/null
  assert_no_private_data

  teardown
  setup

  # Case 2: tools JSON reports public adapter capabilities without binary paths
  local expected_platform=linux
  [ "$(uname -s)" = Darwin ] && expected_platform=macos
  run multicli tools --json
  [ "$status" -eq 0 ]
  assert_envelope tools
  printf '%s' "$output" | jq -e --arg platform "$expected_platform" '
    .data.platform == $platform and .data.count == 2 and
    (.data.tools | all(has("id") and has("kind") and has("strategy") and has("supportLevel") and has("installed"))) and
    (.data.tools | all((.installed | type) == "boolean"))
  ' >/dev/null
  assert_no_private_data
}

@test "matrix: doctor JSON contains verdicts but no storage or binary paths (+1 related)" {
  # Case 1: doctor JSON contains verdicts but no storage or binary paths
  local expected_platform=linux
  [ "$(uname -s)" = Darwin ] && expected_platform=macos
  run multicli doctor --json
  [ "$status" -eq 0 ]
  assert_envelope doctor
  printf '%s' "$output" | jq -e --arg platform "$expected_platform" '
    .ok and .data.platform == $platform and
    (.data.storage.exists | type) == "boolean" and
    (.data.storage.writable | type) == "boolean" and
    (.data.tools | type) == "array"
  ' >/dev/null
  assert_no_private_data

  teardown
  setup

  # Case 2: stats and template list JSON use numeric sizes
  run multicli stats --json
  [ "$status" -eq 0 ]
  assert_envelope stats
  printf '%s' "$output" | jq -e '
    .data.count == 2 and (.data.totalBytes | type) == "number" and
    (.data.profiles | all((.sizeBytes | type) == "number"))
  ' >/dev/null
  assert_no_private_data

  run multicli template list --json
  [ "$status" -eq 0 ]
  assert_envelope template-list
  printf '%s' "$output" | jq -e '.data.count == 1 and .data.templates[0].name == "plain"' >/dev/null
  assert_no_private_data
}

@test "matrix: unsupported JSON commands fail with a deterministic safe envelope (+3 related)" {
  # Case 1: unsupported JSON commands fail with a deterministic safe envelope
  run multicli clone codex/work codex/copy --json
  [ "$status" -eq 2 ]
  assert_envelope clone
  printf '%s' "$output" | jq -e '
    (.ok | not) and .data == null and .error.code == "json_unsupported" and
    .error.message == "JSON output is not available for this command."
  ' >/dev/null
  [ -d "$MULTICLI_HOME/codex/work" ]
  assert_no_private_data

  teardown
  setup

  # Case 2: transactional movement result serializer exposes only state codes
  run bash -c '
    source "$1/lib/cli-json.sh"
    MOVE_RESULT_CODE=destination_runtime_failed_rolled_back
    MOVE_RESULT_STATE=source_restored
    MOVE_RESULT_FORMAT=v2
    cli_json_move_result false
  ' _ "$MULTICLI_REPO_ROOT"
  [ "$status" -eq 0 ]
  assert_envelope move
  printf '%s' "$output" | jq -e '
    (.ok | not) and .data == null and
    .error.code == "destination_runtime_failed_rolled_back" and
    .error.details == {state:"source_restored",format:"v2"}
  ' >/dev/null
  assert_no_private_data

  teardown
  setup

  # Case 3: successful movement result serializer uses the same envelope
  run bash -c '
    source "$1/lib/cli-json.sh"
    MOVE_RESULT_CODE=ok
    MOVE_RESULT_STATE=destination_active
    MOVE_RESULT_FORMAT=legacy
    cli_json_move_result true
  ' _ "$MULTICLI_REPO_ROOT"
  [ "$status" -eq 0 ]
  assert_envelope move
  printf '%s' "$output" | jq -e '.ok and .data == {code:"ok",state:"destination_active",format:"legacy"}' >/dev/null

  teardown
  setup

  # Case 4: every unsupported JSON argument is rejected deterministically
  local invocation
  for invocation in \
    'version extra --json' \
    'list codex extra --json' \
    'tools extra --json' \
    'doctor --deep --json' \
    'stats extra --json' \
    'template save --json'; do
    run bash -c 'launcher=$1; shift; "$launcher" "$@"' _ "$MULTICLI_BIN" $invocation
    [ "$status" -eq 2 ]
    printf '%s' "$output" | jq -e '(.ok | not) and .data == null and (.error.code | type == "string")' >/dev/null
  done
  [ -d "$MULTICLI_HOME/codex/work" ]
}

@test "doctor dependency and health failures remain valid JSON" {
  local sparse_path="$MULTICLI_SCRATCH/sparse-bin"
  mkdir -p "$sparse_path"
  ln -s "$(command -v dirname)" "$sparse_path/dirname"
  ln -s "$(command -v cat)" "$sparse_path/cat"
  run env PATH="$sparse_path" /bin/bash "$MULTICLI_BIN" --json version
  [ "$status" -eq 6 ]
  assert_envelope unknown
  printf '%s' "$output" | "$MULTICLI_VENDOR/jq" -e '.error.code == "dependency_missing"' >/dev/null 2>&1 || \
    printf '%s' "$output" | jq -e '.error.code == "dependency_missing"' >/dev/null

  run env MULTICLI_HOME=/proc/nini-agents-json-test "$MULTICLI_BIN" doctor --json
  [ "$status" -eq 6 ]
  assert_envelope doctor
  printf '%s' "$output" | jq -e '.error.code == "health_check_failed" and .error.details.result.storage.writable == false' >/dev/null
}

@test "JSON discovery skips symlinked profile and template roots" {
  local outside="$MULTICLI_SCRATCH/outside-private"
  mkdir -p "$outside"
  printf '%s\n' 'outside-private-value' > "$outside/state.txt"
  if ! make_symlink "$outside" "$MULTICLI_HOME/codex/linked" || [ ! -L "$MULTICLI_HOME/codex/linked" ]; then
    skip "host cannot create real symlinks"
  fi
  make_symlink "$outside" "$MULTICLI_HOME/.templates/linked"

  run multicli list --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.data.profiles | all(.name != "linked")' >/dev/null
  [[ "$output" != *"outside-private-value"* ]]

  run multicli template list --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.data.templates | all(.name != "linked")' >/dev/null
}
