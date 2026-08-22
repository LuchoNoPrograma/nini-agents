#!/usr/bin/env bats

load helpers/common

# Transactional credential-bearing profile movement. Every profile, adapter,
# transport and process probe is synthetic and lives below the per-test scratch
# root. The fixtures contain structural JSON only, never real credentials.

setup() {
  setup_scratch
  export USERPROFILE="$HOME"
  export APPDATA="$HOME/AppData/Roaming"
  export LOCALAPPDATA="$HOME/AppData/Local"
  MOVE_TOOLS="$MULTICLI_SCRATCH/move-tools"
  MOVE_MANIFEST="$MOVE_TOOLS/fixture/adapter.json"
  MOVE_SOURCE_ROOT="$MULTICLI_SCRATCH/source"
  MOVE_DESTINATION_ROOT="$MULTICLI_SCRATCH/destination"
  mkdir -p "$MOVE_TOOLS/fixture" "$MOVE_SOURCE_ROOT" "$MOVE_DESTINATION_ROOT"
  write_move_adapter
}

teardown() {
  teardown_scratch
}

write_move_adapter() {
  cat > "$MOVE_MANIFEST" <<'JSON'
{
  "schemaVersion": 2,
  "id": "fixture",
  "displayName": "Fixture CLI",
  "kind": "cli",
  "binary": {"windows":["fixture.exe"],"macos":["fixture"],"linux":["fixture"]},
  "isolation": {"strategy":"accountOverlay","mode":"foreground","env":{"FIXTURE_HOME":"{runtimeRoot}"},"clearEnv":[]},
  "account": {"mechanism":"fileOverlay","credentialFiles":["auth.json"],"credentialPrecedence":["auth.json"],"logoutScope":"profile"},
  "normalState": {
    "root":{"windows":"%USERPROFILE%\\.fixture","macos":"$HOME/.fixture","linux":"$HOME/.fixture"},
    "sharedPaths":["config.toml","rules"],
    "sessionPaths":["sessions","history.jsonl"],
    "filePaths":["config.toml","history.jsonl"],
    "unsafePaths":[]
  },
  "concurrency":{"level":"multiWriter","singletonScope":"none"},
  "support":{"windows":{"level":"supported"},"macos":{"level":"supported"},"linux":{"level":"supported"}},
  "install":"https://example.test/install",
  "versionCommand":["--version"]
}
JSON
}

make_legacy_move_profile() {
  local profile="$MOVE_SOURCE_ROOT/account-a"
  mkdir -p "$profile/rules" "$profile/sessions"
  printf '{"fixture":true}\n' > "$profile/auth.json"
  printf 'model = "fixture"\n' > "$profile/config.toml"
  printf '# fixture rule\n' > "$profile/rules/default.md"
  printf '{"session":"fixture"}\n' > "$profile/sessions/one.jsonl"
  printf '{"history":"fixture"}\n' > "$profile/history.jsonl"
}

make_v2_move_profile() {
  local profile="$MOVE_SOURCE_ROOT/account-a"
  mkdir -p "$profile/auth"
  printf '{"fixture":true}\n' > "$profile/auth/auth.json"
  printf '%s\n' '{"schemaVersion":2,"adapterId":"fixture","profileId":"fixture-profile","mode":"accountOverlay"}' > "$profile/.profile.json"
}

# Run the real movement engine in a child shell. The process probe and
# transport are explicit protocol inputs, so tests never inspect host
# processes or contact another machine. Output contains only state/error codes.
move_run() {
  local scenario="${1:-success}" dry_run="${2:-false}"
  bash -c '
    repo=$1; manifest=$2; source_root=$3; destination_root=$4; scenario=$5; dry_run=$6
    cd "$repo" || exit 1
    set -- help
    source ./nini-agents >/dev/null 2>&1
    source ./lib/transfer.sh

    probe_free() { return 1; }
    probe_busy() { return 0; }
    probe_failed() { return 2; }
    probe_calls=0
    probe_appears() {
      probe_calls=$((probe_calls + 1))
      [ "$probe_calls" -ge 3 ] && return 0
      return 1
    }
    copy_local() { move_copy_candidate_local "$1" "$2"; }
    copy_failed() { return 1; }
    copy_tampered() {
      move_copy_candidate_local "$1" "$2" || return 1
      if [ -f "$2/auth/auth.json" ]; then
        printf "{\\\"fixture\\\":false}\\n" > "$2/auth/auth.json"
      else
        printf "{\\\"fixture\\\":false}\\n" > "$2/auth.json"
      fi
    }

    probe=probe_free
    copy=copy_local
    case "$scenario" in
      busy) probe=probe_busy ;;
      probe-fail) probe=probe_failed ;;
      process-appears) probe=probe_appears ;;
      transport-fail) copy=copy_failed ;;
      tamper) copy=copy_tampered ;;
      activate-fail) move_activate_candidate() { return 1; } ;;
      deactivate-fail) move_deactivate_source() { return 1; } ;;
      runtime-fail) runtime_build_overlay() { return 1; } ;;
      rollback-fail)
        move_activate_candidate() { mv -- "$1" "$2"; return 1; }
        move_quarantine_destination() { return 1; }
        ;;
      post-activate-tamper)
        move_activate_candidate() {
          mv -- "$1" "$2" || return 1
          if [ -f "$2/auth/auth.json" ]; then
            printf "{\\\"fixture\\\":false}\\n" > "$2/auth/auth.json"
          else
            printf "{\\\"fixture\\\":false}\\n" > "$2/auth.json"
          fi
        }
        ;;
    esac

    if move_profile_transaction "$manifest" "$source_root" "$destination_root" account-a fixture-op "$probe" "$copy" "$dry_run"; then
      rc=0
    else
      rc=$?
    fi
    printf "%s|%s|%s\n" "$MOVE_RESULT_CODE" "$MOVE_RESULT_STATE" "$MOVE_RESULT_FORMAT"
    exit "$rc"
  ' move-run "$MULTICLI_REPO_ROOT" "$MOVE_MANIFEST" "$MOVE_SOURCE_ROOT" "$MOVE_DESTINATION_ROOT" "$scenario" "$dry_run"
}

@test "legacy move stages, verifies, activates exactly one copy, and keeps an inactive backup" {
  make_legacy_move_profile
  cp "$MOVE_SOURCE_ROOT/account-a/auth.json" "$MULTICLI_SCRATCH/auth.before"

  run move_run

  [ "$status" -eq 0 ]
  [ "$output" = "ok|destination_active|legacy" ]
  [ ! -e "$MOVE_SOURCE_ROOT/account-a" ]
  [ -d "$MOVE_DESTINATION_ROOT/account-a" ]
  [ -d "$MOVE_SOURCE_ROOT/.inactive/account-a.fixture-op" ]
  cmp -s "$MULTICLI_SCRATCH/auth.before" "$MOVE_DESTINATION_ROOT/account-a/auth.json"
  cmp -s "$MULTICLI_SCRATCH/auth.before" "$MOVE_SOURCE_ROOT/.inactive/account-a.fixture-op/auth.json"
}

@test "schema-v2 move treats runtime as reconstructible and preserves credential bytes" {
  make_v2_move_profile
  cp "$MOVE_SOURCE_ROOT/account-a/auth/auth.json" "$MULTICLI_SCRATCH/auth.before"

  run move_run

  [ "$status" -eq 0 ]
  [ "$output" = "ok|destination_active|v2" ]
  cmp -s "$MULTICLI_SCRATCH/auth.before" "$MOVE_DESTINATION_ROOT/account-a/auth/auth.json"
  [ -e "$MOVE_DESTINATION_ROOT/account-a/.runtime/auth.json" ]
  cmp -s "$MULTICLI_SCRATCH/auth.before" "$MOVE_DESTINATION_ROOT/account-a/.runtime/auth.json"
  [ -f "$MOVE_DESTINATION_ROOT/account-a/.profile.json" ]
}

@test "dry-run validates without creating staging, backup, or destination" {
  make_v2_move_profile

  run move_run success true

  [ "$status" -eq 0 ]
  [ "$output" = "dry_run|validated|v2" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
  [ ! -e "$MOVE_DESTINATION_ROOT/account-a" ]
  [ ! -e "$MOVE_DESTINATION_ROOT/.staging" ]
  [ ! -e "$MOVE_SOURCE_ROOT/.inactive" ]
}

@test "an active destination rejects the move before any copy" {
  make_v2_move_profile
  mkdir -p "$MOVE_DESTINATION_ROOT/account-a"

  run move_run

  [ "$status" -ne 0 ]
  [ "$output" = "destination_active|preflight_rejected|unknown" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
  [ ! -e "$MOVE_DESTINATION_ROOT/.staging" ]
}

@test "malformed authentication JSON rejects both legacy and schema-v2 profiles" {
  make_legacy_move_profile
  printf 'not-json\n' > "$MOVE_SOURCE_ROOT/account-a/auth.json"
  run move_run
  [ "$status" -ne 0 ]
  [ "$output" = "invalid_auth_json|preflight_rejected|legacy" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]

  rm -rf "$MOVE_SOURCE_ROOT/account-a"
  make_v2_move_profile
  printf 'not-json\n' > "$MOVE_SOURCE_ROOT/account-a/auth/auth.json"
  run move_run
  [ "$status" -ne 0 ]
  [ "$output" = "invalid_auth_json|preflight_rejected|v2" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
}

@test "metadata mismatch and unknown content fail closed" {
  make_v2_move_profile
  printf '%s\n' '{"schemaVersion":2,"adapterId":"other","profileId":"fixture-profile","mode":"accountOverlay"}' > "$MOVE_SOURCE_ROOT/account-a/.profile.json"
  run move_run
  [ "$status" -ne 0 ]
  [ "$output" = "invalid_metadata|preflight_rejected|v2" ]

  printf '%s\n' '{"schemaVersion":2,"adapterId":"fixture","profileId":"fixture-profile","mode":"accountOverlay"}' > "$MOVE_SOURCE_ROOT/account-a/.profile.json"
  printf 'unknown\n' > "$MOVE_SOURCE_ROOT/account-a/private.bin"
  run move_run
  [ "$status" -ne 0 ]
  [ "$output" = "unknown_content|preflight_rejected|v2" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
}

@test "links and unexpected hardlinks are rejected without following them" {
  make_legacy_move_profile
  printf 'outside\n' > "$MULTICLI_SCRATCH/outside"
  ln -s "$MULTICLI_SCRATCH/outside" "$MOVE_SOURCE_ROOT/account-a/rules/external"
  run move_run
  [ "$status" -ne 0 ]
  [ "$output" = "unsafe_link|preflight_rejected|legacy" ]

  rm "$MOVE_SOURCE_ROOT/account-a/rules/external"
  ln "$MOVE_SOURCE_ROOT/account-a/rules/default.md" "$MOVE_SOURCE_ROOT/account-a/rules/alias.md"
  run move_run
  [ "$status" -ne 0 ]
  [ "$output" = "unsafe_hardlink|preflight_rejected|legacy" ]
  [ -f "$MULTICLI_SCRATCH/outside" ]
}

@test "an active process blocks the move before staging" {
  make_v2_move_profile

  run move_run busy

  [ "$status" -ne 0 ]
  [ "$output" = "process_active|preflight_rejected|v2" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
  [ ! -e "$MOVE_DESTINATION_ROOT/.staging" ]
}

@test "a pre-existing staging or backup path is never overwritten" {
  make_v2_move_profile
  mkdir -p "$MOVE_DESTINATION_ROOT/.staging/account-a.fixture-op"
  run move_run
  [ "$status" -ne 0 ]
  [ "$output" = "staging_conflict|preflight_rejected|v2" ]

  rm -rf "$MOVE_DESTINATION_ROOT/.staging"
  mkdir -p "$MOVE_SOURCE_ROOT/.inactive/account-a.fixture-op"
  run move_run
  [ "$status" -ne 0 ]
  [ "$output" = "backup_conflict|preflight_rejected|v2" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]

  rm -rf "$MOVE_SOURCE_ROOT/.inactive"
  mkdir "$MOVE_SOURCE_ROOT/.move-lock.account-a"
  run move_run
  [ "$status" -ne 0 ]
  [ "$output" = "transaction_locked|preflight_rejected|v2" ]
}

@test "an integrity mismatch leaves the source active and staging recoverable" {
  make_v2_move_profile

  run move_run tamper

  [ "$status" -ne 0 ]
  [ "$output" = "integrity_mismatch|staging_rejected|v2" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
  [ ! -e "$MOVE_DESTINATION_ROOT/account-a" ]
  [ -d "$MOVE_DESTINATION_ROOT/.staging/account-a.fixture-op" ]
}

@test "activation failure restores the source and preserves staging" {
  make_v2_move_profile

  run move_run activate-fail

  [ "$status" -ne 0 ]
  [ "$output" = "activation_failed_rolled_back|source_restored|v2" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
  [ ! -e "$MOVE_DESTINATION_ROOT/account-a" ]
  [ -d "$MOVE_DESTINATION_ROOT/.staging/account-a.fixture-op" ]
  [ ! -e "$MOVE_SOURCE_ROOT/.inactive/account-a.fixture-op" ]
}

@test "post-activation tampering is quarantined and the source is restored" {
  make_v2_move_profile

  run move_run post-activate-tamper

  [ "$status" -ne 0 ]
  [ "$output" = "destination_invalid_rolled_back|source_restored|v2" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
  [ ! -e "$MOVE_DESTINATION_ROOT/account-a" ]
  [ -d "$MOVE_DESTINATION_ROOT/.failed/account-a.fixture-op" ]
}

@test "the process probe must prove idle and is repeated after staging" {
  make_v2_move_profile

  run move_run probe-fail
  [ "$status" -ne 0 ]
  [ "$output" = "process_probe_failed|preflight_rejected|v2" ]
  [ ! -e "$MOVE_DESTINATION_ROOT/.staging" ]

  run move_run process-appears
  [ "$status" -ne 0 ]
  [ "$output" = "process_appeared|staging_preserved|v2" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
  [ -d "$MOVE_DESTINATION_ROOT/.staging/account-a.fixture-op" ]
}

@test "transport and source deactivation failures never activate the destination" {
  make_v2_move_profile

  run move_run transport-fail
  [ "$status" -ne 0 ]
  [ "$output" = "transport_failed|staging_preserved|v2" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
  [ ! -e "$MOVE_DESTINATION_ROOT/account-a" ]

  rm -rf "$MOVE_DESTINATION_ROOT/.staging"
  run move_run deactivate-fail
  [ "$status" -ne 0 ]
  [ "$output" = "source_deactivation_failed|source_active|v2" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
  [ -d "$MOVE_DESTINATION_ROOT/.staging/account-a.fixture-op" ]
}

@test "runtime reconstruction failure quarantines destination and restores source" {
  make_v2_move_profile

  run move_run runtime-fail

  [ "$status" -ne 0 ]
  [ "$output" = "destination_runtime_failed_rolled_back|source_restored|v2" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
  [ ! -e "$MOVE_DESTINATION_ROOT/account-a" ]
  [ -d "$MOVE_DESTINATION_ROOT/.failed/account-a.fixture-op" ]
}

@test "an unquarantinable partial destination leaves source inactive and all artifacts recoverable" {
  make_v2_move_profile

  run move_run rollback-fail

  [ "$status" -ne 0 ]
  [ "$output" = "rollback_failed|ownership_indeterminate|v2" ]
  [ ! -e "$MOVE_SOURCE_ROOT/account-a" ]
  [ -d "$MOVE_SOURCE_ROOT/.inactive/account-a.fixture-op" ]
  [ -d "$MOVE_DESTINATION_ROOT/account-a" ]
}

@test "transaction control directories cannot be links or files" {
  make_v2_move_profile
  mkdir -p "$MULTICLI_SCRATCH/outside-transaction"
  ln -s "$MULTICLI_SCRATCH/outside-transaction" "$MOVE_DESTINATION_ROOT/.staging"

  run move_run

  [ "$status" -ne 0 ]
  [ "$output" = "unsafe_root|preflight_rejected|unknown" ]
  [ -d "$MOVE_SOURCE_ROOT/account-a" ]
  [ -z "$(find "$MULTICLI_SCRATCH/outside-transaction" -mindepth 1 -print -quit)" ]
}

@test "the one expected schema-v2 runtime credential hardlink is not treated as an unknown credential" {
  make_v2_move_profile
  mkdir -p "$MOVE_SOURCE_ROOT/account-a/.runtime"
  ln "$MOVE_SOURCE_ROOT/account-a/auth/auth.json" "$MOVE_SOURCE_ROOT/account-a/.runtime/auth.json"

  run move_run

  [ "$status" -eq 0 ]
  [ "$output" = "ok|destination_active|v2" ]
  [ -e "$MOVE_DESTINATION_ROOT/account-a/.runtime/auth.json" ]
}
