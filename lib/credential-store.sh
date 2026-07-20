#!/usr/bin/env bash
# credential-store.sh -- per-profile secrets in the OS credential store.
#
# Bash mirror of lib/MultiCli.CredentialStore.psm1: same target naming
# (multi-cli/<tool>/<profileId>/<ENVVAR>) and same semantics, backed by the
# platform's native store:
#   windows (Git Bash/MSYS): Windows Credential Manager, via the PowerShell
#                            module lib/MultiCli.CredentialStore.psm1
#   macos:                   login keychain, via the `security` CLI
#   linux:                   Secret Service (gnome-keyring/KWallet), via
#                            `secret-tool` (libsecret-tools)
#
# Hard rules:
#   - secrets travel only via stdin or environment variables, never as
#     process command-line arguments -- the one exception is the macOS
#     `security` CLI, which has no stdin secret channel and only accepts
#     `-w` (documented at mc_cred_mac_set);
#   - this library never writes secrets to disk (no plaintext fallback files);
#   - mc_cred_present is a silent boolean (exit code only, no output).

set -euo pipefail

# The launcher defines abort(); provide the same shape when the library is
# sourced stand-alone (tests, direct sourcing).
if ! declare -F abort >/dev/null 2>&1; then
  abort() { echo "Error: $1" >&2; exit 1; }
fi

# Canonical platform name, honoring MULTICLI_PLATFORM like the launcher.
mc_cred_platform() {
  local raw="${MULTICLI_PLATFORM:-$(uname -s 2>/dev/null || echo unknown)}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    darwin|macos|mac|osx)         printf 'macos\n' ;;
    linux)                        printf 'linux\n' ;;
    mingw*|msys*|cygwin*|windows*) printf 'windows\n' ;;
    *) abort "unsupported platform '$raw' for credential storage" ;;
  esac
}

# Build the credential target key: multi-cli/<tool>/<profileId>/<envVar>.
mc_cred_target() {
  local tool="${1:-}" profile_id="${2:-}" env_var="${3:-}"
  [ -n "$tool" ] || abort "credential target requires a tool id. Usage: mc_cred_target <tool> <profileId> <envVar>"
  [ -n "$profile_id" ] || abort "credential target requires a profileId. Usage: mc_cred_target <tool> <profileId> <envVar>"
  [ -n "$env_var" ] || abort "credential target requires an environment variable name. Usage: mc_cred_target <tool> <profileId> <envVar>"
  printf 'multi-cli/%s/%s/%s\n' "$tool" "$profile_id" "$env_var"
}

mc_cred_require_target() {
  [ -n "${1:-}" ] || abort "credential target is required. Build one with: mc_cred_target <tool> <profileId> <envVar>"
}

# --- Windows backend (Credential Manager via the PowerShell module) ---------

# Inline PowerShell wrapper: dot-sources MultiCli.CredentialStore.psm1 and
# invokes one operation. The target travels in MC_CRED_TARGET (environment);
# the secret travels on stdin (set) or stdout (get) as raw UTF-8 bytes --
# never on the command line. Exit codes: 0 ok/present, 3 not found, 2 error.
# Export-ModuleMember rejects execution outside a module, so the dot-source
# runs with errors silenced; the Get-Command guard keeps a failed load loud.
MC_CRED_PS_WRAPPER='
$ErrorActionPreference = "Stop"
$code = [System.IO.File]::ReadAllText($env:MC_CRED_MODULE)
$ErrorActionPreference = "SilentlyContinue"
. ([ScriptBlock]::Create($code))
$ErrorActionPreference = "Stop"
if (-not (Get-Command Set-MultiCliCredential -ErrorAction SilentlyContinue)) {
  throw "failed to load MultiCli.CredentialStore.psm1"
}
$target = $env:MC_CRED_TARGET
try {
  switch ($env:MC_CRED_OP) {
    "set" {
      $stream = [Console]::OpenStandardInput()
      $memory = New-Object System.IO.MemoryStream
      $stream.CopyTo($memory)
      $secret = [Text.Encoding]::UTF8.GetString($memory.ToArray())
      Set-MultiCliCredential -Target $target -Secret $secret
      exit 0
    }
    "get" {
      $value = Get-MultiCliCredential -Target $target
      if ($null -eq $value) { exit 3 }
      $bytes = [Text.Encoding]::UTF8.GetBytes($value)
      $stdout = [Console]::OpenStandardOutput()
      $stdout.Write($bytes, 0, $bytes.Length)
      exit 0
    }
    "clear" {
      Remove-MultiCliCredential -Target $target | Out-Null
      exit 0
    }
    "test" {
      if (Test-MultiCliCredential -Target $target) { exit 0 }
      exit 3
    }
    default { exit 2 }
  }
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 2
}
'

# Invoke the PowerShell wrapper. $1 = operation, $2 = target. For "set" the
# secret must arrive on stdin. Returns the wrapper's exit code verbatim.
mc_cred_ps_invoke() {
  local op="$1" target="$2"
  command -v powershell.exe >/dev/null 2>&1 || \
    abort "powershell.exe not found on PATH; the windows credential backend requires Windows PowerShell 5.1+"
  command -v cygpath >/dev/null 2>&1 || \
    abort "cygpath not found; the windows credential backend requires Git Bash/MSYS2"
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  MSYS2_ARG_CONV_EXCL='*' \
  MC_CRED_MODULE="$(cygpath -w "$lib_dir/MultiCli.CredentialStore.psm1")" \
  MC_CRED_OP="$op" \
  MC_CRED_TARGET="$target" \
    powershell.exe -NoProfile -Command "$MC_CRED_PS_WRAPPER"
}

mc_cred_win_set() {
  local target="$1" secret="$2" rc=0
  printf '%s' "$secret" | mc_cred_ps_invoke set "$target" || rc=$?
  return "$rc"
}

mc_cred_win_get() {
  local target="$1" rc=0
  mc_cred_ps_invoke get "$target" </dev/null || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) return 1 ;;
    *) return "$rc" ;;
  esac
}

mc_cred_win_clear() {
  local target="$1" rc=0
  mc_cred_ps_invoke clear "$target" </dev/null || rc=$?
  return "$rc"
}

mc_cred_win_present() {
  local target="$1" rc=0
  mc_cred_ps_invoke test "$target" </dev/null >/dev/null || rc=$?
  case "$rc" in
    0) return 0 ;;
    3) return 1 ;;
    *) return "$rc" ;;
  esac
}

# --- macOS backend (login keychain) ------------------------------------------

mc_cred_mac_require_security() {
  command -v security >/dev/null 2>&1 || \
    abort "the 'security' CLI is required for macOS credential storage but was not found on PATH"
}

mc_cred_mac_present() {
  local target="$1" rc=0 errors
  mc_cred_mac_require_security
  # stderr is captured for the not-found check; stdout holds no diagnostics.
  errors="$(security find-generic-password -s "$target" -a multicli 2>&1 >/dev/null)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    *)
      case "$errors" in
        *"could not be found"*) return 1 ;;
        *) printf '%s\n' "$errors" >&2; return 2 ;;
      esac ;;
  esac
}

mc_cred_mac_set() {
  local target="$1" secret="$2"
  mc_cred_mac_require_security
  # `security` has no stdin secret channel; -U updates an existing item.
  security add-generic-password -s "$target" -a multicli -w "$secret" -U >/dev/null
}

mc_cred_mac_get() {
  local target="$1" rc=0
  mc_cred_mac_require_security
  mc_cred_mac_present "$target" || rc=$?
  case "$rc" in
    0) security find-generic-password -s "$target" -a multicli -w ;;
    1) return 1 ;;
    *) return "$rc" ;;
  esac
}

mc_cred_mac_clear() {
  local target="$1" rc=0
  mc_cred_mac_require_security
  mc_cred_mac_present "$target" || rc=$?
  case "$rc" in
    0) security delete-generic-password -s "$target" -a multicli >/dev/null ;;
    1) return 0 ;;
    *) return "$rc" ;;
  esac
}

# --- linux backend (Secret Service via secret-tool) --------------------------

mc_cred_linux_require_secret_tool() {
  command -v secret-tool >/dev/null 2>&1 || \
    abort "secret-tool is required for linux credential storage but was not found. Install it via: sudo apt install libsecret-tools (Debian/Ubuntu) or your distro's libsecret package"
}

mc_cred_linux_present() {
  local target="$1" rc=0 secret
  mc_cred_linux_require_secret_tool
  secret="$(secret-tool lookup service multicli target "$target" 2>/dev/null)" || rc=$?
  # Secrets are never empty (set rejects them), so empty output means absent.
  [ "$rc" -eq 0 ] && [ -n "$secret" ]
}

mc_cred_linux_set() {
  local target="$1" secret="$2"
  mc_cred_linux_require_secret_tool
  printf '%s' "$secret" | secret-tool store --label="$target" service multicli target "$target"
}

mc_cred_linux_get() {
  local target="$1"
  mc_cred_linux_require_secret_tool
  mc_cred_linux_present "$target" || return 1
  secret-tool lookup service multicli target "$target"
}

mc_cred_linux_clear() {
  local target="$1"
  mc_cred_linux_require_secret_tool
  # Clearing is idempotent; secret-tool clear exits non-zero when nothing
  # matched, so only call it when a secret is actually stored.
  if mc_cred_linux_present "$target"; then
    secret-tool clear service multicli target "$target"
  fi
}

# --- Public API (dispatches on platform) -------------------------------------

mc_cred_set() {
  mc_cred_require_target "${1:-}"
  local target="$1" secret="${2:-}"
  [ -n "$secret" ] || abort "credential secret must not be empty"
  local backend
  backend="$(mc_cred_platform)"
  case "$backend" in
    windows) mc_cred_win_set "$target" "$secret" ;;
    macos)   mc_cred_mac_set "$target" "$secret" ;;
    linux)   mc_cred_linux_set "$target" "$secret" ;;
  esac
}

mc_cred_get() {
  mc_cred_require_target "${1:-}"
  local backend
  backend="$(mc_cred_platform)"
  case "$backend" in
    windows) mc_cred_win_get "$1" ;;
    macos)   mc_cred_mac_get "$1" ;;
    linux)   mc_cred_linux_get "$1" ;;
  esac
}

mc_cred_clear() {
  mc_cred_require_target "${1:-}"
  local backend
  backend="$(mc_cred_platform)"
  case "$backend" in
    windows) mc_cred_win_clear "$1" ;;
    macos)   mc_cred_mac_clear "$1" ;;
    linux)   mc_cred_linux_clear "$1" ;;
  esac
}

mc_cred_present() {
  mc_cred_require_target "${1:-}"
  local backend
  backend="$(mc_cred_platform)"
  case "$backend" in
    windows) mc_cred_win_present "$1" ;;
    macos)   mc_cred_mac_present "$1" ;;
    linux)   mc_cred_linux_present "$1" ;;
  esac
}
