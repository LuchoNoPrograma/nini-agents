#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" \
    "$MULTICLI_TOOLS_DIR/codex/adapter.json"
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
  [[ "$output" != *"auth.json"* ]]
}

@test "new JSON creates one schema-v2 profile and returns its public summary" {
  run multicli new codex/work --no-seed --json

  [ "$status" -eq 0 ]
  assert_envelope new
  printf '%s' "$output" | jq -e '
    .ok and .error == null and
    .data == {
      state:"applied",
      profile:{tool:"codex",name:"work",type:"full",schemaVersion:2}
    }
  ' >/dev/null
  [ -f "$MULTICLI_HOME/codex/work/.profile.json" ]
  assert_no_private_data
}

@test "new JSON accepts prefix form and preserves isolated profile type" {
  run multicli --json new codex/private --isolated --cli --no-seed

  [ "$status" -eq 0 ]
  assert_envelope new
  printf '%s' "$output" | jq -e '
    .ok and .data.state == "applied" and
    .data.profile == {tool:"codex",name:"private",type:"isolated",schemaVersion:2}
  ' >/dev/null
  [ -f "$MULTICLI_HOME/codex/private/.isolated" ]
  [ -f "$MULTICLI_HOME/codex/private/.cli" ]
  assert_no_private_data
}

@test "new JSON rejects invalid addresses and occupied destinations before writing" {
  run multicli new ../outside --no-seed --json
  [ "$status" -eq 2 ]
  assert_envelope new
  printf '%s' "$output" | jq -e '
    (.ok | not) and .data == null and
    .error.code == "invalid_identifier" and
    .error.details.state == "not_applied"
  ' >/dev/null
  [ ! -e "$MULTICLI_SCRATCH/outside" ]

  run multicli new codex/work --no-seed --json
  [ "$status" -eq 0 ]
  run multicli new codex/work --no-seed --json
  [ "$status" -eq 2 ]
  assert_envelope new
  printf '%s' "$output" | jq -e '
    .error.code == "profile_exists" and
    .error.details.state == "not_applied"
  ' >/dev/null
  assert_no_private_data
}

@test "new JSON reports a partial application when alias creation fails" {
  printf '%s\n' blocked > "$MULTICLI_HOME/bin"

  run multicli new codex/work --no-seed --json

  [ "$status" -eq 6 ]
  assert_envelope new
  printf '%s' "$output" | jq -e '
    (.ok | not) and .data == null and
    .error.code == "operation_failed" and
    .error.details.state == "partially_applied"
  ' >/dev/null
  [ -d "$MULTICLI_HOME/codex/work" ]
  assert_no_private_data
}

@test "rename JSON preserves profile identity and returns both public addresses" {
  run multicli new codex/old --no-seed --json
  [ "$status" -eq 0 ]
  profile_id="$(jq -r '.profileId' "$MULTICLI_HOME/codex/old/.profile.json")"

  run multicli rename codex/old codex/new --json

  [ "$status" -eq 0 ]
  assert_envelope rename
  printf '%s' "$output" | jq -e '
    .ok and .error == null and .data.state == "applied" and
    .data.from == {tool:"codex",name:"old"} and
    .data.profile == {tool:"codex",name:"new",type:"full",schemaVersion:2}
  ' >/dev/null
  [ ! -e "$MULTICLI_HOME/codex/old" ]
  [ "$(jq -r '.profileId' "$MULTICLI_HOME/codex/new/.profile.json")" = "$profile_id" ]
  assert_no_private_data
}

@test "human rename completes for a CLI profile without a desktop shortcut" {
  run multicli new codex/old --no-seed
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/share/applications/multicli-codex-old.desktop" ]

  run multicli rename codex/old codex/new

  [ "$status" -eq 0 ]
  [[ "$output" == *"Renamed 'codex/old' to 'codex/new'"* ]]
  [ ! -e "$MULTICLI_HOME/codex/old" ]
  [ -d "$MULTICLI_HOME/codex/new" ]
  [ -x "$MULTICLI_HOME/bin/codex-new" ]
}

@test "rename JSON rejects missing, occupied, and cross-tool destinations" {
  run multicli rename codex/missing codex/new --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '
    .error.code == "profile_not_found" and .error.details.state == "not_applied"
  ' >/dev/null

  run multicli new codex/old --no-seed --json
  [ "$status" -eq 0 ]
  run multicli new codex/new --no-seed --json
  [ "$status" -eq 0 ]
  run multicli rename codex/old codex/new --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '
    .error.code == "profile_exists" and .error.details.state == "not_applied"
  ' >/dev/null

  run multicli rename codex/old cursor/old --json
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '
    .error.code == "cross_tool_rename" and .error.details.state == "not_applied"
  ' >/dev/null
  [ -d "$MULTICLI_HOME/codex/old" ]
  assert_no_private_data
}

@test "rename JSON reports a partial application when alias recreation fails" {
  run multicli new codex/old --no-seed --json
  [ "$status" -eq 0 ]
  rm -r "$MULTICLI_HOME/bin"
  printf '%s\n' blocked > "$MULTICLI_HOME/bin"

  run multicli rename codex/old codex/new --json

  [ "$status" -eq 6 ]
  assert_envelope rename
  printf '%s' "$output" | jq -e '
    (.ok | not) and .data == null and
    .error.code == "operation_failed" and
    .error.details.state == "partially_applied"
  ' >/dev/null
  [ ! -d "$MULTICLI_HOME/codex/old" ]
  [ -d "$MULTICLI_HOME/codex/new" ]
  assert_no_private_data
}
