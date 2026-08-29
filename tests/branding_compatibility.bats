#!/usr/bin/env bats

load helpers/common

@test "matrix: nini-agents is the canonical Bash entrypoint (+1 related)" {
  # Case 1: nini-agents is the canonical Bash entrypoint
  run "$MULTICLI_REPO_ROOT/nini-agents" version

  [ "$status" -eq 0 ]
  [ "$output" = "nini-agents 1.0.0" ]


  # Case 2: multi-cli Bash shim delegates without changing output
  run "$MULTICLI_REPO_ROOT/nini-agents" help
  [ "$status" -eq 0 ]
  local canonical_output="$output"

  run "$MULTICLI_REPO_ROOT/multi-cli" help
  [ "$status" -eq 0 ]
  [ "$output" = "$canonical_output" ]
}

@test "help and shell completion expose canonical compatibility and supported commands" {
  run "$MULTICLI_REPO_ROOT/nini-agents" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"auth set|status|clear"* ]]
  [[ "$output" == *"permissions show | set"* ]]
  [[ "$output" == *"move-export <tool>/<name>"* ]]
  [[ "$output" == *"move-import <package.zip>"* ]]

  run "$MULTICLI_REPO_ROOT/nini-agents" completion bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"complete -F _multi_cli_completions nini-agents multi-cli"* ]]
  [[ "$output" == *" auth "* ]]
  [[ "$output" == *" permissions "* ]]
  [[ "$output" == *" move-export "* ]]
  [[ "$output" == *" move-import "* ]]
}
