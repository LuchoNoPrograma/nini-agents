#!/usr/bin/env bash
# multicli-runtime.sh -- schema-v2 accountOverlay runtime for nini-agents.
#
# Builds the per-profile runtime view: declared credential files stay
# profile-local under <profile>/auth, declared shared/session state is linked
# from the adapter's native root, and the launch environment is expanded from
# adapter placeholders. Sourced by nini-agents after lib/adapter-validation.sh;
# relies on the launcher's abort/platform/resolve_path_token and the jq
# helpers below.

# jq helpers. The trailing `|| true` is load-bearing: the launcher runs with
# `set -euo pipefail`, so a jq failure (e.g. a missing .profile.json) would
# otherwise fail the caller's assignment and kill the shell silently instead
# of reaching the guard that prints an actionable message.
runtime_json_str() {
  jq -r "$1 // empty" "$2" 2>/dev/null | tr -d '\r' || true
}

runtime_json_arr() {
  jq -r "$1 // [] | .[]?" "$2" 2>/dev/null | tr -d '\r' || true
}

# Absolute native shared-state root for the current platform, tokens expanded.
runtime_platform_root() {
  local manifest="$1" key root
  key="$(platform)"
  root="$(runtime_json_str ".normalState.root.$key" "$manifest")"
  resolve_path_token "$root"
}

# Stable per-profile identity written at profile creation; empty when the
# profile predates schema-v2.
runtime_profile_id() {
  local profile_dir="$1"
  runtime_json_str '.profileId' "$profile_dir/.profile.json"
}

# Random UUID using the best source the host offers (uuidgen, /proc,
# PowerShell, /dev/urandom last).
runtime_new_profile_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return
  fi
  if [ -r /proc/sys/kernel/random/uuid ]; then
    tr -d '\r\n' < /proc/sys/kernel/random/uuid
    return
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command '[guid]::NewGuid().ToString()' 2>/dev/null | tr -d '\r\n'
    return
  fi
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/'
}

# Write .profile.json atomically (temp + rename) with a fresh profileId.
runtime_write_profile_metadata() {
  local manifest="$1" profile_dir="$2" profile_id tmp
  profile_id="$(runtime_new_profile_id)"
  tmp="$profile_dir/.profile.json.tmp"
  jq -n \
    --arg adapter_id "$(runtime_json_str '.id' "$manifest")" \
    --arg profile_id "$profile_id" \
    '{schemaVersion:2,adapterId:$adapter_id,profileId:$profile_id,mode:"accountOverlay"}' > "$tmp"
  mv -f "$tmp" "$profile_dir/.profile.json"
}

# Create the schema-v2 skeleton: empty profile-local placeholder files for
# every declared credential, plus fresh metadata. Existing content is kept.
runtime_initialize_profile() {
  local manifest="$1" profile_dir="$2" relative credential_path
  mkdir -p "$profile_dir/auth"
  while IFS= read -r relative; do
    [ -z "$relative" ] && continue
    credential_path="$profile_dir/auth/$relative"
    mkdir -p "$(dirname "$credential_path")"
    [ -e "$credential_path" ] || : > "$credential_path"
  done < <(runtime_json_arr '.account.credentialFiles' "$manifest")
  runtime_write_profile_metadata "$manifest" "$profile_dir"
}

# True when the adapter declares $2 as a file (not a directory) in
# normalState.filePaths.
runtime_is_file_path() {
  local manifest="$1" relative="$2" declared
  while IFS= read -r declared; do
    [ "$declared" = "$relative" ] && return 0
  done < <(runtime_json_arr '.normalState.filePaths' "$manifest")
  return 1
}

# Create the shared-root source for a declared path when missing: a file for
# declared file paths, a directory otherwise.
runtime_ensure_state_source() {
  local manifest="$1" shared_root="$2" relative="$3" source parent
  source="$shared_root/$relative"
  parent="$(dirname "$source")"
  mkdir -p "$parent"
  if [ -e "$source" ]; then return; fi
  if runtime_is_file_path "$manifest" "$relative"; then
    : > "$source"
  else
    mkdir -p "$source"
  fi
}

runtime_is_windows_shell() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*|Windows*) return 0 ;;
    *) return 1 ;;
  esac
}

# Link one path into the overlay: symlink on POSIX, junction (directories) or
# hardlink (files) on Windows. No copy fallback: a copied credential or state
# file would silently diverge from the shared root, so failure aborts.
runtime_link_path() {
  local source="$1" destination="$2" label="$3" parent source_win destination_win
  parent="$(dirname "$destination")"
  mkdir -p "$parent"
  if ! runtime_is_windows_shell; then
    ln -s "$source" "$destination" 2>/dev/null || abort "Cannot link $label '$destination' to '$source'. Link support is required; no copy fallback is allowed."
    return
  fi

  source_win="$(cygpath -w "$source")"
  destination_win="$(cygpath -w "$destination")"
  if [ -d "$source" ]; then
    powershell.exe -NoProfile -Command "New-Item -ItemType Junction -Path '$destination_win' -Target '$source_win' | Out-Null" >/dev/null 2>&1 || \
      abort "Cannot create directory junction for $label '$destination'."
    return
  fi
  powershell.exe -NoProfile -Command "New-Item -ItemType HardLink -Path '$destination_win' -Target '$source_win' | Out-Null" >/dev/null 2>&1 || \
    abort "Cannot create file link for $label '$destination'. Both paths must be on one volume."
}

runtime_remove_overlay() {
  local manifest="$1" runtime_root="$2"
  [ -e "$runtime_root" ] || return 0
  # Remove every link (POSIX symlink, MSYS junction/hardlink dir) without
  # traversing it before recursing; rm -rf must never cross into shared state.
  find "$runtime_root" -mindepth 1 -type l -delete 2>/dev/null || true
  rm -rf "$runtime_root"
}

# Link every entry of the jq array at $4 from the shared root into the staging
# tree, creating missing sources first.
runtime_link_state_list() {
  local manifest="$1" shared_root="$2" staging="$3" jq_path="$4" relative
  while IFS= read -r relative; do
    [ -z "$relative" ] && continue
    runtime_ensure_state_source "$manifest" "$shared_root" "$relative"
    runtime_link_path "$shared_root/$relative" "$staging/$relative" "shared state"
  done < <(runtime_json_arr "$jq_path" "$manifest")
}

# Link the profile's own auth/<rel> files into the staging tree -- the only
# overlay entries that are profile-local.
runtime_link_credentials() {
  local manifest="$1" profile_dir="$2" staging="$3" relative auth_path
  while IFS= read -r relative; do
    [ -z "$relative" ] && continue
    auth_path="$profile_dir/auth/$relative"
    mkdir -p "$(dirname "$auth_path")"
    [ -e "$auth_path" ] || : > "$auth_path"
    runtime_link_path "$auth_path" "$staging/$relative" "profile credential"
  done < <(runtime_json_arr '.account.credentialFiles' "$manifest")
}

runtime_expected_manifest() {
  local manifest="$1" state_subdir
  state_subdir="$(runtime_json_str '.normalState.runtimeSubdir' "$manifest")"
  if [ -n "$state_subdir" ]; then
    runtime_json_arr '.normalState.sharedPaths' "$manifest" | sed "s|^|$state_subdir/|"
    runtime_json_arr '.normalState.sessionPaths' "$manifest" | sed "s|^|$state_subdir/|"
    runtime_json_arr '.account.credentialFiles' "$manifest" | sed "s|^|$state_subdir/|"
    return
  fi
  runtime_json_arr '.normalState.sharedPaths' "$manifest"
  runtime_json_arr '.normalState.sessionPaths' "$manifest"
  runtime_json_arr '.account.credentialFiles' "$manifest"
}

runtime_overlay_is_current() {
  local manifest="$1" runtime_root="$2" expected actual relative declared expected_source
  local profile_dir shared_root state_subdir credential credential_path
  [ -f "$runtime_root/.runtime-manifest" ] || return 1
  expected="$(runtime_expected_manifest "$manifest")"
  actual="$(tr -d '\r' < "$runtime_root/.runtime-manifest")"
  [ "$actual" = "$expected" ] || return 1
  profile_dir="$(dirname "$runtime_root")"
  shared_root="$(runtime_platform_root "$manifest")"
  state_subdir="$(runtime_json_str '.normalState.runtimeSubdir' "$manifest")"
  while IFS= read -r relative; do
    [ -z "$relative" ] && continue
    [ -e "$runtime_root/$relative" ] || [ -L "$runtime_root/$relative" ] || return 1
    declared="$relative"
    [ -z "$state_subdir" ] || declared="${relative#${state_subdir}/}"
    credential=false
    while IFS= read -r credential_path; do
      [ "$credential_path" = "$declared" ] && credential=true && break
    done < <(runtime_json_arr '.account.credentialFiles' "$manifest")
    if [ "$credential" = true ]; then
      expected_source="$profile_dir/auth/$declared"
    else
      expected_source="$shared_root/$declared"
    fi
    [ -e "$expected_source" ] || [ -L "$expected_source" ] || return 1
    [ "$runtime_root/$relative" -ef "$expected_source" ] || return 1
  done <<< "$expected"
}

# Serialize builds across processes. A current overlay is reused so launching a
# second process never removes the runtime tree from beneath the first.
runtime_build_overlay() {
  local manifest="$1" profile_dir="$2" lock_dir owner attempts=0
  lock_dir="$profile_dir/.runtime.lock"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    [ ! -L "$lock_dir" ] || abort "Refusing to build overlay: '$lock_dir' is a symlink."
    owner="$(tr -dc '0-9' < "$lock_dir/pid" 2>/dev/null || true)"
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$lock_dir/pid" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
      continue
    fi
    attempts=$((attempts + 1))
    [ "$attempts" -lt 600 ] || abort "Timed out waiting for profile runtime lock '$lock_dir'. Close a stuck nini-agents launch and retry."
    sleep 0.05
  done
  printf '%s\n' "${BASHPID:-$$}" > "$lock_dir/pid"
  (
    trap 'rm -f "$lock_dir/pid" 2>/dev/null || true; rmdir "$lock_dir" 2>/dev/null || true' EXIT
    runtime_build_overlay_locked "$manifest" "$profile_dir"
  )
}

# Build in a PID-unique staging dir and swap it into place while holding the
# profile runtime lock. Staging leftovers can therefore never belong to a live
# builder.
runtime_build_overlay_locked() {
  local manifest="$1" profile_dir="$2" shared_root runtime_root staging state_subdir link_root
  shared_root="$(runtime_platform_root "$manifest")"
  [ -n "$shared_root" ] || abort "Adapter '$TOOL' has no normal-state root for $(platform)."
  mkdir -p "$shared_root"
  runtime_root="$profile_dir/.runtime"
  if runtime_overlay_is_current "$manifest" "$runtime_root"; then
    printf '%s\n' "$runtime_root"
    return
  fi
  state_subdir="$(runtime_json_str '.normalState.runtimeSubdir' "$manifest")"
  staging="$profile_dir/.runtime.staging.${BASHPID:-$$}"
  link_root="$staging"
  [ -n "$state_subdir" ] && link_root="$staging/$state_subdir"
  local stale
  for stale in "$profile_dir"/.runtime.staging.*; do
    [ -e "$stale" ] || continue
    [ "$stale" = "$staging" ] && continue
    find "$stale" -mindepth 1 -type l -delete 2>/dev/null || true
    rm -rf "$stale"
  done
  [ ! -L "$staging" ] || abort "Refusing to build overlay: '$staging' is a symlink."
  rm -rf "$staging"
  [ ! -e "$staging" ] || abort "Refusing to build overlay: '$staging' already exists."
  mkdir -p "$link_root"
  runtime_link_state_list "$manifest" "$shared_root" "$link_root" '.normalState.sharedPaths'
  runtime_link_state_list "$manifest" "$shared_root" "$link_root" '.normalState.sessionPaths'
  runtime_link_credentials "$manifest" "$profile_dir" "$link_root"
  runtime_expected_manifest "$manifest" > "$staging/.runtime-manifest"
  runtime_remove_overlay "$manifest" "$runtime_root"
  mv "$staging" "$runtime_root"
  printf '%s\n' "$runtime_root"
}

# Expand the six adapter placeholders against the concrete launch-time paths.
runtime_expand_value() {
  local value="$1" profile_dir="$2" profile_id="$3" auth_dir="$4" runtime_root="$5" shared_root="$6"
  value="${value//\{profileDir\}/$profile_dir}"
  value="${value//\{profileId\}/$profile_id}"
  value="${value//\{authDir\}/$auth_dir}"
  value="${value//\{runtimeRoot\}/$runtime_root}"
  value="${value//\{sharedStateRoot\}/$shared_root}"
  value="${value//\{realHome\}/$HOME}"
  printf '%s\n' "$value"
}

# Launch $binary with the adapter's isolation environment. fileOverlay builds
# a per-profile runtime view; processSecret reads the profile's secret from
# the OS credential store and injects it into the child environment only
# (fail-closed until `nini-agents auth set`); osUserCredentialStore and
# inseparable refuse to launch by design. Extra binary args follow $@.
runtime_launch_account_overlay() {
  local tool="$1" profile_dir="$2" binary="$3"; shift 3
  local manifest profile_id auth_dir runtime_root shared_root mechanism key value
  local env_args=()
  local unset_args=()
  manifest="$(adapter_path "$tool")"
  mechanism="$(runtime_json_str '.account.mechanism' "$manifest")"
  profile_id="$(runtime_profile_id "$profile_dir")"
  [ -n "$profile_id" ] || abort "Profile '$tool/$(basename "$profile_dir")' is missing schema-v2 metadata."
  local process_secret="" secret_env_var=""
  case "$mechanism" in
    fileOverlay) ;;
    processSecret)
      secret_env_var="$(runtime_json_str '.account.secret.environmentVariable' "$manifest")"
      [ -n "$secret_env_var" ] || abort "Adapter '$tool' is missing account.secret.environmentVariable."
      local secret_target
      secret_target="$(mc_cred_target "$tool" "$profile_id" "$secret_env_var")"
      process_secret="$(mc_cred_get "$secret_target")" || \
        abort "Profile '$tool/$(basename "$profile_dir")' has no stored credential. Run: nini-agents auth set $tool/$(basename "$profile_dir")"
      ;;
    osUserCredentialStore)
      mc_osuser_ensure "$tool" "$profile_dir" "$manifest"
      mc_osuser_launch "$tool" "$profile_dir" "$binary" "$@"
      return
      ;;
    inseparable) abort "$(runtime_json_str '.account.reason' "$manifest") Create this profile with --isolated to use a separate whole-root profile." ;;
    *) abort "Unsupported schema-v2 account mechanism '$mechanism'." ;;
  esac
  auth_dir="$profile_dir/auth"
  shared_root="$(runtime_platform_root "$manifest")"
  if [ "$mechanism" = fileOverlay ]; then
    runtime_root="$(runtime_build_overlay "$manifest" "$profile_dir")"
  else
    runtime_root="$shared_root"
  fi

  while IFS= read -r key; do
    [ -z "$key" ] && continue
    value="$(json_obj_val '.isolation.env' "$key" "$manifest")"
    value="$(runtime_expand_value "$value" "$profile_dir" "$profile_id" "$auth_dir" "$runtime_root" "$shared_root")"
    env_args+=("$key=$value")
  done < <(json_obj_keys '.isolation.env' "$manifest")
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    unset_args+=("-u" "$key")
  done < <(runtime_json_arr '.isolation.clearEnv' "$manifest")
  env_args+=("MULTICLI_PROFILE_ID=$profile_id")
  [ -n "$secret_env_var" ] && env_args+=("$secret_env_var=$process_secret")

  env "${unset_args[@]+"${unset_args[@]}"}" "${env_args[@]+"${env_args[@]}"}" "$binary" "$@"
}
