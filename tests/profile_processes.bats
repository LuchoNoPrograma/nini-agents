#!/usr/bin/env bats

load helpers/common

setup() {
  setup_scratch
  [ -d /proc/self ] || skip 'Linux /proc is required'
  export SCRIPT_DIR="$MULTICLI_REPO_ROOT"
  cp "$MULTICLI_REPO_ROOT/ai-tools/codex/adapter.json" "$MULTICLI_TOOLS_DIR/codex/adapter.json"
  mkdir -p "$MULTICLI_HOME/codex/work/auth" "$MULTICLI_HOME/codex/other/auth"
  printf '%s\n' '{"schemaVersion":2,"adapterId":"codex","profileId":"fixture-work","mode":"accountOverlay"}' > "$MULTICLI_HOME/codex/work/.profile.json"
  printf '%s\n' '{"access_token":"synthetic-secret"}' > "$MULTICLI_HOME/codex/work/auth/auth.json"
  JOBS=()
}

teardown() {
  local job
  for job in "${JOBS[@]}"; do kill "$job" 2>/dev/null || true; done
  teardown_scratch
}

orphan_job() {
  local root=$1
  # The launching session exits; only the inherited marker survives.
  job=$(bash -c 'env CODEX_HOME="$1" sleep 60 </dev/null >/dev/null 2>&1 3>&- & echo $!' -- "$root")
  JOBS+=("$job")
}

@test 'preflight reports an orphaned background process without exposing its environment' {
  orphan_job "$MULTICLI_HOME/codex/work/.runtime"
  run "$MULTICLI_BIN" move-export codex/work --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"PID $job "* ]]
  [[ "$output" == *'sleep'* ]]
  [[ "$output" != *'synthetic-secret'* && "$output" != *'fixture-work'* ]]
  [ -d "$MULTICLI_HOME/codex/work" ]
  [ ! -e "$MULTICLI_HOME/codex/.inactive" ]
  kill -0 "$job"
}

@test 'safe stop ends only exact profile jobs then preflight succeeds without writing a ZIP' {
  orphan_job "$MULTICLI_HOME/codex/work/.runtime"
  local selected=$job
  orphan_job "$MULTICLI_HOME/codex/work/.runtime-extra"
  local other=$job
  run "$MULTICLI_BIN" processes codex/work --stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"SIGTERM sent to PID $selected"* ]]
  [[ "$output" != *"SIGTERM sent to PID $other"* ]]
  kill -0 "$other"
  run "$MULTICLI_BIN" move-export codex/work "$MULTICLI_SCRATCH/export.zip" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$MULTICLI_SCRATCH/export.zip" ]
  [ -f "$MULTICLI_HOME/codex/work/auth/auth.json" ]
}

@test 'legacy marker and profile ID both identify inherited jobs' {
  orphan_job "$MULTICLI_HOME/codex/work"
  local legacy=$job
  job=$(bash -c 'env MULTICLI_PROFILE_ID=fixture-work sleep 60 </dev/null >/dev/null 2>&1 3>&- & echo $!')
  JOBS+=("$job")
  # Legacy whole-root profiles have no metadata, but still have CODEX_HOME.
  rm "$MULTICLI_HOME/codex/work/.profile.json"
  run "$MULTICLI_BIN" processes codex/work
  [ "$status" -eq 1 ]
  [[ "$output" == *"PID $legacy "* ]]
  printf '%s\n' '{"schemaVersion":2,"adapterId":"codex","profileId":"fixture-work","mode":"accountOverlay"}' > "$MULTICLI_HOME/codex/work/.profile.json"
  run "$MULTICLI_BIN" processes codex/work
  [ "$status" -eq 1 ]
  [[ "$output" == *"PID $job "* ]]
}

@test 'stop refuses its own session before signalling any selected job' {
  orphan_job "$MULTICLI_HOME/codex/work/.runtime"
  local selected=$job
  run env CODEX_HOME="$MULTICLI_HOME/codex/work/.runtime" "$MULTICLI_BIN" processes codex/work --stop
  [ "$status" -ne 0 ]
  [[ "$output" == *'independent terminal'* ]]
  [[ "$output" != *'SIGTERM sent'* ]]
  kill -0 "$selected"
}

@test 'invalid process commands and linked profiles fail without signalling' {
  orphan_job "$MULTICLI_HOME/codex/work/.runtime"
  run "$MULTICLI_BIN" processes codex/work --force
  [ "$status" -ne 0 ]
  run "$MULTICLI_BIN" processes codex/../work --stop
  [ "$status" -ne 0 ]
  ln -s work "$MULTICLI_HOME/codex/linked"
  run "$MULTICLI_BIN" processes codex/linked --stop
  [ "$status" -ne 0 ]
  kill -0 "$job"
}

@test 'stubborn background jobs keep migration blocked after SIGTERM timeout' {
  job=$(bash -c 'env CODEX_HOME="$1" python3 -c '\''import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print("ready", flush=True); time.sleep(60)'\'' >"$2" 2>&1 </dev/null 3>&- & echo $!' -- "$MULTICLI_HOME/codex/work/.runtime" "$MULTICLI_SCRATCH/ready")
  JOBS+=("$job")
  local i
  for ((i=0; i<100; i++)); do [ ! -s "$MULTICLI_SCRATCH/ready" ] || break; sleep .02; done
  run "$MULTICLI_BIN" processes codex/work --stop
  [ "$status" -eq 1 ]
  [[ "$output" == *'No SIGKILL was sent'* ]]
  kill -0 "$job"
  # Force is used only to clean up this deliberately stubborn synthetic job.
  kill -KILL "$job"
}
