#!/usr/bin/env bash
# Legacy -> schema-v2 migration engine for nini-agents.
#
# Sourced by the nini-agents launcher (which provides abort, adapter_path,
# assert_adapter_valid, split_profile_spec, validate_name, profile_dir,
# platform, file_nlink) after lib/multicli-runtime.sh (which provides
# runtime_json_str, runtime_json_arr, runtime_platform_root,
# runtime_write_profile_metadata).
#
# Entry point for the launcher's dispatch: cmd_migrate.
#
# A legacy profile (a profile directory without .profile.json) is migrated to
# the schema-v2 accountOverlay layout:
#   - declared credential files move into <profile>/auth/<rel>, subpaths kept;
#   - declared shared/session state merges into the adapter's native shared
#     root without overwriting differing content (skip + report, unless
#     --prefer-profile); credential targets are never overwritten;
#   - migrationPreservePaths retain legacy transactional/volatile normal state
#     inactive instead of merging it into an unrelated live state family;
#   - legacy --shared links are recognized and left in place;
#   - entries the adapter does not declare refuse the migration by default;
#     an explicit --preserve-unknown moves those objects into inactive
#     recovery without following or reading them. Overlaps and unsafe
#     declarations always refuse the migration;
#   - every filesystem operation is journaled; handled failures automatically
#     reverse completed moves, while an unprovable rollback preserves evidence
#     and blocks reuse. All credential moves are same-volume renames.

MIGRATION_JOURNAL_NAME=".migration-journal.json"
MIGRATION_LOCK_NAME=".migration.lock"
MIGRATION_ROLLBACK_NAME=".migration-rollback"

# Unit separator: ops carry empty fields, so tab/space IFS collapsing is
# unacceptable here.
MIGRATION_OP_SEP=$'\x1f'

MIGRATION_CREDS=()
MIGRATION_SHARED=()
MIGRATION_SESSION=()
MIGRATION_RUNTIME=()
MIGRATION_PRESERVE=()
MIGRATION_SHARED_CREDENTIALS=()
MIGRATION_SHARED_CREDENTIAL_BACKUP_PATTERN=""
MIGRATION_UNSAFE_DECLS=()
MIGRATION_ENTRIES=()
MIGRATION_UNKNOWN=()
MIGRATION_OVERLAP=()
MIGRATION_UNSAFE=()
MIGRATION_OPS=()
MIGRATION_SHARED_ROOT_CREATED=false
MIGRATION_CREATED_DEST_DIRS=()

# True when pdir is a profile directory without schema-v2 metadata.
migration_is_legacy_profile() {
  local pdir="$1"
  [ -d "$pdir" ] && [ ! -e "$pdir/.profile.json" ]
}

# =============================================================================
# Classification
# =============================================================================

# Load the adapter's credential/shared/session/unsafe declarations into the
# MIGRATION_* arrays, separators normalized to '/'.
migration_load_declarations() {
  local manifest="$1" p
  MIGRATION_CREDS=(); MIGRATION_SHARED=(); MIGRATION_SESSION=(); MIGRATION_RUNTIME=(); MIGRATION_PRESERVE=(); MIGRATION_SHARED_CREDENTIALS=(); MIGRATION_UNSAFE_DECLS=()
  MIGRATION_SHARED_CREDENTIAL_BACKUP_PATTERN="$(runtime_json_str '.sharedCredentialState.legacyBackupPattern' "$manifest")"
  while IFS= read -r p; do
    [ -n "$p" ] && MIGRATION_CREDS+=("${p//\\//}")
  done < <(runtime_json_arr '.account.credentialFiles' "$manifest")
  while IFS= read -r p; do
    [ -n "$p" ] && MIGRATION_SHARED+=("${p//\\//}")
  done < <(runtime_json_arr '.normalState.sharedPaths' "$manifest")
  while IFS= read -r p; do
    [ -n "$p" ] && MIGRATION_SESSION+=("${p//\\//}")
  done < <(runtime_json_arr '.normalState.sessionPaths' "$manifest")
  while IFS= read -r p; do
    [ -n "$p" ] && MIGRATION_RUNTIME+=("${p//\\//}")
  done < <(runtime_json_arr '.normalState.runtimePaths' "$manifest")
  while IFS= read -r p; do
    [ -n "$p" ] && MIGRATION_PRESERVE+=("${p//\\//}")
  done < <(runtime_json_arr '.normalState.migrationPreservePaths' "$manifest")
  while IFS= read -r p; do
    [ -n "$p" ] && MIGRATION_SHARED_CREDENTIALS+=("${p//\\//}")
  done < <(runtime_json_arr '.sharedCredentialState.entries // [] | map(.path)' "$manifest")
  while IFS= read -r p; do
    [ -n "$p" ] && MIGRATION_UNSAFE_DECLS+=("${p//\\//}")
  done < <(runtime_json_arr '.normalState.unsafePaths' "$manifest")
}

# Print the first declared path related to $1: equal to it, an ancestor
# directory of it, or sitting underneath it.
migration_match_declared() {
  local rel="$1"; shift
  local declared
  for declared in "$@"; do
    if [ "$rel" = "$declared" ] || [[ "$declared" == "$rel"/* ]] || [[ "$rel" == "$declared"/* ]]; then
      printf '%s\n' "$declared"
      return 0
    fi
  done
  return 1
}

# Match exact shared-credential entries and, when opted in, their dot-suffix
# legacy backup siblings. The backup object itself becomes the matched root so
# directories are preserved whole without inspecting their contents.
migration_match_shared_credential() {
  local rel="$1" declared match
  shift
  match="$(migration_match_declared "$rel" "$@")" && { printf '%s\n' "$match"; return 0; }
  [ "$MIGRATION_SHARED_CREDENTIAL_BACKUP_PATTERN" = dotSuffix ] || return 1
  for declared in "$@"; do
    if [[ "$rel" == "${declared}."?* ]]; then
      printf '%s\n' "$rel"
      return 0
    fi
  done
  return 1
}

# Launcher/migration-owned entries that are never tool state. 'auth' and
# '.runtime' predate this migration only in partial/failed runs; a legacy
# profile cannot meaningfully own them.
migration_is_meta_entry() {
  local rel="$1"
  case "$rel" in
    .shared|.cli|.profile.json|.runtime|.isolated|auth|"$MIGRATION_LOCK_NAME"|"$MIGRATION_ROLLBACK_NAME") return 0 ;;
    "$MIGRATION_JOURNAL_NAME"*) return 0 ;;
  esac
  return 1
}

# Return 0 when a process is using the legacy profile, 1 when the probe can
# prove it idle, and 2 when the platform probe is inconclusive. Linux matches
# the adapter-declared launch environment against same-user /proc entries, so
# another profile of the same tool does not block this one. Other POSIX hosts
# conservatively reject any process whose name matches an adapter binary.
migration_process_name_matches() {
  local manifest="$1" actual="$2" candidate process_name platform_name
  platform_name="$(platform)"
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    case "$candidate" in
      http://*|https://*|appx:*)
        continue
        ;;
    esac
    process_name="${candidate##*/}"
    process_name="${process_name##*\\}"
    process_name="${process_name%.cmd}"
    process_name="${process_name%.exe}"
    [ -n "$process_name" ] || continue
    [ "$actual" = "$process_name" ] && return 0
  done < <(runtime_json_arr ".binary.$platform_name" "$manifest")
  return 1
}

migration_process_probe() {
  local manifest="$1" pdir="$2" key value pair procdir owner current_uid process_name process_env
  local pairs=()
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    value="$(runtime_json_str ".isolation.env.\"$key\"" "$manifest")"
    value="$(runtime_expand_value "$value" "$pdir" "" "$pdir/auth" "$pdir" "$pdir")"
    pairs+=("$key=$value")
  done < <(jq -r '.isolation.env // {} | keys[]' "$manifest" 2>/dev/null || true)

  if [ "$(platform)" = linux ] && [ -d /proc ] && [ "${#pairs[@]}" -gt 0 ]; then
    current_uid="$(id -u 2>/dev/null)" || return 2
    for procdir in /proc/[0-9]*; do
      [ -d "$procdir" ] || continue
      owner="$(stat -c '%u' "$procdir" 2>/dev/null || true)"
      [ "$owner" = "$current_uid" ] || continue
      if ! process_env="$(tr '\0' '\n' < "$procdir/environ" 2>/dev/null)"; then
        process_name="$(tr -d '\r\n' < "$procdir/comm" 2>/dev/null || true)"
        if [ -n "$process_name" ] && migration_process_name_matches "$manifest" "$process_name"; then
          return 0
        fi
        continue
      fi
      for pair in "${pairs[@]}"; do
        if grep -Fqx -- "$pair" <<< "$process_env"; then
          return 0
        fi
      done
    done
    return 1
  fi

  command -v pgrep >/dev/null 2>&1 || return 2
  local candidate platform_name
  platform_name="$(platform)"
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    pgrep -x "$candidate" >/dev/null 2>&1 && return 0
  done < <(runtime_json_arr ".binary.$platform_name" "$manifest" | while IFS= read -r candidate; do
    if [[ "$candidate" == http://* || "$candidate" == https://* || "$candidate" == appx:* ]]; then
      continue
    fi
    process_name="${candidate##*/}"
    process_name="${process_name##*\\}"
    process_name="${process_name%.cmd}"
    process_name="${process_name%.exe}"
    [ -n "$process_name" ] && printf '%s\n' "$process_name"
  done | LC_ALL=C sort -u)
  return 1
}

migration_assert_process_idle() {
  local manifest="$1" pdir="$2" spec="$3" after_lock="${4:-false}" rc
  if migration_process_probe "$manifest" "$pdir"; then
    if [ "$after_lock" = true ]; then
      abort "Cannot migrate $spec: a tool process appeared while acquiring the migration lock. The lock was released and no profile data was changed."
    fi
    abort "Cannot migrate $spec: an active process is using this profile. Close it and retry. No changes were made."
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] || abort "Cannot migrate $spec: could not prove that tool processes are stopped. No changes were made."
}

migration_acquire_lock() {
  local pdir="$1" spec="$2" lock="$pdir/$MIGRATION_LOCK_NAME"
  [ ! -L "$lock" ] || abort "Cannot migrate $spec: migration lock is an unsafe link. No changes were made."
  if ! (umask 077; mkdir "$lock") 2>/dev/null; then
    abort "Cannot migrate $spec: migration is already locked. Close the other migration or recover the stale lock before retrying. No changes were made."
  fi
  if ! (umask 077; printf '%s\n' "${BASHPID:-$$}" > "$lock/pid"); then
    rmdir "$lock" 2>/dev/null || true
    abort "Cannot migrate $spec: could not record the migration lock owner. No changes were made."
  fi
}

migration_release_lock() {
  local lock="$1"
  rm -f -- "$lock/pid" 2>/dev/null || true
  rmdir "$lock" 2>/dev/null || true
}

# Refuse stale or linked control paths before planning, including dry-run. A
# previous journal is allowed only as a regular completed/rolled-back record;
# temporary files, locks, and rollback staging indicate an unfinished run.
migration_assert_control_paths_safe() {
  local pdir="$1" spec="$2" rel path
  [ ! -L "$pdir" ] || abort "Cannot migrate $spec: the profile directory is a link. No changes were made."
  path="$pdir/$MIGRATION_LOCK_NAME"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ ! -L "$path" ] || abort "Cannot migrate $spec: migration lock is an unsafe link. No changes were made."
    abort "Cannot migrate $spec: migration is already locked. Close the other migration or recover the stale lock before retrying. No changes were made."
  fi
  path="$pdir/$MIGRATION_ROLLBACK_NAME"
  if [ -e "$path" ] || [ -L "$path" ]; then
    abort "Cannot migrate $spec: recovery artifacts already exist. Do not launch the profile; inspect the previous journal before retrying. No changes were made."
  fi
  for rel in "$MIGRATION_JOURNAL_NAME.tmp" ".profile.json.tmp"; do
    path="$pdir/$rel"
    if [ -e "$path" ] || [ -L "$path" ]; then
      abort "Cannot migrate $spec: unfinished migration control artifact '$rel' exists. Inspect it before retrying. No changes were made."
    fi
  done
  for rel in "$MIGRATION_JOURNAL_NAME" ".profile.json"; do
    [ ! -L "$pdir/$rel" ] || abort "Cannot migrate $spec: migration control path '$rel' is an unsafe link. No changes were made."
  done
}

# Verify that an adapter-declared destination stays below its lexical root and
# that neither the root nor any existing component is a link. A non-directory
# ancestor is also unsafe because mkdir/mv would otherwise traverse or replace
# an unexpected object.
migration_assert_destination_path_safe() {
  local root="${1%/}" target="$2" spec="$3" label="$4"
  local rel current component
  [ -n "$root" ] || root="/"
  case "$target" in
    "$root"|"$root"/*) ;;
    *) abort "Cannot migrate $spec: $label escapes its declared root. No changes were made." ;;
  esac
  rel="${target#"$root"}"
  rel="${rel#/}"
  current="$root"
  while :; do
    [ ! -L "$current" ] || abort "Cannot migrate $spec: $label crosses a link at '$current'. No changes were made."
    if [ "$current" != "$target" ] && [ -e "$current" ] && [ ! -d "$current" ]; then
      abort "Cannot migrate $spec: $label crosses a non-directory path at '$current'. No changes were made."
    fi
    [ -n "$rel" ] || break
    component="${rel%%/*}"
    if [ "$component" = "$rel" ]; then rel=""; else rel="${rel#*/}"; fi
    current="$current/$component"
  done
}

migration_file_device() {
  stat -c %d "$1" 2>/dev/null || stat -f %d "$1" 2>/dev/null
}

migration_existing_destination_parent() {
  local current
  current="$(dirname "$1")"
  while [ ! -e "$current" ] && [ ! -L "$current" ] && [ "$current" != "$(dirname "$current")" ]; do
    current="$(dirname "$current")"
  done
  printf '%s\n' "$current"
}

migration_assert_credential_same_volume() {
  local from="$1" to="$2" spec="$3" rel="$4" parent source_device destination_device
  parent="$(migration_existing_destination_parent "$to")"
  source_device="$(migration_file_device "$from" 2>/dev/null || true)"
  destination_device="$(migration_file_device "$parent" 2>/dev/null || true)"
  [ -n "$source_device" ] && [ -n "$destination_device" ] || \
    abort "Cannot migrate $spec: could not prove the volume for credential '$rel'. No changes were made."
  [ "$source_device" = "$destination_device" ] || \
    abort "Cannot migrate $spec: credential '$rel' and its destination are on different volumes; refusing a copy-based move. No changes were made."
}

migration_classify() {
  local pdir="$1"
  MIGRATION_ENTRIES=(); MIGRATION_UNKNOWN=(); MIGRATION_OVERLAP=(); MIGRATION_UNSAFE=()
  migration_classify_dir "$pdir" ""
}

# Walk one level of the profile tree, classifying each entry against the
# adapter declarations. Directories that are strict ancestors of a declared
# path are descended into so undeclared siblings are caught; directories that
# are themselves declared are adopted whole.
migration_classify_dir() {
  local pdir="$1" prefix="$2"
  local entry name rel m_cred m_shared m_session m_runtime m_preserve m_shared_credential m_state m_unsafe kind
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    name="$(basename "$entry")"
    rel="${prefix:+$prefix/}$name"
    if migration_is_meta_entry "$rel"; then
      MIGRATION_ENTRIES+=("metadata	$rel")
      continue
    fi
    m_cred=""; m_shared=""; m_session=""; m_runtime=""; m_preserve=""; m_shared_credential=""; m_unsafe=""
    m_cred="$(migration_match_declared "$rel" "${MIGRATION_CREDS[@]+"${MIGRATION_CREDS[@]}"}")" || true
    m_shared="$(migration_match_declared "$rel" "${MIGRATION_SHARED[@]+"${MIGRATION_SHARED[@]}"}")" || true
    m_session="$(migration_match_declared "$rel" "${MIGRATION_SESSION[@]+"${MIGRATION_SESSION[@]}"}")" || true
    m_runtime="$(migration_match_declared "$rel" "${MIGRATION_RUNTIME[@]+"${MIGRATION_RUNTIME[@]}"}")" || true
    m_preserve="$(migration_match_declared "$rel" "${MIGRATION_PRESERVE[@]+"${MIGRATION_PRESERVE[@]}"}")" || true
    m_shared_credential="$(migration_match_shared_credential "$rel" "${MIGRATION_SHARED_CREDENTIALS[@]+"${MIGRATION_SHARED_CREDENTIALS[@]}"}")" || true
    m_unsafe="$(migration_match_declared "$rel" "${MIGRATION_UNSAFE_DECLS[@]+"${MIGRATION_UNSAFE_DECLS[@]}"}")" || true
    if [ -n "$m_unsafe" ]; then
      if [ -d "$entry" ] && [ ! -L "$entry" ] && [ "$rel" != "$m_unsafe" ] && [[ "$m_unsafe" == "$rel"/* ]]; then
        migration_classify_dir "$entry" "$rel"
      else
        MIGRATION_UNSAFE+=("$rel")
      fi
      continue
    fi
    m_state="${m_shared:-${m_session:-$m_runtime}}"
    if { [ -n "$m_cred" ] && [ -n "$m_state" ]; } || \
       { [ -n "$m_shared_credential" ] && { [ -n "$m_cred" ] || [ -n "$m_state" ]; }; }; then
      MIGRATION_OVERLAP+=("$rel")
      continue
    fi
    if [ -n "$m_shared_credential" ]; then
      if [ -d "$entry" ] && [ ! -L "$entry" ] && [ "$rel" != "$m_shared_credential" ] && [[ "$m_shared_credential" == "$rel"/* ]]; then
        migration_classify_dir "$entry" "$rel"
      else
        MIGRATION_ENTRIES+=("shared-credential	$rel")
      fi
      continue
    fi
    if [ -n "$m_cred" ]; then
      if [ -d "$entry" ] && [ ! -L "$entry" ] && [ "$rel" != "$m_cred" ] && [[ "$m_cred" == "$rel"/* ]]; then
        migration_classify_dir "$entry" "$rel"
      else
        MIGRATION_ENTRIES+=("credential	$rel")
      fi
      continue
    fi
    if [ -n "$m_preserve" ]; then
      if [ -d "$entry" ] && [ ! -L "$entry" ] && [ "$rel" != "$m_preserve" ] && [[ "$m_preserve" == "$rel"/* ]]; then
        migration_classify_dir "$entry" "$rel"
      else
        MIGRATION_ENTRIES+=("preserve-profile-state	$rel")
      fi
      continue
    fi
    if [ -n "$m_state" ]; then
      kind="shared"
      [ -n "$m_shared" ] || kind="session"
      [ -n "$m_shared" ] || [ -n "$m_session" ] || kind="runtime"
      if [ -d "$entry" ] && [ ! -L "$entry" ] && [ "$rel" != "$m_state" ] && [[ "$m_state" == "$rel"/* ]]; then
        migration_classify_dir "$entry" "$rel"
      else
        MIGRATION_ENTRIES+=("$kind	$rel")
      fi
      continue
    fi
    MIGRATION_UNKNOWN+=("$rel")
  done < <(find "$pdir" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)
}

# Abort listing every unknown/overlapping entry. Runs before any write, so
# "No changes were made" in the message is true by construction.
migration_refuse_unclassified() {
  local spec="$1" entry message
  message="Cannot migrate $spec: legacy profile contains entries the adapter does not declare:"
  for entry in "${MIGRATION_UNKNOWN[@]+"${MIGRATION_UNKNOWN[@]}"}"; do
    message="$message
  unknown: $entry"
  done
  for entry in "${MIGRATION_OVERLAP[@]+"${MIGRATION_OVERLAP[@]}"}"; do
    message="$message
  overlap: $entry (matches both credential and shared-state declarations)"
  done
  for entry in "${MIGRATION_UNSAFE[@]+"${MIGRATION_UNSAFE[@]}"}"; do
    message="$message
  unsafe: $entry"
  done
  message="$message
Declare safe paths in the adapter or remove unsafe/unknown entries from the profile. No changes were made."
  abort "$message"
}

# =============================================================================
# Planning
# =============================================================================

# Ops are packed as: op, rel, from, to, status, note separated by
# MIGRATION_OP_SEP. Unpack into MIG_OP/MIG_REL/MIG_FROM/MIG_TO/MIG_STATUS/
# MIG_NOTE.
migration_op_unpack() {
  local packed="$1"
  IFS="$MIGRATION_OP_SEP" read -r MIG_OP MIG_REL MIG_FROM MIG_TO MIG_STATUS MIG_NOTE <<< "$packed"
}

# Append a pending op: $1 op, $2 rel, $3 from, $4 to, $5 note.
migration_add_op() {
  MIGRATION_OPS+=("$1$MIGRATION_OP_SEP$2$MIGRATION_OP_SEP$3$MIGRATION_OP_SEP$4${MIGRATION_OP_SEP}pending$MIGRATION_OP_SEP$5")
}

# Rewrite one op's status field in place (pending -> done/skipped/failed).
migration_set_op_status() {
  local index="$1" new_status="$2"
  migration_op_unpack "${MIGRATION_OPS[$index]}"
  MIGRATION_OPS[$index]="$MIG_OP$MIGRATION_OP_SEP$MIG_REL$MIGRATION_OP_SEP$MIG_FROM$MIGRATION_OP_SEP$MIG_TO${MIGRATION_OP_SEP}$new_status$MIGRATION_OP_SEP$MIG_NOTE"
}

# True when a file leaf name collides with a declared credential leaf, so a
# lookalike hiding inside a shared directory is never merged into the root.
migration_credential_leaf() {
  local leaf="$1" cred
  for cred in "${MIGRATION_CREDS[@]+"${MIGRATION_CREDS[@]}"}"; do
    [ "$leaf" = "${cred##*/}" ] && return 0
  done
  return 1
}

# Build the full op list from the classification: credentials first
# (profile-local moves), then state merges, then metadata, then the closing
# .profile.json write.
migration_plan_ops() {
  local pdir="$1" shared_root="$2" prefer_profile="$3" spec="$4"
  local entry class inactive_root="" runtime_inactive_root="" profile_state_inactive_root="" unknown_inactive_root="" store_root
  local has_shared_credentials=false has_runtime_state=false has_profile_state=false has_unknown_state=false
  MIGRATION_OPS=()
  MIGRATION_LINK_ROOT_CHECKED=false
  # Credentials first (profile-local moves), then state merges, then metadata.
  for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
    class="${entry%%	*}"
    [ "$class" = credential ] && migration_plan_credential "$pdir" "${entry#*	}" "$spec"
  done
  for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
    class="${entry%%	*}"
    [ "$class" = shared-credential ] && has_shared_credentials=true
  done
  if [ "$has_shared_credentials" = true ]; then
    store_root="$(dirname "$(dirname "$pdir")")"
    inactive_root="$(migration_inactive_shared_credential_root "$pdir")"
    migration_assert_destination_path_safe "$store_root/.inactive" "$inactive_root" "$spec" "inactive shared-credential recovery root"
    [ ! -e "$inactive_root" ] && [ ! -L "$inactive_root" ] || \
      abort "Cannot migrate $spec: inactive shared-credential recovery already exists. Inspect it before retrying. No changes were made."
    for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
      class="${entry%%	*}"
      [ "$class" = shared-credential ] && migration_plan_shared_credential "$pdir" "$inactive_root" "${entry#*	}" "$spec"
    done
  fi
  for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
    class="${entry%%	*}"
    [ "$class" = runtime ] && has_runtime_state=true
  done
  if [ "$has_runtime_state" = true ]; then
    store_root="$(dirname "$(dirname "$pdir")")"
    runtime_inactive_root="$(migration_inactive_runtime_root "$pdir")"
    migration_assert_destination_path_safe "$store_root/.inactive" "$runtime_inactive_root" "$spec" "inactive runtime-state recovery root"
    [ ! -e "$runtime_inactive_root" ] && [ ! -L "$runtime_inactive_root" ] || \
      abort "Cannot migrate $spec: inactive runtime-state recovery already exists. Inspect it before retrying. No changes were made."
    for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
      class="${entry%%	*}"
      [ "$class" = runtime ] && migration_plan_runtime_state "$pdir" "$runtime_inactive_root" "${entry#*	}" "$spec"
    done
  fi
  for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
    class="${entry%%	*}"
    [ "$class" = preserve-profile-state ] && has_profile_state=true
  done
  if [ "$has_profile_state" = true ]; then
    store_root="$(dirname "$(dirname "$pdir")")"
    profile_state_inactive_root="$(migration_inactive_profile_state_root "$pdir")"
    migration_assert_destination_path_safe "$store_root/.inactive" "$profile_state_inactive_root" "$spec" "inactive profile-state recovery root"
    [ ! -e "$profile_state_inactive_root" ] && [ ! -L "$profile_state_inactive_root" ] || \
      abort "Cannot migrate $spec: inactive profile-state recovery already exists. Inspect it before retrying. No changes were made."
    for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
      class="${entry%%	*}"
      [ "$class" = preserve-profile-state ] && migration_plan_profile_state "$pdir" "$profile_state_inactive_root" "${entry#*	}" "$spec"
    done
  fi
  for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
    class="${entry%%	*}"
    [ "$class" = preserve-unknown ] && has_unknown_state=true
  done
  if [ "$has_unknown_state" = true ]; then
    store_root="$(dirname "$(dirname "$pdir")")"
    unknown_inactive_root="$(migration_inactive_unknown_root "$pdir")"
    migration_assert_destination_path_safe "$store_root/.inactive" "$unknown_inactive_root" "$spec" "inactive unknown-state recovery root"
    [ ! -e "$unknown_inactive_root" ] && [ ! -L "$unknown_inactive_root" ] || \
      abort "Cannot migrate $spec: inactive unknown-state recovery already exists. Inspect it before retrying. No changes were made."
    for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
      class="${entry%%	*}"
      [ "$class" = preserve-unknown ] && migration_plan_unknown_state "$pdir" "$unknown_inactive_root" "${entry#*	}" "$spec"
    done
  fi
  for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
    class="${entry%%	*}"
    case "$class" in
      shared|session) migration_plan_shared "$pdir" "$shared_root" "${entry#*	}" "$class" "$prefer_profile" "$spec" ;;
    esac
  done
  for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
    class="${entry%%	*}"
    [ "$class" = metadata ] && migration_add_op keep-metadata "${entry#*	}" "" "" ""
  done
  migration_plan_placeholders "$pdir" "$spec"
  migration_add_op write-metadata ".profile.json" "" "$pdir/.profile.json" ""
}

migration_inactive_shared_credential_root() {
  local pdir="$1" store_root tool name
  store_root="$(dirname "$(dirname "$pdir")")"
  tool="$(basename "$(dirname "$pdir")")"
  name="$(basename "$pdir")"
  printf '%s/.inactive/migrations/%s/%s/shared-credentials\n' "$store_root" "$tool" "$name"
}

migration_inactive_runtime_root() {
  local pdir="$1" store_root tool name
  store_root="$(dirname "$(dirname "$pdir")")"
  tool="$(basename "$(dirname "$pdir")")"
  name="$(basename "$pdir")"
  printf '%s/.inactive/migrations/%s/%s/runtime-state\n' "$store_root" "$tool" "$name"
}

migration_inactive_profile_state_root() {
  local pdir="$1" store_root tool name
  store_root="$(dirname "$(dirname "$pdir")")"
  tool="$(basename "$(dirname "$pdir")")"
  name="$(basename "$pdir")"
  printf '%s/.inactive/migrations/%s/%s/profile-state\n' "$store_root" "$tool" "$name"
}

migration_inactive_link_root() {
  local pdir="$1" store_root tool name
  store_root="$(dirname "$(dirname "$pdir")")"
  tool="$(basename "$(dirname "$pdir")")"
  name="$(basename "$pdir")"
  printf '%s/.inactive/migrations/%s/%s/linked-state\n' "$store_root" "$tool" "$name"
}

migration_inactive_unknown_root() {
  local pdir="$1" store_root tool name
  store_root="$(dirname "$(dirname "$pdir")")"
  tool="$(basename "$(dirname "$pdir")")"
  name="$(basename "$pdir")"
  printf '%s/.inactive/migrations/%s/%s/unknown-state\n' "$store_root" "$tool" "$name"
}

# Preserve the legacy object itself without following it or reading its
# contents. The destination is outside the active schema-v2 profile and on the
# same filesystem so apply and rollback are rename-only.
migration_plan_shared_credential() {
  local pdir="$1" inactive_root="$2" rel="$3" spec="$4"
  local from="$pdir/$rel" to="$inactive_root/$rel" store_root parent source_device destination_device
  store_root="$(dirname "$(dirname "$pdir")")"
  migration_assert_destination_path_safe "$store_root/.inactive" "$to" "$spec" "inactive shared-credential destination '$rel'"
  [ -e "$from" ] || [ -L "$from" ] || abort "Cannot migrate $spec: shared credential '$rel' disappeared during planning. No changes were made."
  [ ! -e "$to" ] && [ ! -L "$to" ] || abort "Cannot migrate $spec: inactive shared-credential destination '$rel' already exists. No changes were made."
  parent="$(migration_existing_destination_parent "$to")"
  source_device="$(migration_file_device "$from" 2>/dev/null || true)"
  destination_device="$(migration_file_device "$parent" 2>/dev/null || true)"
  [ -n "$source_device" ] && [ -n "$destination_device" ] && [ "$source_device" = "$destination_device" ] || \
    abort "Cannot migrate $spec: shared credential '$rel' cannot be preserved by same-volume rename. No changes were made."
  migration_add_op preserve-shared-credential "$rel" "$from" "$to" "inactive recovery"
}

# Reconstructible state is retained for recovery, never merged into normal
# state. Like credentials, preservation is a same-volume rename with rollback.
migration_plan_runtime_state() {
  local pdir="$1" inactive_root="$2" rel="$3" spec="$4"
  local from="$pdir/$rel" to="$inactive_root/$rel" store_root parent source_device destination_device
  store_root="$(dirname "$(dirname "$pdir")")"
  migration_assert_destination_path_safe "$store_root/.inactive" "$to" "$spec" "inactive runtime-state destination '$rel'"
  [ -e "$from" ] || [ -L "$from" ] || abort "Cannot migrate $spec: runtime state '$rel' disappeared during planning. No changes were made."
  [ ! -e "$to" ] && [ ! -L "$to" ] || abort "Cannot migrate $spec: inactive runtime-state destination '$rel' already exists. No changes were made."
  parent="$(migration_existing_destination_parent "$to")"
  source_device="$(migration_file_device "$from" 2>/dev/null || true)"
  destination_device="$(migration_file_device "$parent" 2>/dev/null || true)"
  [ -n "$source_device" ] && [ -n "$destination_device" ] && [ "$source_device" = "$destination_device" ] || \
    abort "Cannot migrate $spec: runtime state '$rel' cannot be preserved by same-volume rename. No changes were made."
  migration_add_op preserve-runtime-state "$rel" "$from" "$to" "inactive recovery"
}

# Transactional or volatile normal state remains declared for the schema-v2
# runtime, but its legacy instance must not be combined with a different live
# state family. Preserve the complete object by same-volume rename.
migration_plan_profile_state() {
  local pdir="$1" inactive_root="$2" rel="$3" spec="$4"
  local from="$pdir/$rel" to="$inactive_root/$rel" store_root parent source_device destination_device
  store_root="$(dirname "$(dirname "$pdir")")"
  migration_assert_destination_path_safe "$store_root/.inactive" "$to" "$spec" "inactive profile-state destination '$rel'"
  [ -e "$from" ] || [ -L "$from" ] || abort "Cannot migrate $spec: profile state '$rel' disappeared during planning. No changes were made."
  [ ! -e "$to" ] && [ ! -L "$to" ] || abort "Cannot migrate $spec: inactive profile-state destination '$rel' already exists. No changes were made."
  parent="$(migration_existing_destination_parent "$to")"
  source_device="$(migration_file_device "$from" 2>/dev/null || true)"
  destination_device="$(migration_file_device "$parent" 2>/dev/null || true)"
  [ -n "$source_device" ] && [ -n "$destination_device" ] && [ "$source_device" = "$destination_device" ] || \
    abort "Cannot migrate $spec: profile state '$rel' cannot be preserved by same-volume rename. No changes were made."
  migration_add_op preserve-profile-state "$rel" "$from" "$to" "inactive recovery"
}

# Legacy links are preserved as opaque filesystem objects outside the active
# schema-v2 profile. Their targets are never opened, resolved, or copied.
migration_plan_link_state() {
  local pdir="$1" rel="$2" spec="$3"
  local from="$pdir/$rel" inactive_root to store_root parent source_device destination_device
  store_root="$(dirname "$(dirname "$pdir")")"
  inactive_root="$(migration_inactive_link_root "$pdir")"
  to="$inactive_root/$rel"
  migration_assert_destination_path_safe "$store_root/.inactive" "$inactive_root" "$spec" "inactive linked-state recovery root"
  if [ "${MIGRATION_LINK_ROOT_CHECKED:-false}" = false ]; then
    [ ! -e "$inactive_root" ] && [ ! -L "$inactive_root" ] || \
      abort "Cannot migrate $spec: inactive linked-state recovery already exists. Inspect it before retrying. No changes were made."
    MIGRATION_LINK_ROOT_CHECKED=true
  fi
  migration_assert_destination_path_safe "$store_root/.inactive" "$to" "$spec" "inactive linked-state destination '$rel'"
  [ -L "$from" ] || abort "Cannot migrate $spec: linked state '$rel' disappeared during planning. No changes were made."
  [ ! -e "$to" ] && [ ! -L "$to" ] || abort "Cannot migrate $spec: inactive linked-state destination '$rel' already exists. No changes were made."
  parent="$(migration_existing_destination_parent "$to")"
  source_device="$(migration_file_device "$from" 2>/dev/null || true)"
  destination_device="$(migration_file_device "$parent" 2>/dev/null || true)"
  [ -n "$source_device" ] && [ -n "$destination_device" ] && [ "$source_device" = "$destination_device" ] || \
    abort "Cannot migrate $spec: linked state '$rel' cannot be preserved by same-volume rename. No changes were made."
  migration_add_op preserve-link "$rel" "$from" "$to" "inactive recovery"
}

# Unknown legacy state is accepted only after the operator explicitly asks to
# preserve it. The object is renamed whole into inactive recovery, so links are
# not followed and directory contents are not interpreted or merged.
migration_plan_unknown_state() {
  local pdir="$1" inactive_root="$2" rel="$3" spec="$4"
  local from="$pdir/$rel" to="$inactive_root/$rel" store_root parent source_device destination_device
  store_root="$(dirname "$(dirname "$pdir")")"
  migration_assert_destination_path_safe "$store_root/.inactive" "$to" "$spec" "inactive unknown-state destination '$rel'"
  [ -e "$from" ] || [ -L "$from" ] || abort "Cannot migrate $spec: unknown state '$rel' disappeared during planning. No changes were made."
  [ ! -e "$to" ] && [ ! -L "$to" ] || abort "Cannot migrate $spec: inactive unknown-state destination '$rel' already exists. No changes were made."
  parent="$(migration_existing_destination_parent "$to")"
  source_device="$(migration_file_device "$from" 2>/dev/null || true)"
  destination_device="$(migration_file_device "$parent" 2>/dev/null || true)"
  [ -n "$source_device" ] && [ -n "$destination_device" ] && [ "$source_device" = "$destination_device" ] || \
    abort "Cannot migrate $spec: unknown state '$rel' cannot be preserved by same-volume rename. No changes were made."
  migration_add_op preserve-unknown "$rel" "$from" "$to" "explicit inactive recovery"
}

# Plan one credential move into auth/. Links refuse the run; an existing
# target with different content refuses it too -- credentials are never
# overwritten. Identical content dedupes instead of moving.
migration_plan_credential() {
  local pdir="$1" rel="$2" spec="$3"
  local from="$pdir/$rel" auth_root="$pdir/auth" to="$pdir/auth/$rel"
  if [ -L "$from" ]; then
    abort "Cannot migrate $spec: credential '$rel' is a link. Replace it with the real credential file before migrating. No changes were made."
  fi
  if [ ! -f "$from" ]; then
    abort "Cannot migrate $spec: credential '$rel' is not a regular file. No changes were made."
  fi
  if [ "$(file_nlink "$from")" -ne 1 ]; then
    abort "Cannot migrate $spec: credential '$rel' is a hardlink. Detach it before migrating. No changes were made."
  fi
  migration_assert_destination_path_safe "$auth_root" "$to" "$spec" "credential destination 'auth/$rel'"
  if [ -e "$to" ] || [ -L "$to" ]; then
    if [ ! -f "$to" ] || [ -L "$to" ] || [ "$(file_nlink "$to")" -ne 1 ]; then
      abort "Cannot migrate $spec: credential target 'auth/$rel' is not one regular unlinked file. Resolve the conflict manually. No changes were made."
    fi
    if cmp -s "$from" "$to"; then
      migration_add_op remove-duplicate-credential "$rel" "$from" "$to" ""
    else
      abort "Cannot migrate $spec: credential target 'auth/$rel' already exists with different content; refusing to overwrite credentials. Resolve the conflict manually. No changes were made."
    fi
    return
  fi
  migration_assert_credential_same_volume "$from" "$to" "$spec" "$rel"
  migration_add_op move-credential "$rel" "$from" "$to" ""
}

# True when a directory tree holds anything the per-file merge must handle
# individually: links, hardlinked files, or credential-lookalike leaf names.
# Clean trees move whole; blocked trees fall back to per-file merging so
# nothing unsafe rides along into the shared root.
migration_dir_has_blocked_entries() {
  local from="$1" f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    [ -L "$f" ] && return 0
    [ -f "$f" ] || continue
    [ "$(file_nlink "$f")" -gt 1 ] && return 0
    migration_credential_leaf "${f##*/}" && return 0
  done < <(find "$from" -mindepth 1 \( -type f -o -type l \) | LC_ALL=C sort)
  return 1
}

# Plan one shared/session entry: links move opaquely to inactive recovery,
# files merge per the conflict policy, clean new directories move whole, and
# everything else falls back to per-file merging.
migration_plan_shared() {
  local pdir="$1" shared_root="$2" rel="$3" kind="$4" prefer_profile="$5" spec="$6"
  local from="$pdir/$rel" to="$shared_root/$rel"
  migration_assert_destination_path_safe "$shared_root" "$to" "$spec" "shared-state destination '$rel'"
  if [ -L "$from" ]; then
    migration_plan_link_state "$pdir" "$rel" "$spec"
    return
  fi
  if [ -f "$from" ]; then
    migration_plan_file_merge "$from" "$to" "$rel" "$kind" "$prefer_profile" "$shared_root" "$spec"
    return
  fi
  if [ -e "$to" ] && [ ! -d "$to" ]; then
    migration_plan_type_conflict "$from" "$to" "$rel" "$prefer_profile" \
      "shared root has a file where the profile has a directory"
    return
  fi
  if [ ! -d "$to" ] && ! migration_dir_has_blocked_entries "$from"; then
    migration_add_op merge-move "$rel" "$from" "$to" "$kind"
    return
  fi
  # Merge per file: either both sides are directories (existing shared content
  # is preserved), or the tree contains blocked entries handled individually.
  local f sub
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    sub="${f#"$from"/}"
    if [ -L "$f" ]; then
      migration_plan_link_state "$pdir" "$rel/$sub" "$spec"
      continue
    fi
    [ -f "$f" ] || continue
    if [ "$(file_nlink "$f")" -gt 1 ]; then
      migration_add_op skip-link "$rel/$sub" "$f" "" "hardlinked file left in profile"
      continue
    fi
    if migration_credential_leaf "${f##*/}"; then
      migration_add_op skip-credential-lookalike "$rel/$sub" "$f" "" "name matches a declared credential; left in profile"
      continue
    fi
    migration_plan_file_merge "$f" "$to/$sub" "$rel/$sub" "$kind" "$prefer_profile" "$shared_root" "$spec"
  done < <(find "$from" -mindepth 1 \( -type f -o -type l \) | LC_ALL=C sort)
}

# Plan one file against its shared-root target: move when absent, dedupe when
# identical, replace only with --prefer-profile, otherwise skip the conflict.
migration_plan_file_merge() {
  local from="$1" to="$2" rel="$3" kind="$4" prefer_profile="$5" shared_root="$6" spec="$7"
  migration_assert_destination_path_safe "$shared_root" "$to" "$spec" "shared-state destination '$rel'"
  if [ ! -e "$to" ] && [ ! -L "$to" ]; then
    migration_add_op merge-move "$rel" "$from" "$to" "$kind"
    return
  fi
  if [ -d "$to" ]; then
    migration_plan_type_conflict "$from" "$to" "$rel" "$prefer_profile" \
      "shared root has a directory where the profile has a file"
    return
  fi
  if cmp -s "$from" "$to"; then
    migration_add_op remove-duplicate "$rel" "$from" "$to" ""
    return
  fi
  if [ "$prefer_profile" = true ]; then
    migration_add_op replace-shared "$rel" "$from" "$to" "content differs"
  else
    migration_add_op skip-conflict "$rel" "$from" "$to" "content differs"
  fi
}

# Plan a file-vs-directory type conflict: replace with --prefer-profile,
# skip otherwise.
migration_plan_type_conflict() {
  local from="$1" to="$2" rel="$3" prefer_profile="$4" reason="$5"
  if [ "$prefer_profile" = true ]; then
    migration_add_op replace-shared "$rel" "$from" "$to" "$reason"
  else
    migration_add_op skip-conflict "$rel" "$from" "$to" "$reason"
  fi
}

# Declared credential files the legacy profile never had get the same empty
# placeholders the runtime creates for fresh schema-v2 profiles.
migration_plan_placeholders() {
  local pdir="$1" spec="$2" cred existing covered to
  for cred in "${MIGRATION_CREDS[@]+"${MIGRATION_CREDS[@]}"}"; do
    covered=false
    for existing in "${MIGRATION_OPS[@]+"${MIGRATION_OPS[@]}"}"; do
      migration_op_unpack "$existing"
      case "$MIG_OP" in
        move-credential|remove-duplicate-credential) [ "$MIG_REL" = "$cred" ] && covered=true ;;
      esac
    done
    [ "$covered" = true ] && continue
    [ -e "$pdir/$cred" ] && continue
    [ -e "$pdir/auth/$cred" ] && continue
    to="$pdir/auth/$cred"
    migration_assert_destination_path_safe "$pdir/auth" "$to" "$spec" "credential destination 'auth/$cred'"
    migration_add_op ensure-placeholder "$cred" "" "$to" ""
  done
}

# =============================================================================
# Journal
# =============================================================================

# Write the journal atomically (temp + rename): overall status plus every op
# with its current status, so a crash mid-migration leaves a truthful record.
migration_journal_write() {
  local journal="$1" overall="$2" tool="$3" name="$4" shared_root="$5" prefer_profile="$6"
  local tmp="$journal.tmp" i preserve_unknown=false
  local retry_command="nini-agents migrate $tool/$name"
  for i in "${!MIGRATION_OPS[@]}"; do
    migration_op_unpack "${MIGRATION_OPS[$i]}"
    [ "$MIG_OP" = preserve-unknown ] && preserve_unknown=true
  done
  [ "$prefer_profile" = true ] && retry_command="$retry_command --prefer-profile"
  [ "$preserve_unknown" = true ] && retry_command="$retry_command --preserve-unknown"
  if ! printf '%s\0' "${MIGRATION_OPS[@]+"${MIGRATION_OPS[@]}"}" | jq -Rs \
      --arg sep "$MIGRATION_OP_SEP" \
      --arg tool "$tool" \
      --arg profile "$name" \
      --arg shared_root "$shared_root" \
      --arg status "$overall" \
      --argjson prefer_profile "$prefer_profile" \
      --argjson preserve_unknown "$preserve_unknown" \
      --arg action "Automatic rollback is attempted after any failed apply. Re-run '$retry_command' only when status is rolled_back; do not launch when status is rollback_failed." '
        (split("\u0000")
          | map(select(length > 0)
            | split($sep)
            | {op:.[0],rel:.[1],from:.[2],to:.[3],status:.[4],note:.[5]})) as $operations
        | {tool:$tool,profile:$profile,sharedRoot:$shared_root,status:$status,preferProfile:$prefer_profile,preserveUnknown:$preserve_unknown,action:$action,operations:$operations}
      ' > "$tmp"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv -f "$tmp" "$journal"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

# =============================================================================
# Reporting
# =============================================================================

migration_op_line() {
  local op="$1" rel="$2" to="$3" note="$4"
  case "$op" in
    move-credential)              printf '  move credential %s -> auth/%s\n' "$rel" "$rel" ;;
    remove-duplicate-credential)  printf '  remove duplicate credential %s (already migrated)\n' "$rel" ;;
    preserve-shared-credential)   printf '  preserve shared credential %s in inactive recovery\n' "$rel" ;;
    preserve-runtime-state)       printf '  preserve runtime state %s in inactive recovery\n' "$rel" ;;
    preserve-profile-state)       printf '  preserve profile state %s in inactive recovery\n' "$rel" ;;
    preserve-link)                printf '  preserve linked state %s in inactive recovery\n' "$rel" ;;
    preserve-unknown)             printf '  preserve unknown state %s in inactive recovery (--preserve-unknown)\n' "$rel" ;;
    merge-move)                   printf '  merge %s %s -> %s\n' "$note" "$rel" "$to" ;;
    remove-duplicate)             printf '  remove duplicate %s (shared root already has identical content)\n' "$rel" ;;
    skip-conflict)                printf '  skip %s (conflict: %s; use --prefer-profile to override)\n' "$rel" "$note" ;;
    replace-shared)               printf '  replace %s -> %s (--prefer-profile: %s)\n' "$rel" "$to" "$note" ;;
    keep-link)                    printf '  keep shared link %s (%s)\n' "$rel" "$note" ;;
    skip-link)                    printf '  skip nested link %s (%s)\n' "$rel" "$note" ;;
    skip-credential-lookalike)    printf '  skip %s (%s)\n' "$rel" "$note" ;;
    keep-metadata)                printf '  keep launcher metadata %s\n' "$rel" ;;
    ensure-placeholder)           printf '  create empty credential placeholder auth/%s\n' "$rel" ;;
    write-metadata)               printf '  write .profile.json (schemaVersion 2, mode accountOverlay)\n' ;;
    *)                            printf '  %s %s\n' "$op" "$rel" ;;
  esac
}

migration_print_plan() {
  local spec="$1" i
  echo "Migration plan for $spec (legacy-isolated -> accountOverlay):"
  for i in "${!MIGRATION_OPS[@]}"; do
    migration_op_unpack "${MIGRATION_OPS[$i]}"
    migration_op_line "$MIG_OP" "$MIG_REL" "$MIG_TO" "$MIG_NOTE"
  done
  echo "Dry run -- no changes written."
}

# =============================================================================
# Execution
# =============================================================================

migration_do_move() {
  local from="$1" to="$2" parent source_device destination_device
  mkdir -p "$(dirname "$to")"
  parent="$(dirname "$to")"
  source_device="$(migration_file_device "$from")" || return 1
  destination_device="$(migration_file_device "$parent")" || return 1
  [ "$source_device" = "$destination_device" ] || return 1
  mv -- "$from" "$to"
}

# Recheck an inactive-preservation destination immediately before mkdir/mv.
# Unlike the planning assertion this returns non-zero instead of aborting so
# the transaction can journal the failed op and roll back earlier moves.
migration_destination_is_safe_now() {
  local root="${1%/}" target="$2" rel current component
  case "$target" in "$root"|"$root"/*) ;; *) return 1 ;; esac
  rel="${target#"$root"}"
  rel="${rel#/}"
  current="$root"
  while :; do
    [ ! -L "$current" ] || return 1
    if [ "$current" != "$target" ] && [ -e "$current" ] && [ ! -d "$current" ]; then return 1; fi
    [ -n "$rel" ] || break
    component="${rel%%/*}"
    if [ "$component" = "$rel" ]; then rel=""; else rel="${rel#*/}"; fi
    current="$current/$component"
  done
}

migration_do_preserve_inactive() {
  local from="$1" to="$2" inactive_root="$3"
  [ -e "$from" ] || [ -L "$from" ] || return 1
  [ ! -e "$to" ] && [ ! -L "$to" ] || return 1
  migration_destination_is_safe_now "$inactive_root" "$to" || return 1
  migration_do_move "$from" "$to"
}

# Device/inode identity proves a same-filesystem credential rename did not
# make a second physical credential. Values are kept in memory only and never
# written to output or the journal.
migration_file_identity() {
  local path="$1"
  stat -c '%d:%i' "$path" 2>/dev/null || stat -f '%d:%i' "$path" 2>/dev/null
}

migration_do_credential_move() {
  local from="$1" to="$2" before after parent source_device destination_device
  [ -f "$from" ] && [ ! -L "$from" ] || return 1
  [ "$(file_nlink "$from")" -eq 1 ] || return 1
  parent="$(migration_existing_destination_parent "$to")" || return 1
  source_device="$(migration_file_device "$from")" || return 1
  destination_device="$(migration_file_device "$parent")" || return 1
  [ "$source_device" = "$destination_device" ] || return 1
  before="$(migration_file_identity "$from")" || return 1
  migration_do_move "$from" "$to" || return 1
  after="$(migration_file_identity "$to")" || {
    migration_do_move "$to" "$from" 2>/dev/null || true
    return 1
  }
  if [ "$before" != "$after" ] || [ "$(file_nlink "$to")" -ne 1 ]; then
    migration_do_move "$to" "$from" 2>/dev/null || true
    return 1
  fi
}

migration_rollback_slot() {
  printf '%s/%06d\n' "$1" "$2"
}

# Remember destination parents that did not exist immediately before an op.
# Handled rollback removes only these directories, never a pre-existing empty
# directory owned by the user.
migration_record_missing_parent_dirs() {
  local target="$1" boundary="${2%/}" current i
  local missing=()
  current="$(dirname "$target")"
  while [ "$current" != "$boundary" ]; do
    case "$current" in "$boundary"/*) ;; *) return 1 ;; esac
    if [ ! -e "$current" ] && [ ! -L "$current" ]; then
      missing+=("$current")
    fi
    current="$(dirname "$current")"
  done
  # Store parent-to-child so reverse-order rollback removes leaves first,
  # including deep inactive recovery roots.
  for ((i=${#missing[@]} - 1; i >= 0; i--)); do
    MIGRATION_CREATED_DEST_DIRS+=("${missing[$i]}")
  done
}

migration_remove_created_destination_dirs() {
  local i dir
  for ((i=${#MIGRATION_CREATED_DEST_DIRS[@]} - 1; i >= 0; i--)); do
    dir="${MIGRATION_CREATED_DEST_DIRS[$i]}"
    [ ! -e "$dir" ] || { [ -d "$dir" ] && [ ! -L "$dir" ] && rmdir "$dir" 2>/dev/null; } || return 1
  done
}

migration_move_to_rollback() {
  local from="$1" slot="$2"
  [ ! -e "$slot" ] && [ ! -L "$slot" ] || return 1
  migration_do_move "$from" "$slot"
}

# Preserve the previous shared target until the complete journal is durable.
# If activation of the profile entry fails, restore the old target locally so
# the failed operation itself has no partial effect.
migration_do_replace() {
  local from="$1" to="$2" slot="$3"
  migration_move_to_rollback "$to" "$slot" || return 1
  if migration_do_move "$from" "$to"; then
    return 0
  fi
  migration_do_move "$slot" "$to" 2>/dev/null || return 2
  return 1
}

migration_do_placeholder() {
  local to="$1"
  mkdir -p "$(dirname "$to")"
  [ -e "$to" ] || : > "$to"
}

migration_do_metadata() {
  local manifest="$1" pdir="$2"
  if runtime_write_profile_metadata "$manifest" "$pdir"; then
    return 0
  fi
  rm -f -- "$pdir/.profile.json" "$pdir/.profile.json.tmp" 2>/dev/null || return 2
  return 1
}

# Reverse every completed operation in strict reverse order. Rollback uses
# moves, not credential copies. A failure leaves every artifact in place and
# returns non-zero so callers mark ownership indeterminate.
migration_rollback_ops() {
  local pdir="$1" rollback_root="$2" i slot rollback_failed=false op_failed
  local op_status
  for ((i=${#MIGRATION_OPS[@]} - 1; i >= 0; i--)); do
    migration_op_unpack "${MIGRATION_OPS[$i]}"
    op_status="$MIG_STATUS"
    [ "$op_status" = done ] || continue
    slot="$(migration_rollback_slot "$rollback_root" "$i")"
    op_failed=false
    case "$MIG_OP" in
      keep-metadata|keep-link|skip-conflict|skip-link|skip-credential-lookalike)
        ;;
      move-credential|merge-move|preserve-shared-credential|preserve-runtime-state|preserve-profile-state|preserve-link|preserve-unknown)
        if [ ! -e "$MIG_FROM" ] && [ ! -L "$MIG_FROM" ] && { [ -e "$MIG_TO" ] || [ -L "$MIG_TO" ]; }; then
          migration_do_move "$MIG_TO" "$MIG_FROM" || op_failed=true
        else
          op_failed=true
        fi
        ;;
      remove-duplicate|remove-duplicate-credential)
        if [ ! -e "$MIG_FROM" ] && [ ! -L "$MIG_FROM" ] && { [ -e "$slot" ] || [ -L "$slot" ]; }; then
          migration_do_move "$slot" "$MIG_FROM" || op_failed=true
        else
          op_failed=true
        fi
        ;;
      replace-shared)
        if [ ! -e "$MIG_FROM" ] && [ ! -L "$MIG_FROM" ] && \
           { [ -e "$MIG_TO" ] || [ -L "$MIG_TO" ]; } && \
           { [ -e "$slot" ] || [ -L "$slot" ]; }; then
          migration_do_move "$MIG_TO" "$MIG_FROM" && migration_do_move "$slot" "$MIG_TO" || op_failed=true
        else
          op_failed=true
        fi
        ;;
      ensure-placeholder)
        if [ -f "$MIG_TO" ] && [ ! -L "$MIG_TO" ] && [ ! -s "$MIG_TO" ]; then
          rm -f -- "$MIG_TO" || op_failed=true
        else
          op_failed=true
        fi
        ;;
      write-metadata)
        rm -f -- "$MIG_TO" "$MIG_TO.tmp" 2>/dev/null || op_failed=true
        ;;
      *) op_failed=true ;;
    esac
    if [ "$op_failed" = false ]; then
      migration_set_op_status "$i" rolled-back
    else
      rollback_failed=true
    fi
  done
  [ "$rollback_failed" = false ] || return 1
  if [ -d "$rollback_root" ] && [ ! -L "$rollback_root" ]; then
    while IFS= read -r slot; do rmdir "$slot" 2>/dev/null || true; done < <(find "$rollback_root" -depth -type d | LC_ALL=C sort -r)
  fi
  [ ! -e "$rollback_root" ] && [ ! -L "$rollback_root" ]
}

migration_cleanup_rollback_root() {
  local pdir="$1" rollback_root="$2"
  [ "$rollback_root" = "$pdir/$MIGRATION_ROLLBACK_NAME" ] || return 1
  [ ! -L "$rollback_root" ] || return 1
  [ -e "$rollback_root" ] || return 0
  rm -rf -- "$rollback_root"
}

migration_remove_created_shared_root() {
  local shared_root="$1"
  [ "$MIGRATION_SHARED_ROOT_CREATED" = true ] || return 0
  [ ! -L "$shared_root" ] || return 1
  [ -d "$shared_root" ] || return 1
  rmdir "$shared_root" 2>/dev/null
}

migration_failure_state_is_legacy() {
  local pdir="$1" rollback_root="$2" shared_root="$3" i slot
  [ ! -e "$pdir/.profile.json" ] && [ ! -L "$pdir/.profile.json" ] || return 1
  [ ! -e "$pdir/.profile.json.tmp" ] && [ ! -L "$pdir/.profile.json.tmp" ] || return 1
  [ ! -e "$rollback_root" ] && [ ! -L "$rollback_root" ] || return 1
  if [ "$MIGRATION_SHARED_ROOT_CREATED" = true ]; then
    [ ! -e "$shared_root" ] && [ ! -L "$shared_root" ] || return 1
  fi
  for i in "${!MIGRATION_OPS[@]}"; do
    migration_op_unpack "${MIGRATION_OPS[$i]}"
    [ "$MIG_STATUS" != done ] || return 1
    [ "$MIG_STATUS" = failed ] || continue
    slot="$(migration_rollback_slot "$rollback_root" "$i")"
    case "$MIG_OP" in
      move-credential|merge-move|preserve-shared-credential|preserve-runtime-state|preserve-profile-state|preserve-link|preserve-unknown)
        { [ -e "$MIG_FROM" ] || [ -L "$MIG_FROM" ]; } && [ ! -e "$MIG_TO" ] && [ ! -L "$MIG_TO" ] || return 1
        ;;
      remove-duplicate|remove-duplicate-credential)
        { [ -e "$MIG_FROM" ] || [ -L "$MIG_FROM" ]; } && [ ! -e "$slot" ] && [ ! -L "$slot" ] || return 1
        ;;
      replace-shared)
        { [ -e "$MIG_FROM" ] || [ -L "$MIG_FROM" ]; } && { [ -e "$MIG_TO" ] || [ -L "$MIG_TO" ]; } && [ ! -e "$slot" ] && [ ! -L "$slot" ] || return 1
        ;;
      ensure-placeholder)
        [ ! -e "$MIG_TO" ] && [ ! -L "$MIG_TO" ] || return 1
        ;;
      write-metadata)
        [ ! -e "$MIG_TO" ] && [ ! -L "$MIG_TO" ] && [ ! -e "$MIG_TO.tmp" ] && [ ! -L "$MIG_TO.tmp" ] || return 1
        ;;
      keep-metadata|keep-link|skip-conflict|skip-link|skip-credential-lookalike) ;;
      *) ;;
    esac
  done
}

migration_fail_and_rollback() {
  local index="$1" error="$2" pdir="$3" rollback_root="$4" journal="$5"
  local tool="$6" name="$7" shared_root="$8" prefer_profile="$9"
  [ "$index" -lt 0 ] || migration_set_op_status "$index" failed
  migration_journal_write "$journal" failed "$tool" "$name" "$shared_root" "$prefer_profile" 2>/dev/null || true
  if migration_rollback_ops "$pdir" "$rollback_root" && \
     migration_remove_created_destination_dirs && \
     migration_remove_created_shared_root "$shared_root" && \
     migration_failure_state_is_legacy "$pdir" "$rollback_root" "$shared_root"; then
    migration_journal_write "$journal" rolled_back "$tool" "$name" "$shared_root" "$prefer_profile" 2>/dev/null || true
    abort "Migration failed: $error
Automatic rollback restored the legacy layout. Journal written to $journal
Fix the cause, verify the profile is idle, and re-run 'nini-agents migrate $tool/$name'."
  fi
  migration_journal_write "$journal" rollback_failed "$tool" "$name" "$shared_root" "$prefer_profile" 2>/dev/null || true
  abort "Migration failed: $error
Automatic rollback could not prove the legacy layout was restored. Do not launch this profile. Preserve $journal and $rollback_root for recovery."
}

# Apply a frozen plan under an exclusive profile lock. Process state is checked
# both before the first write and again while the lock is held.
migration_apply_transaction() (
  local pdir="$1" manifest="$2" journal="$3" tool="$4" name="$5" shared_root="$6" prefer_profile="$7" spec="$8"
  local lock="$pdir/$MIGRATION_LOCK_NAME" rollback_root="$pdir/$MIGRATION_ROLLBACK_NAME"

  migration_assert_process_idle "$manifest" "$pdir" "$spec" false
  [ ! -e "$rollback_root" ] && [ ! -L "$rollback_root" ] || \
    abort "Cannot migrate $spec: recovery artifacts already exist. Do not launch the profile; inspect the previous journal before retrying. No changes were made."
  migration_acquire_lock "$pdir" "$spec"
  trap 'migration_release_lock "$lock"' EXIT HUP INT TERM
  migration_assert_process_idle "$manifest" "$pdir" "$spec" true

  MIGRATION_SHARED_ROOT_CREATED=false
  MIGRATION_CREATED_DEST_DIRS=()
  migration_journal_write "$journal" running "$tool" "$name" "$shared_root" "$prefer_profile" || \
    abort "Cannot migrate $spec: could not create the migration journal. No profile data was changed."
  if [ ! -e "$shared_root" ] && [ ! -L "$shared_root" ]; then
    MIGRATION_SHARED_ROOT_CREATED=true
  fi
  if ! mkdir -p "$shared_root"; then
    if migration_remove_created_shared_root "$shared_root"; then
      migration_journal_write "$journal" rolled_back "$tool" "$name" "$shared_root" "$prefer_profile" 2>/dev/null || true
      abort "Cannot migrate $spec: could not prepare the shared state root. No profile data was changed."
    fi
    migration_journal_write "$journal" rollback_failed "$tool" "$name" "$shared_root" "$prefer_profile" 2>/dev/null || true
    abort "Cannot migrate $spec: could not prepare or remove the new shared state root. Do not launch this profile; preserve the journal for recovery."
  fi
  migration_exec_ops "$pdir" "$manifest" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"
  migration_prune_empty_dirs "$pdir"
  if ! migration_journal_write "$journal" completed "$tool" "$name" "$shared_root" "$prefer_profile"; then
    migration_fail_and_rollback -1 "could not finalize the migration journal" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"
  fi
  if ! migration_cleanup_rollback_root "$pdir" "$rollback_root"; then
    abort "Migration reached schema-v2 but could not remove recovery artifacts at $rollback_root. Do not launch the profile until they are inspected."
  fi
)

# Run every planned op in order, journaling after each. Any failure marks the
# op failed, rolls every completed operation back, and aborts.
migration_exec_ops() {
  local pdir="$1" manifest="$2" journal="$3" tool="$4" name="$5" shared_root="$6" prefer_profile="$7"
  local rollback_root="$pdir/$MIGRATION_ROLLBACK_NAME" i slot err rc
  for i in "${!MIGRATION_OPS[@]}"; do
    migration_op_unpack "${MIGRATION_OPS[$i]}"
    slot="$(migration_rollback_slot "$rollback_root" "$i")"
    err=""
    case "$MIG_OP" in
      keep-metadata|keep-link|skip-conflict|skip-link|skip-credential-lookalike)
        migration_set_op_status "$i" skipped
        ;;
      remove-duplicate|remove-duplicate-credential)
        err="$(migration_move_to_rollback "$MIG_FROM" "$slot" 2>&1)" || rc=$?
        if [ "${rc:-0}" -eq 0 ]; then migration_set_op_status "$i" done; else migration_fail_and_rollback "$i" "$err" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"; fi
        ;;
      move-credential)
        migration_record_missing_parent_dirs "$MIG_TO" "$pdir" || \
          migration_fail_and_rollback "$i" "credential destination escaped the profile" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"
        err="$(migration_do_credential_move "$MIG_FROM" "$MIG_TO" 2>&1)" || rc=$?
        if [ "${rc:-0}" -eq 0 ]; then migration_set_op_status "$i" done; else migration_fail_and_rollback "$i" "${err:-credential identity verification failed}" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"; fi
        ;;
      preserve-shared-credential)
        migration_record_missing_parent_dirs "$MIG_TO" "$(dirname "$(dirname "$pdir")")" || \
          migration_fail_and_rollback "$i" "inactive shared-credential destination escaped profile storage" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"
        err="$(migration_do_preserve_inactive "$MIG_FROM" "$MIG_TO" "$(dirname "$(dirname "$pdir")")/.inactive" 2>&1)" || rc=$?
        if [ "${rc:-0}" -eq 0 ]; then migration_set_op_status "$i" done; else migration_fail_and_rollback "$i" "$err" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"; fi
        ;;
      preserve-runtime-state)
        migration_record_missing_parent_dirs "$MIG_TO" "$(dirname "$(dirname "$pdir")")" || \
          migration_fail_and_rollback "$i" "inactive runtime-state destination escaped profile storage" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"
        err="$(migration_do_preserve_inactive "$MIG_FROM" "$MIG_TO" "$(dirname "$(dirname "$pdir")")/.inactive" 2>&1)" || rc=$?
        if [ "${rc:-0}" -eq 0 ]; then migration_set_op_status "$i" done; else migration_fail_and_rollback "$i" "$err" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"; fi
        ;;
      preserve-profile-state)
        migration_record_missing_parent_dirs "$MIG_TO" "$(dirname "$(dirname "$pdir")")" || \
          migration_fail_and_rollback "$i" "inactive profile-state destination escaped profile storage" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"
        err="$(migration_do_preserve_inactive "$MIG_FROM" "$MIG_TO" "$(dirname "$(dirname "$pdir")")/.inactive" 2>&1)" || rc=$?
        if [ "${rc:-0}" -eq 0 ]; then migration_set_op_status "$i" done; else migration_fail_and_rollback "$i" "$err" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"; fi
        ;;
      preserve-link)
        migration_record_missing_parent_dirs "$MIG_TO" "$(dirname "$(dirname "$pdir")")" || \
          migration_fail_and_rollback "$i" "inactive linked-state destination escaped profile storage" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"
        err="$(migration_do_preserve_inactive "$MIG_FROM" "$MIG_TO" "$(dirname "$(dirname "$pdir")")/.inactive" 2>&1)" || rc=$?
        if [ "${rc:-0}" -eq 0 ]; then migration_set_op_status "$i" done; else migration_fail_and_rollback "$i" "$err" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"; fi
        ;;
      preserve-unknown)
        migration_record_missing_parent_dirs "$MIG_TO" "$(dirname "$(dirname "$pdir")")" || \
          migration_fail_and_rollback "$i" "inactive unknown-state destination escaped profile storage" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"
        err="$(migration_do_preserve_inactive "$MIG_FROM" "$MIG_TO" "$(dirname "$(dirname "$pdir")")/.inactive" 2>&1)" || rc=$?
        if [ "${rc:-0}" -eq 0 ]; then migration_set_op_status "$i" done; else migration_fail_and_rollback "$i" "$err" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"; fi
        ;;
      merge-move)
        migration_record_missing_parent_dirs "$MIG_TO" "$shared_root" || \
          migration_fail_and_rollback "$i" "shared-state destination escaped its root" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"
        err="$(migration_do_move "$MIG_FROM" "$MIG_TO" 2>&1)" || rc=$?
        if [ "${rc:-0}" -eq 0 ]; then migration_set_op_status "$i" done; else migration_fail_and_rollback "$i" "$err" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"; fi
        ;;
      replace-shared)
        err="$(migration_do_replace "$MIG_FROM" "$MIG_TO" "$slot" 2>&1)" || rc=$?
        if [ "${rc:-0}" -eq 0 ]; then migration_set_op_status "$i" done; else migration_fail_and_rollback "$i" "$err" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"; fi
        ;;
      ensure-placeholder)
        migration_record_missing_parent_dirs "$MIG_TO" "$pdir" || \
          migration_fail_and_rollback "$i" "credential placeholder escaped the profile" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"
        err="$(migration_do_placeholder "$MIG_TO" 2>&1)" || rc=$?
        if [ "${rc:-0}" -eq 0 ]; then migration_set_op_status "$i" done; else migration_fail_and_rollback "$i" "$err" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"; fi
        ;;
      write-metadata)
        err="$(migration_do_metadata "$manifest" "$pdir" 2>&1)" || rc=$?
        if [ "${rc:-0}" -eq 0 ]; then migration_set_op_status "$i" done; else migration_fail_and_rollback "$i" "$err" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"; fi
        ;;
      *)
        migration_fail_and_rollback "$i" "unknown operation '$MIG_OP'" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"
        ;;
    esac
    rc=0
    migration_op_unpack "${MIGRATION_OPS[$i]}"
    migration_op_line "$MIG_OP" "$MIG_REL" "$MIG_TO" "$MIG_NOTE"
    if ! migration_journal_write "$journal" running "$tool" "$name" "$shared_root" "$prefer_profile"; then
      migration_fail_and_rollback -1 "could not update the migration journal" "$pdir" "$rollback_root" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile"
    fi
  done
}

# Remove directories left empty by moves, keeping the schema-v2 skeleton.
migration_prune_empty_dirs() {
  local pdir="$1" dir
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    [ "$dir" = "$pdir" ] && continue
    case "$dir" in
      "$pdir/auth"|"$pdir/auth"/*|"$pdir/.runtime"*) continue ;;
    esac
    rmdir "$dir" 2>/dev/null || true
  done < <(find "$pdir" -depth -type d -empty | LC_ALL=C sort)
}

# Atomic moves need profile storage and the shared root on one volume.
migration_assert_same_volume() {
  local pdir="$1" shared_root="$2" spec="$3"
  local existing="$shared_root" dev_a dev_b
  while [ ! -e "$existing" ] && [ "$existing" != "$(dirname "$existing")" ]; do
    existing="$(dirname "$existing")"
  done
  dev_a="$(stat -c %d "$pdir" 2>/dev/null || stat -f %d "$pdir" 2>/dev/null || echo '?')"
  dev_b="$(stat -c %d "$existing" 2>/dev/null || stat -f %d "$existing" 2>/dev/null || echo '?')"
  [ "$dev_a" = "$dev_b" ] || abort "Cannot migrate $spec: profile storage and the shared state root '$shared_root' are on different volumes. Migration uses atomic same-volume moves; set MULTICLI_HOME to the same volume as '$shared_root' and retry."
}

# =============================================================================
# Entry point -- wired into the launcher as `nini-agents migrate`
# =============================================================================

# nini-agents migrate <tool>/<name> [--dry-run] [--prefer-profile]
# [--preserve-unknown]: refuse unclassifiable profiles by default, or preserve
# unknown objects inactive after explicit opt-in. Overlap/unsafe entries always
# refuse. Then plan and either print the plan or execute it under the journal.
cmd_migrate() {
  local spec="" dry_run=false prefer_profile=false preserve_unknown=false entry
  local positionals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)        dry_run=true ;;
      --prefer-profile) prefer_profile=true ;;
      --preserve-unknown) preserve_unknown=true ;;
      --*)              abort "Unknown option '$1'. Usage: nini-agents migrate <tool>/<name> [--dry-run] [--prefer-profile] [--preserve-unknown]" ;;
      *)                positionals+=("$1") ;;
    esac
    shift
  done
  spec="${positionals[0]:-}"
  [ -n "$spec" ] || abort "Usage: nini-agents migrate <tool>/<name> [--dry-run] [--prefer-profile] [--preserve-unknown]"
  split_profile_spec "$spec"
  validate_name "$NAME"
  local manifest pdir shared_root mechanism journal
  manifest="$(adapter_path "$TOOL")"
  assert_adapter_valid "$TOOL"
  pdir="$(profile_dir "$TOOL" "$NAME")"
  [ -d "$pdir" ] || abort "Profile '$spec' does not exist"
  migration_assert_control_paths_safe "$pdir" "$spec"

  if ! migration_is_legacy_profile "$pdir"; then
    echo "Profile '$spec' is already schema-v2 (accountOverlay); nothing to do."
    return 0
  fi
  mechanism="$(runtime_json_str '.account.mechanism' "$manifest")"
  case "$mechanism" in
    fileOverlay|processSecret) ;;
    osUserCredentialStore)
      abort "Cannot migrate $spec: adapter '$TOOL' uses 'osUserCredentialStore' credentials. Only fileOverlay and processSecret adapters can be migrated; keep the legacy profile." ;;
    inseparable)
      abort "Cannot migrate $spec: adapter '$TOOL' is marked inseparable ($(runtime_json_str '.account.reason' "$manifest")) Keep the legacy-isolated profile." ;;
    *)
      abort "Cannot migrate $spec: unsupported account mechanism '$mechanism'." ;;
  esac

  shared_root="$(runtime_platform_root "$manifest")"
  [ -n "$shared_root" ] || abort "Adapter '$TOOL' has no normal-state root for $(platform)."
  # Windows adapter roots use backslashes; normalize so plan lines, journal
  # paths, and prefix arithmetic see one separator.
  shared_root="${shared_root//\\//}"
  migration_assert_destination_path_safe "$shared_root" "$shared_root" "$spec" "shared-state root"

  migration_load_declarations "$manifest"
  migration_classify "$pdir"
  if [ "$preserve_unknown" = true ] && [ "${#MIGRATION_UNKNOWN[@]}" -gt 0 ]; then
    for entry in "${MIGRATION_UNKNOWN[@]}"; do
      MIGRATION_ENTRIES+=("preserve-unknown	$entry")
    done
    MIGRATION_UNKNOWN=()
  fi
  if [ "${#MIGRATION_UNKNOWN[@]}" -gt 0 ] || [ "${#MIGRATION_OVERLAP[@]}" -gt 0 ] || [ "${#MIGRATION_UNSAFE[@]}" -gt 0 ]; then
    migration_refuse_unclassified "$spec"
  fi

  migration_assert_same_volume "$pdir" "$shared_root" "$spec"
  migration_plan_ops "$pdir" "$shared_root" "$prefer_profile" "$spec"

  if [ "$dry_run" = true ]; then
    migration_print_plan "$spec"
    return 0
  fi

  echo "Migrating $spec (legacy-isolated -> accountOverlay):"
  journal="$pdir/$MIGRATION_JOURNAL_NAME"
  migration_apply_transaction "$pdir" "$manifest" "$journal" "$TOOL" "$NAME" "$shared_root" "$prefer_profile" "$spec" || return $?
  echo "Migrated $spec to schema-v2 (accountOverlay)."
  if [ "$mechanism" = processSecret ]; then
    echo "Note: adapter '$TOOL' uses process-secret credentials. Run: nini-agents auth set $spec before launching."
  fi
}
