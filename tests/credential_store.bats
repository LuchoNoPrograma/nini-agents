#!/usr/bin/env bats
# Real-execution tests for lib/credential-store.sh -- per-profile secrets in
# the OS credential store (bash mirror of lib/MultiCli.CredentialStore.psm1).
#
# No mocks. On Windows (Git Bash) the windows backend tests really store,
# read and clear uniquely-named targets in Windows Credential Manager and
# prove the secret never lands in any file under the test temp dir. The
# linux/macOS backends get dispatch-selection tests everywhere and real
# round-trips only where their platform + CLI exist (Bats `skip` otherwise --
# never a faked success).

load helpers/common

export CRED_STORE_LIB="$MULTICLI_REPO_ROOT/lib/credential-store.sh"

setup() {
  setup_scratch
  CRED_TEST_TARGET=""
}

teardown() {
  if [ -n "${CRED_TEST_TARGET:-}" ]; then
    cred_call mc_cred_clear "$CRED_TEST_TARGET" >/dev/null 2>&1 || true
  fi
  teardown_scratch
}

# --- Helpers ---------------------------------------------------------------

# Run one library function in a fresh shell with only the library sourced.
# The secret for mc_cred_set travels in MC_CRED_TEST_SECRET (environment) --
# never as a process argument, mirroring the library's own discipline.
cred_call() {
  bash -c '
    source "$CRED_STORE_LIB"
    fn="$1"; shift
    if [ "$fn" = mc_cred_set ]; then
      mc_cred_set "$1" "${MC_CRED_TEST_SECRET:-}"
    else
      "$fn" "$@"
    fi
  ' _ "$@"
}

# Same as cred_call, but forces the platform selector.
cred_platform_call() {
  local plat="$1"
  shift
  MULTICLI_PLATFORM="$plat" cred_call "$@"
}

cred_set() {
  MC_CRED_TEST_SECRET="$2" cred_call mc_cred_set "$1"
}

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr -d '\r' | tr '[:upper:]' '[:lower:]'
    return
  fi
  if [ -r /proc/sys/kernel/random/uuid ]; then
    tr -d '\r\n' < /proc/sys/kernel/random/uuid
    return
  fi
  powershell.exe -NoProfile -Command '[guid]::NewGuid().ToString("N")' | tr -d '\r'
}

# Unique Credential-Manager target per test, mirroring the Pester suite's
# multi-cli/tests/<guid> shape plus the env-var segment of real targets.
new_credential_target() {
  printf 'multi-cli/tests/%s/MCLI_BATS_TOKEN\n' "$(new_uuid)"
}

new_secret() {
  printf 'mcli-bats-secret-%s\n' "$(new_uuid)"
}

# --- Target naming ----------------------------------------------------------

@test "matrix: mc_cred_target builds multi-cli/<tool>/<profileId>/<ENVVAR> (+1 related)" {
  # Case 1: mc_cred_target builds multi-cli/<tool>/<profileId>/<ENVVAR>
  run cred_call mc_cred_target cursor-cli 9b2e4c6a1234 CURSOR_API_KEY
  [ "$status" -eq 0 ]
  [ "$output" = "multi-cli/cursor-cli/9b2e4c6a1234/CURSOR_API_KEY" ]

  teardown
  setup

  # Case 2: mc_cred_target rejects empty segments with an actionable error
  run cred_call mc_cred_target "" some-id SOME_VAR
  [ "$status" -ne 0 ]
  [[ "$output" == *"tool"* ]]

  run cred_call mc_cred_target cursor-cli "" SOME_VAR
  [ "$status" -ne 0 ]
  [[ "$output" == *"profileId"* ]]

  run cred_call mc_cred_target cursor-cli some-id ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"environment variable"* ]]
}

# --- Input validation (fires before any backend is touched) -----------------

@test "matrix: entry points reject an empty target with an actionable error (+1 related)" {
  # Case 1: entry points reject an empty target with an actionable error
  run cred_call mc_cred_get ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"target"* ]]

  run cred_call mc_cred_clear ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"target"* ]]

  run cred_call mc_cred_present ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"target"* ]]

  export MC_CRED_TEST_SECRET="dummy-secret"
  run cred_call mc_cred_set ""
  unset MC_CRED_TEST_SECRET
  [ "$status" -ne 0 ]
  [[ "$output" == *"target"* ]]

  teardown
  setup

  # Case 2: mc_cred_set rejects an empty secret before touching any backend
  export MC_CRED_TEST_SECRET=""
  run cred_call mc_cred_set "multi-cli/tests/$(new_uuid)/MCLI_BATS_TOKEN"
  unset MC_CRED_TEST_SECRET
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]]
}

# --- Backend selection ------------------------------------------------------

@test "matrix: platform detection maps darwin/linux/msys to macos/linux/windows (+1 related)" {
  # Case 1: platform detection maps darwin/linux/msys to macos/linux/windows
  run cred_platform_call darwin mc_cred_platform
  [ "$status" -eq 0 ]
  [ "$output" = "macos" ]

  run cred_platform_call linux mc_cred_platform
  [ "$status" -eq 0 ]
  [ "$output" = "linux" ]

  run cred_platform_call msys_nt-10.0-19045 mc_cred_platform
  [ "$status" -eq 0 ]
  [ "$output" = "windows" ]

  run cred_platform_call MINGW64_NT-10.0 mc_cred_platform
  [ "$status" -eq 0 ]
  [ "$output" = "windows" ]

  teardown
  setup

  # Case 2: unsupported platform aborts with an actionable error
  run cred_platform_call freebsd mc_cred_get "multi-cli/tests/x/MCLI_BATS_TOKEN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsupported platform"* ]]
}

@test "linux dispatch aborts with a libsecret-tools hint when secret-tool is missing" {
  command -v secret-tool >/dev/null 2>&1 && skip "secret-tool installed; missing-CLI path not testable"
  run cred_platform_call linux mc_cred_get "multi-cli/tests/irrelevant/MCLI_BATS_TOKEN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"secret-tool"* ]]
  [[ "$output" == *"libsecret-tools"* ]]
}

@test "macos dispatch aborts when the security CLI is missing" {
  command -v security >/dev/null 2>&1 && skip "security CLI present; missing-CLI path not testable"
  run cred_platform_call macos mc_cred_get "multi-cli/tests/irrelevant/MCLI_BATS_TOKEN"
  [ "$status" -ne 0 ]
  [[ "$output" == *"security"* ]]
}

# --- linux backend (real store only where it exists) ------------------------

@test "linux backend round-trips a secret via secret-tool" {
  [ "$(uname -s 2>/dev/null)" = "Linux" ] || skip "linux round-trip requires a Linux host"
  command -v secret-tool >/dev/null 2>&1 || skip "secret-tool not installed (libsecret-tools)"
  CRED_TEST_TARGET="$(new_credential_target)"
  local secret
  secret="$(new_secret)"

  run cred_set "$CRED_TEST_TARGET" "$secret"
  [ "$status" -eq 0 ]

  run cred_call mc_cred_get "$CRED_TEST_TARGET"
  [ "$status" -eq 0 ]
  [ "$output" = "$secret" ]

  run cred_call mc_cred_present "$CRED_TEST_TARGET"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  run grep -rF -- "$secret" "$MULTICLI_SCRATCH/"
  [ "$status" -eq 1 ]

  run cred_call mc_cred_clear "$CRED_TEST_TARGET"
  [ "$status" -eq 0 ]

  run cred_call mc_cred_get "$CRED_TEST_TARGET"
  [ "$status" -eq 1 ]
}

# --- macOS backend (real store only where it exists) ------------------------

# A contract stub for the macOS `security` CLI: an absent item exits 44 with
# the real not-found message on STDERR. Recorded from `security
# find-generic-password` on a keychain miss; replayed here so the not-found
# path is testable on any host.
write_security_stub_absent() {
  local bin_dir="$MULTICLI_SCRATCH/mac-bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/security" <<'STUB'
#!/usr/bin/env bash
if [ -n "${SECURITY_ARGUMENT_CAPTURE:-}" ]; then
  printf '%s\n' "$@" > "$SECURITY_ARGUMENT_CAPTURE"
fi
echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
exit 44
STUB
  chmod +x "$bin_dir/security"
  printf '%s\n' "$bin_dir"
}

@test "macos backend restricts every operation to the configured keychain" {
  local bin_dir capture keychain
  bin_dir="$(write_security_stub_absent)"
  capture="$MULTICLI_SCRATCH/security-arguments"
  keychain="$MULTICLI_SCRATCH/multicli-ci.keychain-db"

  run env PATH="$bin_dir:$PATH" MULTICLI_PLATFORM=macos MULTICLI_MACOS_KEYCHAIN="$keychain" SECURITY_ARGUMENT_CAPTURE="$capture" bash -c '
    source "$CRED_STORE_LIB"
    "$1" "multi-cli/tests/absent/MCLI_BATS_TOKEN" "test-secret"
  ' _ mc_cred_mac_present
  [ "$status" -eq 1 ]
  [ "$(tail -n 1 "$capture")" = "$keychain" ]

  run env PATH="$bin_dir:$PATH" MULTICLI_PLATFORM=macos MULTICLI_MACOS_KEYCHAIN="$keychain" SECURITY_ARGUMENT_CAPTURE="$capture" bash -c '
    source "$CRED_STORE_LIB"
    "$1" "multi-cli/tests/absent/MCLI_BATS_TOKEN" "test-secret"
  ' _ mc_cred_mac_set
  [ "$status" -eq 44 ]
  [ "$(tail -n 1 "$capture")" = "$keychain" ]

  run env PATH="$bin_dir:$PATH" MULTICLI_PLATFORM=macos MULTICLI_MACOS_KEYCHAIN="$keychain" SECURITY_ARGUMENT_CAPTURE="$capture" bash -c '
    source "$CRED_STORE_LIB"
    "$1" "multi-cli/tests/absent/MCLI_BATS_TOKEN" "test-secret"
  ' _ mc_cred_mac_get
  [ "$status" -eq 1 ]
  [ "$(tail -n 1 "$capture")" = "$keychain" ]

  run env PATH="$bin_dir:$PATH" MULTICLI_PLATFORM=macos MULTICLI_MACOS_KEYCHAIN="$keychain" SECURITY_ARGUMENT_CAPTURE="$capture" bash -c '
    source "$CRED_STORE_LIB"
    "$1" "multi-cli/tests/absent/MCLI_BATS_TOKEN" "test-secret"
  ' _ mc_cred_mac_clear
  [ "$status" -eq 0 ]
  [ "$(tail -n 1 "$capture")" = "$keychain" ]
}

@test "macos backend keeps absent-item operations silent and idempotent" {
  local bin_dir
  bin_dir="$(write_security_stub_absent)"
  local operation expected_status
  for operation in mc_cred_present mc_cred_clear mc_cred_get; do
    expected_status=1
    [ "$operation" = "mc_cred_clear" ] && expected_status=0
    run bash -c '
      PATH="$1:$PATH"
      export MULTICLI_PLATFORM=macos
      source "$CRED_STORE_LIB"
      "$2" "multi-cli/tests/absent/MCLI_BATS_TOKEN"
    ' _ "$bin_dir" "$operation"
    [ "$status" -eq "$expected_status" ]
    [ "$output" = "" ]
  done
}

@test "macos backend round-trips a secret via the login keychain" {
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || skip "macos round-trip requires a macOS host"
  command -v security >/dev/null 2>&1 || skip "security CLI not available"
  CRED_TEST_TARGET="$(new_credential_target)"
  local secret
  secret="$(new_secret)"

  run cred_set "$CRED_TEST_TARGET" "$secret"
  [ "$status" -eq 0 ]

  run cred_call mc_cred_get "$CRED_TEST_TARGET"
  [ "$status" -eq 0 ]
  [ "$output" = "$secret" ]

  run cred_call mc_cred_present "$CRED_TEST_TARGET"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  run grep -rF -- "$secret" "$MULTICLI_SCRATCH/"
  [ "$status" -eq 1 ]

  run cred_call mc_cred_clear "$CRED_TEST_TARGET"
  [ "$status" -eq 0 ]

  run cred_call mc_cred_get "$CRED_TEST_TARGET"
  [ "$status" -eq 1 ]
}

# --- Windows backend (real Credential Manager on this host) ------------------

@test "matrix: windows backend stores, reads and clears a secret in Credential Manager without touching disk (+3 related)" {
  # Case 1: windows backend stores, reads and clears a secret in Credential Manager without touching disk
  _multicli_is_windows || skip "windows backend test requires Git Bash on Windows"
  CRED_TEST_TARGET="$(new_credential_target)"
  local secret=" mcli-bats-$(new_uuid) sp ac/e+äöü€ "

  run cred_set "$CRED_TEST_TARGET" "$secret"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  # present is a silent boolean: exit 0, no output
  run cred_call mc_cred_present "$CRED_TEST_TARGET"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  # byte-exact read-back, including padding, spaces and non-ASCII
  run cred_call mc_cred_get "$CRED_TEST_TARGET"
  [ "$status" -eq 0 ]
  [ "$output" = "$secret" ]

  # the secret must not exist in ANY file under the test temp dir
  run grep -rF -- "$secret" "$MULTICLI_SCRATCH/"
  [ "$status" -eq 1 ]

  run cred_call mc_cred_clear "$CRED_TEST_TARGET"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  # after clear: get is non-zero with empty output; present is silent false
  run cred_call mc_cred_get "$CRED_TEST_TARGET"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]

  run cred_call mc_cred_present "$CRED_TEST_TARGET"
  [ "$status" -eq 1 ]
  [ "$output" = "" ]

  teardown
  setup

  # Case 2: windows backend overwrites an existing secret at the same target
  _multicli_is_windows || skip "windows backend test requires Git Bash on Windows"
  CRED_TEST_TARGET="$(new_credential_target)"

  cred_set "$CRED_TEST_TARGET" "first-secret-value"
  cred_set "$CRED_TEST_TARGET" "second-secret-value"

  run cred_call mc_cred_get "$CRED_TEST_TARGET"
  [ "$status" -eq 0 ]
  [ "$output" = "second-secret-value" ]

  teardown
  setup

  # Case 3: windows backend keeps a command-injection-shaped secret inert
  _multicli_is_windows || skip "windows backend test requires Git Bash on Windows"
  CRED_TEST_TARGET="$(new_credential_target)"
  # If this string ever reached a command line or script text, the exit code
  # or output would change. Byte-exact round-trip proves stdin-only transport.
  local secret='x"; exit 42; "$(whoami)"; `calc`; $env:USERPROFILE; &("pwn")'

  run cred_set "$CRED_TEST_TARGET" "$secret"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  run cred_call mc_cred_get "$CRED_TEST_TARGET"
  [ "$status" -eq 0 ]
  [ "$output" = "$secret" ]

  teardown
  setup

  # Case 4: windows backend clear is idempotent on a never-stored target
  _multicli_is_windows || skip "windows backend test requires Git Bash on Windows"
  CRED_TEST_TARGET="$(new_credential_target)"

  run cred_call mc_cred_clear "$CRED_TEST_TARGET"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}
