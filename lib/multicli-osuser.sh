#!/usr/bin/env bash
# multicli-osuser.sh -- osUserCredentialStore account mechanism for nini-agents.
#
# Identity derivation (deterministic sandbox usernames) and ownership-record
# checks live here; the privileged Windows work (user provisioning, ACLs,
# scheduled-task launch) is delegated to lib/MultiCli.OsUser.psm1, mirroring
# how lib/credential-store.sh wraps MultiCli.CredentialStore.psm1. macOS and
# Linux fail closed with a precise message -- no sudo half-implementation.
#
# Exported surface (orchestrator wiring):
#   mc_osuser_username <tool> <profileId>        -- derived sandbox username
#   mc_osuser_ensure  <tool> <profile_dir> [adapter.json]  -- provision (new)
#   mc_osuser_launch  <tool> <profile_dir> <binary> [args...]  -- run as user
#   mc_osuser_remove  <profile_dir>              -- profile delete (no-op safe)
#   mc_osuser_is_owned <profile_dir>             -- ownership record present?
#
# Sourced by nini-agents after lib/multicli-runtime.sh; uses the launcher's
# abort and adapter_path like the sibling runtime lib. Pure functions
# (username/task/target derivation) work stand-alone.

set -euo pipefail

# The launcher defines abort(); provide the same shape when the library is
# sourced stand-alone (tests, direct sourcing).
if ! declare -F abort >/dev/null 2>&1; then
  abort() { echo "Error: $1" >&2; exit 1; }
fi

# Canonical platform name, honoring MULTICLI_PLATFORM like the launcher.
mc_osuser_platform() {
  local raw="${MULTICLI_PLATFORM:-$(uname -s 2>/dev/null || echo unknown)}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    darwin|macos|mac|osx)          printf 'macos\n' ;;
    linux)                         printf 'linux\n' ;;
    mingw*|msys*|cygwin*|windows*) printf 'windows\n' ;;
    *) abort "unsupported platform '$raw' for OS-user isolation" ;;
  esac
}

# Lowercase SHA-256 hex of stdin. First available tool wins; the PowerShell
# fallback hashes the same UTF-8 bytes as Get-OsUserIdentityHash, so both
# implementations derive identical usernames.
mc_osuser_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
    return
  fi
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | sed 's/^.* //'
    return
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command '
      $sha = [System.Security.Cryptography.SHA256]::Create()
      try {
        $stream = [Console]::OpenStandardInput()
        $memory = New-Object System.IO.MemoryStream
        $stream.CopyTo($memory)
        $hash = $sha.ComputeHash($memory.ToArray())
        [Console]::Out.Write(([BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant())
      } finally { $sha.Dispose() }
    ' | tr -d '\r\n'
    return
  fi
  abort "no SHA-256 tool available (need sha256sum, shasum, openssl, or powershell.exe)"
}

# Sandbox username: mcli_ + first 12 hex of SHA256("<tool>:<profileId>").
# 17 chars, within the 20-char Windows SAM account limit; deterministic, and
# collision-safe across tools because the tool id is part of the hash input.
mc_osuser_username() {
  local tool="${1:-}" profile_id="${2:-}" hex
  [ -n "$tool" ] || abort "OS-user name derivation requires a tool id. Usage: mc_osuser_username <tool> <profileId>"
  [ -n "$profile_id" ] || abort "OS-user name derivation requires a profileId. Usage: mc_osuser_username <tool> <profileId>"
  tool="$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')"
  hex="$(printf '%s' "$tool:$profile_id" | mc_osuser_sha256)"
  printf 'mcli_%s\n' "${hex:0:12}"
}

# Scheduled-task name for the sandbox user (multi-cli-<hash suffix>).
mc_osuser_task_name() {
  local username="${1:-}"
  [ -n "$username" ] || abort "OS-user task name requires a username. Usage: mc_osuser_task_name <username>"
  printf 'multi-cli-%s\n' "${username#mcli_}"
}

# Credential Manager target holding the sandbox user's password.
mc_osuser_cred_target() {
  local username="${1:-}"
  [ -n "$username" ] || abort "OS-user credential target requires a username. Usage: mc_osuser_cred_target <username>"
  printf 'multi-cli/osuser/%s\n' "$username"
}

mc_osuser_require_command() {
  local name="$1" plat="$2" package_hint="$3"
  command -v "$name" >/dev/null 2>&1 || abort "OS-user isolation on $plat requires '$name'. Install $package_hint, then retry."
}

mc_osuser_require_windows() {
  [ "$(mc_osuser_platform)" = windows ] || abort "Windows OS-user delegation was called on a non-Windows platform"
}

mc_osuser_profile_id() {
  local metadata="$1/.profile.json"
  [ -f "$metadata" ] || return 1
  jq -r '.profileId // empty' "$metadata" 2>/dev/null
}

mc_osuser_posix_home() {
  printf '%s/_home\n' "$1"
}

mc_osuser_posix_user_exists() {
  local username="$1"
  case "$(mc_osuser_platform)" in
    macos) dscl . -read "/Users/$username" >/dev/null 2>&1 ;;
    linux) id "$username" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

mc_osuser_posix_create_macos() {
  local username="$1" home_dir="$2" tool="$3" max_uid generated_uid
  max_uid="$(dscl . -list /Users UniqueID | awk '$2 >= 501 && $2 < 60000 { print $2 }' | sort -n | tail -1)"
  [[ "$max_uid" =~ ^[0-9]+$ ]] || abort "Could not determine a free macOS user id for '$username'."
  generated_uid="$(uuidgen)"
  if ! {
    sudo dscl . -create "/Users/$username" &&
    sudo dscl . -create "/Users/$username" UniqueID "$((max_uid + 1))" &&
    sudo dscl . -create "/Users/$username" GeneratedUID "$generated_uid" &&
    sudo dscl . -create "/Users/$username" PrimaryGroupID 20 &&
    sudo dscl . -create "/Users/$username" UserShell /usr/bin/false &&
    sudo dscl . -create "/Users/$username" NFSHomeDirectory "$home_dir" &&
    sudo dscl . -create "/Users/$username" IsHidden 1 &&
    sudo dscl . -create "/Users/$username" RealName "multi-cli sandbox $tool"
  }; then
    sudo dscl . -delete "/Users/$username" >/dev/null 2>&1 || true
    abort "Could not create macOS OS user '$username'."
  fi
}

mc_osuser_posix_create_linux() {
  local username="$1" home_dir="$2"
  sudo useradd --system --user-group --no-create-home --home-dir "$home_dir" \
    --shell /usr/sbin/nologin "$username" || abort "Could not create Linux OS user '$username'."
}

mc_osuser_posix_write_record() {
  local profile_dir="$1" tool="$2" profile_id="$3" username="$4" tmp
  tmp="$profile_dir/.osuser.json.tmp"
  jq -n --arg tool "$tool" --arg profile_id "$profile_id" \
    --arg username "$username" --arg platform "$(mc_osuser_platform)" \
    --arg created_utc "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '{schemaVersion:1,tool:$tool,profileId:$profile_id,username:$username,platform:$platform,taskName:"",credentialTarget:"",createdUtc:$created_utc}' > "$tmp" &&
    mv -f "$tmp" "$profile_dir/.osuser.json"
}

mc_osuser_posix_create() {
  local tool="$1" profile_dir="$2" profile_id="$3" username="$4" plat home_dir
  plat="$(mc_osuser_platform)"
  home_dir="$(mc_osuser_posix_home "$profile_dir")"
  mc_osuser_require_command sudo "$plat" sudo
  mkdir -p "$home_dir"
  case "$plat" in
    macos)
      mc_osuser_require_command dscl "$plat" 'the macOS directory tools'
      mc_osuser_require_command uuidgen "$plat" 'the macOS system tools'
      mc_osuser_posix_create_macos "$username" "$home_dir" "$tool"
      if ! sudo chown -R "$username":staff "$home_dir"; then
        mc_osuser_posix_delete_user "$username" || true
        abort "Could not assign '$home_dir' to macOS OS user '$username'; the user was rolled back."
      fi
      ;;
    linux)
      mc_osuser_require_command useradd "$plat" 'the shadow/user-management package'
      mc_osuser_posix_create_linux "$username" "$home_dir"
      if ! sudo chown -R "$username":"$username" "$home_dir"; then
        mc_osuser_posix_delete_user "$username" || true
        abort "Could not assign '$home_dir' to Linux OS user '$username'; the user was rolled back."
      fi
      ;;
  esac
  if ! mc_osuser_posix_write_record "$profile_dir" "$tool" "$profile_id" "$username"; then
    mc_osuser_posix_delete_user "$username" || true
    abort "Could not record ownership for OS user '$username'; the user was rolled back."
  fi
}

mc_osuser_posix_root() {
  local manifest="$1" home_dir="$2" pattern
  pattern="$(jq -r --arg platform "$(mc_osuser_platform)" '.normalState.root[$platform] // empty' "$manifest")"
  [ -n "$pattern" ] || abort "Adapter '$(jq -r '.id' "$manifest")' has no normal-state root for $(mc_osuser_platform)."
  printf '%s\n' "${pattern//\$HOME/$home_dir}"
}

mc_osuser_posix_is_file() {
  jq -e --arg path "$2" '(.normalState.filePaths // []) | index($path) != null' "$1" >/dev/null
}

mc_osuser_posix_acl_entry() {
  printf '%s allow read,write,execute,delete,append,list,search,add_file,add_subdirectory,delete_child,readattr,writeattr,readextattr,writeextattr,readsecurity,file_inherit,directory_inherit\n' "$1"
}

mc_osuser_posix_grant_shared_root() {
  local root="$1" username="$2" plat parent
  plat="$(mc_osuser_platform)"
  case "$plat" in
    macos)
      sudo chmod -R +a "$(mc_osuser_posix_acl_entry "$username")" "$root"
      parent="$(dirname "$root")"
      while [ "$parent" != / ]; do sudo chmod +a "$username allow search" "$parent"; parent="$(dirname "$parent")"; done
      ;;
    linux)
      mc_osuser_require_command setfacl "$plat" 'the acl package'
      sudo setfacl -R -m "u:$username:rwx" "$root"
      sudo find "$root" -type d -exec setfacl -m "d:u:$username:rwx" {} +
      parent="$(dirname "$root")"
      while [ "$parent" != / ]; do sudo setfacl -m "u:$username:--x" "$parent"; parent="$(dirname "$parent")"; done
      ;;
  esac
}

mc_osuser_posix_state_links() {
  local profile_dir="$1" manifest="$2" username="$3" shared_root sandbox_root relative source destination
  shared_root="$(runtime_platform_root "$manifest")"
  sandbox_root="$(mc_osuser_posix_root "$manifest" "$(mc_osuser_posix_home "$profile_dir")")"
  # The sandbox must be able to traverse every profile ancestor before it can
  # create normal-state parents below its owned home.
  mc_osuser_posix_grant_shared_root "$(mc_osuser_posix_home "$profile_dir")" "$username"
  mkdir -p "$shared_root"
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    source="$shared_root/$relative"
    destination="$sandbox_root/$relative"
    if mc_osuser_posix_is_file "$manifest" "$relative"; then
      mkdir -p "$(dirname "$source")"
      [ -e "$source" ] || : > "$source"
    else
      mkdir -p "$source"
    fi
    sudo -u "$username" mkdir -p "$(dirname "$destination")"
    [ -e "$destination" ] || sudo -u "$username" ln -s "$source" "$destination"
  done < <(jq -r '.normalState.sharedPaths[]?, .normalState.sessionPaths[]? // empty' "$manifest")
  if jq -e '((.normalState.sharedPaths // []) + (.normalState.sessionPaths // [])) | length > 0' "$manifest" >/dev/null; then
    mc_osuser_posix_grant_shared_root "$shared_root" "$username"
  fi
}

mc_osuser_macos_prepare_keychain() {
  local username="$1" home_dir="$2" keychain="$home_dir/Library/Keychains/login.keychain-db"
  sudo -u "$username" mkdir -p "$(dirname "$keychain")"
  if [ ! -f "$keychain" ]; then
    sudo -H -u "$username" env HOME="$home_dir" security create-keychain -p '' "$keychain"
  fi
  sudo -H -u "$username" env HOME="$home_dir" security list-keychains -d user -s "$keychain"
  sudo -H -u "$username" env HOME="$home_dir" security default-keychain -d user -s "$keychain"
  sudo -H -u "$username" env HOME="$home_dir" security unlock-keychain -p '' "$keychain"
}

mc_osuser_posix_launch() {
  local profile_dir="$1" binary="$2" manifest="$3" username="$4"; shift 4
  local home_dir profile_id mode key value env_args=() unset_args=()
  home_dir="$(mc_osuser_posix_home "$profile_dir")"
  profile_id="$(mc_osuser_profile_id "$profile_dir")"
  mode="$(runtime_json_str '.isolation.mode' "$manifest")"
  mc_osuser_posix_state_links "$profile_dir" "$manifest" "$username"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    value="$(json_obj_val '.isolation.env' "$key" "$manifest")"
    env_args+=("$key=$(runtime_expand_value "$value" "$profile_dir" "$profile_id" "$profile_dir/auth" "$home_dir" "$(runtime_platform_root "$manifest")")")
  done < <(json_obj_keys '.isolation.env' "$manifest")
  while IFS= read -r key; do [ -n "$key" ] && unset_args+=("-u" "$key"); done < <(runtime_json_arr '.isolation.clearEnv' "$manifest")
  env_args+=("HOME=$home_dir" "TMPDIR=$home_dir/.tmp" "XDG_CONFIG_HOME=$home_dir/.config" "XDG_DATA_HOME=$home_dir/.local/share" "XDG_CACHE_HOME=$home_dir/.cache" "MULTICLI_PROFILE_ID=$profile_id")
  sudo -u "$username" mkdir -p "$home_dir/.tmp" "$home_dir/.config" "$home_dir/.local/share" "$home_dir/.cache"
  [ "$(mc_osuser_platform)" != macos ] || mc_osuser_macos_prepare_keychain "$username" "$home_dir"
  if [ "$mode" = detached ]; then
    sudo -H -u "$username" env "${unset_args[@]+${unset_args[@]}}" "${env_args[@]}" "$binary" "$@" > "$profile_dir/.osuser-launch.log" 2>&1 &
    return 0
  fi
  sudo -H -u "$username" env "${unset_args[@]+${unset_args[@]}}" "${env_args[@]}" "$binary" "$@"
}

mc_osuser_posix_delete_user() {
  local username="$1" plat
  plat="$(mc_osuser_platform)"
  case "$plat" in
    macos)
      mc_osuser_require_command dscl "$plat" 'the macOS directory tools'
      sudo dscl . -delete "/Users/$username" || abort "Could not delete macOS OS user '$username'."
      ;;
    linux)
      mc_osuser_require_command userdel "$plat" 'the shadow/user-management package'
      sudo userdel "$username" || abort "Could not delete Linux OS user '$username'."
      ;;
  esac
}

# --- Ownership record (<profile_dir>/.osuser.json) ---------------------------

# True when the profile carries an ownership record.
mc_osuser_is_owned() {
  local profile_dir="${1:-}"
  [ -n "$profile_dir" ] || abort "Usage: mc_osuser_is_owned <profile_dir>"
  [ -f "$profile_dir/.osuser.json" ]
}

# One field from the ownership record; exit 1 (no output) when absent.
mc_osuser_ownership_field() {
  local profile_dir="${1:-}" field="${2:-}" record
  [ -n "$profile_dir" ] && [ -n "$field" ] || abort "Usage: mc_osuser_ownership_field <profile_dir> <jq-path>"
  record="$profile_dir/.osuser.json"
  [ -f "$record" ] || return 1
  command -v jq >/dev/null 2>&1 || abort "jq is required to read OS-user ownership records"
  jq -r "$field // empty" "$record" 2>/dev/null | tr -d '\r'
}

# Prove the record matches the derived identity before anything touches the
# user; aborts on foreign records. Runs before elevation/PS delegation on
# purpose: a fabricated record is rejected on any host.
mc_osuser_assert_ownership() {
  local profile_dir="${1:-}" metadata tool profile_id username task_name credential_target expected expected_task expected_credential
  [ -n "$profile_dir" ] || abort "Usage: mc_osuser_assert_ownership <profile_dir>"
  metadata="$profile_dir/.profile.json"
  tool="$(mc_osuser_ownership_field "$profile_dir" '.tool')" || return 1
  profile_id="$(mc_osuser_ownership_field "$profile_dir" '.profileId')"
  username="$(mc_osuser_ownership_field "$profile_dir" '.username')"
  [ -f "$metadata" ] || abort "Refusing to touch OS user '$username': '$profile_dir' is missing schema-v2 profile metadata."
  [ "$tool" = "$(jq -r '.adapterId // empty' "$metadata")" ] && \
    [ "$profile_id" = "$(jq -r '.profileId // empty' "$metadata")" ] || \
    abort "Refusing to touch OS user '$username': the ownership record in '$profile_dir' belongs to another profile."
  expected="$(mc_osuser_username "$tool" "$profile_id")"
  task_name="$(mc_osuser_ownership_field "$profile_dir" '.taskName')"
  credential_target="$(mc_osuser_ownership_field "$profile_dir" '.credentialTarget')"
  expected_task="$(mc_osuser_task_name "$expected")"
  expected_credential="$(mc_osuser_cred_target "$expected")"
  if [ "$username" != "$expected" ] || \
    { [ -n "$task_name" ] && [ "$task_name" != "$expected_task" ]; } || \
    { [ -n "$credential_target" ] && [ "$credential_target" != "$expected_credential" ]; }; then
    abort "Refusing to touch OS user '$username': the ownership record in '$profile_dir' does not match the derived identity '$expected'; the user is not multi-cli-owned."
  fi
}

# --- Windows delegation (MultiCli.OsUser.psm1) --------------------------------

# PowerShell wrapper: imports the module and runs one operation. Paths travel
# in the environment (Windows form); binary args travel base64-encoded, one
# per line, so quoting/space edge cases never reach a command line. The
# Resolve-PathToken shim mirrors the launcher's contract for the module.
# Exit codes: 0 ok, otherwise the launch's own exit code; 2 = error.
MC_OSUSER_PS_WRAPPER="$(cat <<'PS'
$ErrorActionPreference = "Stop"
Import-Module $env:MC_OSUSER_MODULE -Force
if (-not (Get-Command Get-OsUserName -ErrorAction SilentlyContinue)) {
  throw "failed to load MultiCli.OsUser.psm1"
}
if (-not (Get-Command Resolve-PathToken -ErrorAction SilentlyContinue)) {
  function global:Resolve-PathToken([string]$Path) {
    if (-not $Path) { return $Path }
    $expanded = $Path -replace '\$HOME', $env:USERPROFILE.Replace('\', '\\')
    return [Environment]::ExpandEnvironmentVariables($expanded)
  }
}
$binaryArgs = @()
if ($env:MC_OSUSER_ARGS_B64) {
  foreach ($line in ($env:MC_OSUSER_ARGS_B64 -split "\r?\n")) {
    if ($line) { $binaryArgs += [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($line)) }
  }
}
try {
  switch ($env:MC_OSUSER_OP) {
    "ensure" {
      $adapter = Get-Content -LiteralPath $env:MC_OSUSER_ADAPTER -Raw | ConvertFrom-Json
      Initialize-OsUserIsolation -Adapter $adapter -ProfileDir $env:MC_OSUSER_PROFILE_DIR | Out-Null
      exit 0
    }
    "remove" {
      Remove-OsUserIsolation -ProfileDir $env:MC_OSUSER_PROFILE_DIR | Out-Null
      exit 0
    }
    "launch" {
      $adapter = Get-Content -LiteralPath $env:MC_OSUSER_ADAPTER -Raw | ConvertFrom-Json
      $exitCode = Invoke-OsUserLaunch -Adapter $adapter -ProfileDir $env:MC_OSUSER_PROFILE_DIR -Binary $env:MC_OSUSER_BINARY -BinaryArgs $binaryArgs
      exit $exitCode
    }
    default { exit 2 }
  }
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 2
}
PS
)"

# Invoke the PowerShell wrapper. $1 = operation; callers set the MC_OSUSER_*
# inputs via the environment. Returns the wrapper's exit code verbatim.
mc_osuser_ps_invoke() {
  local op="$1"
  command -v powershell.exe >/dev/null 2>&1 || \
    abort "powershell.exe not found on PATH; OS-user isolation on Windows requires Windows PowerShell 5.1+"
  command -v cygpath >/dev/null 2>&1 || \
    abort "cygpath not found; OS-user isolation on Windows requires Git Bash/MSYS2"
  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  MSYS2_ARG_CONV_EXCL='*' \
  MC_OSUSER_MODULE="$(cygpath -w "$lib_dir/MultiCli.OsUser.psm1")" \
  MC_OSUSER_OP="$op" \
  MC_OSUSER_ADAPTER="${MC_OSUSER_ADAPTER:-}" \
  MC_OSUSER_PROFILE_DIR="${MC_OSUSER_PROFILE_DIR:-}" \
  MC_OSUSER_BINARY="${MC_OSUSER_BINARY:-}" \
  MC_OSUSER_ARGS_B64="${MC_OSUSER_ARGS_B64:-}" \
    powershell.exe -NoProfile -Command "$MC_OSUSER_PS_WRAPPER"
}

# Resolve the adapter manifest for a tool: explicit path ($2) wins, otherwise
# the launcher's adapter_path. Prints the path or aborts.
mc_osuser_adapter_path() {
  local tool="$1" explicit="${2:-}" caller="$3"
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return
  fi
  declare -F adapter_path >/dev/null 2>&1 || \
    abort "mc_osuser_$caller requires the nini-agents launcher (adapter_path) or an explicit adapter path"
  adapter_path "$tool"
}

# Provision the sandbox user for a profile (profile creation hook).
mc_osuser_ensure() {
  local tool="${1:-}" profile_dir="${2:-}" adapter="${3:-}" platform profile_id username recorded
  [ -n "$tool" ] && [ -n "$profile_dir" ] || abort "Usage: mc_osuser_ensure <tool> <profile_dir> [adapter.json]"
  adapter="$(mc_osuser_adapter_path "$tool" "$adapter" ensure)" || exit 1
  [ -f "$adapter" ] || abort "Unknown tool '$tool'. Run: nini-agents tools"
  platform="$(mc_osuser_platform)"
  if [ "$platform" = windows ]; then
    MC_OSUSER_ADAPTER="$(cygpath -w "$adapter")" \
    MC_OSUSER_PROFILE_DIR="$(cygpath -w "$profile_dir")" \
      mc_osuser_ps_invoke ensure
    return
  fi
  profile_id="$(mc_osuser_profile_id "$profile_dir")"
  [ -n "$profile_id" ] || abort "Profile '$tool/$(basename "$profile_dir")' is missing schema-v2 metadata."
  username="$(mc_osuser_username "$tool" "$profile_id")"
  if mc_osuser_posix_user_exists "$username"; then
    recorded="$(mc_osuser_ownership_field "$profile_dir" '.username' 2>/dev/null || true)"
    [ "$recorded" = "$username" ] || abort "OS user '$username' already exists but is not recorded as multi-cli-owned in '$profile_dir'; refusing to touch it."
    return 0
  fi
  mc_osuser_posix_create "$tool" "$profile_dir" "$profile_id" "$username"
}

# Run $binary as the profile's sandbox user (launch hook). Returns the
# child's exit code for foreground adapters, or 0 after a detached start.
mc_osuser_launch() {
  local tool="${1:-}" profile_dir="${2:-}" binary="${3:-}" platform adapter username
  [ -n "$tool" ] && [ -n "$profile_dir" ] && [ -n "$binary" ] || \
    abort "Usage: mc_osuser_launch <tool> <profile_dir> <binary> [args...]"
  shift 3
  adapter="${MC_OSUSER_ADAPTER_PATH:-}"
  adapter="$(mc_osuser_adapter_path "$tool" "$adapter" launch)" || exit 1
  [ -f "$adapter" ] || abort "Unknown tool '$tool'. Run: nini-agents tools"
  platform="$(mc_osuser_platform)"
  if [ "$platform" != windows ]; then
    username="$(mc_osuser_ownership_field "$profile_dir" '.username')" || abort "Profile '$tool/$(basename "$profile_dir")' has no OS-user ownership record."
    mc_osuser_assert_ownership "$profile_dir"
    mc_osuser_posix_launch "$profile_dir" "$binary" "$adapter" "$username" "$@"
    return
  fi
  case "$binary" in /*) binary="$(cygpath -w "$binary")" ;; esac
  local args_b64="" arg
  for arg in "$@"; do
    args_b64+="$(printf '%s' "$arg" | base64 -w0)"$'\n'
  done
  MC_OSUSER_ADAPTER="$(cygpath -w "$adapter")" \
  MC_OSUSER_PROFILE_DIR="$(cygpath -w "$profile_dir")" \
  MC_OSUSER_BINARY="$binary" \
  MC_OSUSER_ARGS_B64="$args_b64" \
    mc_osuser_ps_invoke launch
}

# Remove everything multi-cli owns for the profile (profile delete hook).
mc_osuser_remove() {
  local profile_dir="${1:-}" platform username
  [ -n "$profile_dir" ] || abort "Usage: mc_osuser_remove <profile_dir>"
  mc_osuser_is_owned "$profile_dir" || return 0
  mc_osuser_assert_ownership "$profile_dir"
  platform="$(mc_osuser_platform)"
  if [ "$platform" = windows ]; then
    MC_OSUSER_PROFILE_DIR="$(cygpath -w "$profile_dir")" mc_osuser_ps_invoke remove
    return
  fi
  username="$(mc_osuser_ownership_field "$profile_dir" '.username')"
  if mc_osuser_posix_user_exists "$username"; then
    sudo chown -R "$(id -u):$(id -g)" "$profile_dir"
    mc_osuser_posix_delete_user "$username"
  fi
  rm -f "$profile_dir/.osuser.json"
}
