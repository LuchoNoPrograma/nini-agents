#!/usr/bin/env bash
# Stable JSON envelope helpers for Nini Agents CLI consumers.
# Callers must pass already-sanitized data. This module never reads profiles.

cli_json_success() {
  local command="$1" data_json="$2"
  jq -cn --arg command "$command" --argjson data "$data_json" '{
    schemaVersion: 1,
    command: $command,
    ok: true,
    data: $data,
    error: null
  }'
}

cli_json_error() {
  local command="$1" code="$2" message="$3" details_json="${4:-null}"
  jq -cn \
    --arg command "$command" \
    --arg code "$code" \
    --arg message "$message" \
    --argjson details "$details_json" '{
      schemaVersion: 1,
      command: $command,
      ok: false,
      data: null,
      error: ({code: $code, message: $message} +
        (if $details == null then {} else {details: $details} end))
    }'
}

# Serialize a profile mutation failure without forwarding implementation
# messages, filesystem paths, profile IDs, or credential details.
cli_json_mutation_error() {
  local command="$1" code="$2" message="$3" state="$4"
  cli_json_error "$command" "$code" "$message" \
    "$(jq -cn --arg state "$state" '{state: $state}')"
}

# Serialize the current transactional movement result without paths, profile
# identifiers, operation identifiers, credentials, or callback details.
cli_json_move_result() {
  local succeeded="$1" details
  details="$(jq -cn \
    --arg state "${MOVE_RESULT_STATE:-unknown}" \
    --arg format "${MOVE_RESULT_FORMAT:-unknown}" \
    '{state: $state, format: $format}')"
  if [ "$succeeded" = true ]; then
    cli_json_success move "$(jq -cn \
      --arg code "${MOVE_RESULT_CODE:-unknown}" \
      --argjson details "$details" \
      '{code: $code, state: $details.state, format: $details.format}')"
  else
    cli_json_error move "${MOVE_RESULT_CODE:-operation_failed}" \
      'The profile movement did not complete.' "$details"
  fi
}
