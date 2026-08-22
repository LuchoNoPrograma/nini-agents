#!/usr/bin/env bats

load helpers/common

@test "nini-agents is the canonical Bash entrypoint" {
  run "$MULTICLI_REPO_ROOT/nini-agents" version

  [ "$status" -eq 0 ]
  [ "$output" = "nini-agents 1.0.0" ]
}

@test "multi-cli Bash shim delegates without changing output" {
  run "$MULTICLI_REPO_ROOT/nini-agents" help
  [ "$status" -eq 0 ]
  local canonical_output="$output"

  run "$MULTICLI_REPO_ROOT/multi-cli" help
  [ "$status" -eq 0 ]
  [ "$output" = "$canonical_output" ]
}

@test "shell completion registers canonical and compatibility commands" {
  run "$MULTICLI_REPO_ROOT/nini-agents" completion bash

  [ "$status" -eq 0 ]
  [[ "$output" == *"complete -F _multi_cli_completions nini-agents multi-cli"* ]]
}

@test "help and shell completion expose the auth command" {
  run "$MULTICLI_REPO_ROOT/nini-agents" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"auth set|status|clear"* ]]

  run "$MULTICLI_REPO_ROOT/nini-agents" completion bash
  [ "$status" -eq 0 ]
  [[ "$output" == *" auth "* ]]
}

@test "credential target namespace remains backward compatible" {
  run bash -c 'source "$1"; mc_cred_target fixture 11111111-2222-3333-4444-555555555555 TOKEN' _ \
    "$MULTICLI_REPO_ROOT/lib/credential-store.sh"

  [ "$status" -eq 0 ]
  [ "$output" = "multi-cli/fixture/11111111-2222-3333-4444-555555555555/TOKEN" ]
}
