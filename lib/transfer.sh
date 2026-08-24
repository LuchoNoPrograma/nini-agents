#!/usr/bin/env bash
# Allowlist-driven profile transfer (templates, export, import) for schema-v2
# profiles. Only adapter-declared normalState.sharedPaths content is copied;
# credentials, sessions, links, hardlinks, and unclassified files never travel.
#
# Sourced by nini-agents after lib/multicli-runtime.sh; relies on the launcher's
# abort/platform/resolve_path_token. When sourced standalone (tests), it pulls
# in the runtime helpers and defines the small utility fallbacks itself.

if ! declare -F runtime_json_str >/dev/null 2>&1; then
  # shellcheck source=lib/multicli-runtime.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/multicli-runtime.sh"
fi
if ! declare -F abort >/dev/null 2>&1; then
  abort() { echo "Error: $1" >&2; exit 1; }
fi
if ! declare -F file_nlink >/dev/null 2>&1; then
  file_nlink() { stat -c %h "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null || echo 1; }
fi
if ! declare -F file_size >/dev/null 2>&1; then
  file_size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0; }
fi

TRANSFER_MANIFEST_NAME=".multicli-manifest.json"
TRANSFER_SECRET_SCAN_MAX_BYTES=$((1024 * 1024))

# Credential basenames blocked at any depth, including the names the legacy
# copy-then-delete template/export implementation hardcoded.
transfer_is_credential_basename() {
  case "$1" in
    auth.json|.credentials.json|oauth_creds.json|google_accounts.json|mcp-oauth-tokens.json|a2a-oauth-tokens.json) return 0 ;;
  esac
  return 1
}

# True when $rel appears verbatim in the jq array at $1 of the manifest.
transfer_is_declared_path() {
  local jq_path="$1" rel="$2" manifest="$3" declared
  while IFS= read -r declared; do
    [ "$declared" = "$rel" ] && return 0
  done < <(runtime_json_arr "$jq_path" "$manifest")
  return 1
}

transfer_is_shared_credential_path() {
  local manifest="$1" rel="$2" declared backup_pattern
  backup_pattern="$(runtime_json_str '.sharedCredentialState.legacyBackupPattern' "$manifest")"
  while IFS= read -r declared; do
    [ -n "$declared" ] || continue
    case "$rel" in "$declared"|"$declared"/*) return 0 ;; esac
    if [ "$backup_pattern" = dotSuffix ]; then
      case "$rel" in "$declared".?*) return 0 ;; esac
    fi
  done < <(runtime_json_arr '.sharedCredentialState.entries // [] | map(.path)' "$manifest")
  return 1
}

# Credential paths are the adapter-declared credential files, the legacy
# hardcoded credential basenames at any depth, and the profile auth boundary.
transfer_is_credential_path() {
  local manifest="$1" rel="$2"
  transfer_is_declared_path '.account.credentialFiles' "$rel" "$manifest" && return 0
  transfer_is_shared_credential_path "$manifest" "$rel" && return 0
  transfer_is_credential_basename "$(basename "$rel")" && return 0
  case "$rel" in
    auth|auth/*) return 0 ;;
  esac
  return 1
}

# True when $rel is one of the adapter-declared session paths.
transfer_is_session_path() {
  local manifest="$1" rel="$2"
  transfer_is_declared_path '.normalState.sessionPaths' "$rel" "$manifest"
}

# Physical absolute path with all link components resolved; fails when the
# parent does not exist so callers decide how to treat broken links.
transfer_canonical() {
  local path="$1" dir
  if [ -d "$path" ]; then
    (cd "$path" 2>/dev/null && pwd -P)
    return
  fi
  dir="$(dirname "$path")"
  [ -d "$dir" ] || return 1
  (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")")
}

# True when canonical $1 equals canonical $2 or sits underneath it.
transfer_path_within() {
  local child="${1%/}/" root="${2%/}/"
  [ -n "$2" ] || return 1
  [[ "$child" == "$root"* ]]
}

# Read the schema-v2 profile mode. Missing or malformed metadata is treated as
# the ordinary account-overlay mode for backward compatibility.
transfer_profile_mode() {
  local profile_dir="$1" mode=""
  [ -f "$profile_dir/.profile.json" ] && \
    mode="$(runtime_json_str '.mode' "$profile_dir/.profile.json" 2>/dev/null || true)"
  [ "$mode" = isolated ] && printf '%s\n' isolated || printf '%s\n' accountOverlay
}

# Where the profile resolves a declared shared path to. Isolated profiles read
# their own root; ordinary profiles read the runtime view or native shared root.
# Sets TRANSFER_SOURCE.
transfer_profile_source() {
  local manifest="$1" profile_dir="$2" rel="$3" shared_root="$4" candidate state_subdir
  TRANSFER_SOURCE=""
  if [ "$(transfer_profile_mode "$profile_dir")" = isolated ]; then
    state_subdir="$(runtime_json_str '.normalState.runtimeSubdir' "$manifest")"
    candidate="$profile_dir/${state_subdir:+$state_subdir/}$rel"
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      TRANSFER_SOURCE="$candidate"
      return 0
    fi
    return 1
  fi
  candidate="$profile_dir/.runtime/$rel"
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    TRANSFER_SOURCE="$candidate"
    return 0
  fi
  candidate="$shared_root/$rel"
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    TRANSFER_SOURCE="$candidate"
    return 0
  fi
  return 1
}

# Resolve one declared top-level path to the physical location holding its
# content. Overlay links into the shared root are the expected fileOverlay
# mechanism; a link pointing anywhere else is tampering and refuses the run.
# Sets TRANSFER_RESOLVED.
transfer_resolve_top() {
  local path="$1" rel="$2" shared_root="$3" profile_dir="$4" action="$5"
  local target canonical_target canonical_shared canonical_profile
  TRANSFER_RESOLVED=""
  if [ -L "$path" ]; then
    target="$(readlink "$path")"
    case "$target" in
      /*|[A-Za-z]:*) ;;
      *) target="$(dirname "$path")/$target" ;;
    esac
    canonical_target="$(transfer_canonical "$target")" || \
      abort "Cannot $action: '$rel' is a link with no resolvable target. Rebuild the profile runtime with \`nini-agents launch\` and retry."
    canonical_shared="$(transfer_canonical "$shared_root" 2>/dev/null || true)"
    canonical_profile="$(transfer_canonical "$profile_dir")"
    if ! transfer_path_within "$canonical_target" "$canonical_shared" && ! transfer_path_within "$canonical_target" "$canonical_profile"; then
      abort "Cannot $action: '$rel' is a link to '$canonical_target' outside the profile's shared state. Remove the link and retry."
    fi
    TRANSFER_RESOLVED="$canonical_target"
    return 0
  fi
  TRANSFER_RESOLVED="$(transfer_canonical "$path")" || \
    abort "Cannot $action: '$rel' cannot be resolved."
}

# Set TRANSFER_FILE_REFUSAL when a file cannot cross the boundary. Every file
# must be small UTF-8-ish text that can be inspected for secret patterns.
transfer_file_refusal() {
  local src="$1" size
  TRANSFER_FILE_REFUSAL=""
  size="$(file_size "$src")"
  if [ "$size" -gt "$TRANSFER_SECRET_SCAN_MAX_BYTES" ]; then
    TRANSFER_FILE_REFUSAL="is larger than the ${TRANSFER_SECRET_SCAN_MAX_BYTES}-byte secret-scan limit"
    return 0
  fi
  if LC_ALL=C od -An -v -t x1 -- "$src" 2>/dev/null | grep -qw '00'; then
    TRANSFER_FILE_REFUSAL="is binary and cannot be secret-scanned safely"
    return 0
  fi
  if grep -Iq -e 'sk-' -e 'access_token' -e 'refresh_token' -e 'id_token' -e 'Bearer ' -- "$src" 2>/dev/null; then
    TRANSFER_FILE_REFUSAL="looks like it contains a secret (credential pattern match)"
    return 0
  fi
  return 1
}

transfer_file_has_secret() {
  transfer_file_refusal "$1"
}

# Append every regular file under a resolved declared path to the plan,
# applying the exclusion rules. Links are never included and never followed;
# one pointing outside the allowed roots means the tree was tampered with.
transfer_collect_path() {
  local src="$1" rel="$2" manifest="$3" action="$4" is_top="$5"
  local entry name target canonical_target canonical_file
  if [ -L "$src" ]; then
    target="$(readlink "$src" 2>/dev/null || true)"
    case "$target" in
      /*|[A-Za-z]:*) ;;
      *) target="$(dirname "$src")/$target" ;;
    esac
    canonical_target="$(transfer_canonical "$target" 2>/dev/null || true)"
    [ -z "$canonical_target" ] && return 0
    if transfer_path_within "$canonical_target" "$TRANSFER_ALLOWED_SHARED" || \
       transfer_path_within "$canonical_target" "$TRANSFER_ALLOWED_PROFILE"; then
      return 0
    fi
    abort "Cannot $action: '$rel' is a link to '$canonical_target' outside the profile's shared state. Remove the link and retry."
  fi
  if [ -d "$src" ]; then
    while IFS= read -r -d '' entry; do
      name="$(basename "$entry")"
      transfer_collect_path "$entry" "$rel/$name" "$manifest" "$action" false
    done < <(find "$src" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    return 0
  fi
  [ -f "$src" ] || return 0
  transfer_is_credential_path "$manifest" "$rel" && return 0
  transfer_is_session_path "$manifest" "$rel" && return 0
  # A nested hardlink can alias a credential under an innocent name, so its
  # content cannot be proven shareable. Top-level declared paths are the
  # overlay mechanism itself and are copied as content.
  if [ "$is_top" != true ] && [ "$(file_nlink "$src")" -gt 1 ]; then
    return 0
  fi
  canonical_file="$(transfer_canonical "$src" 2>/dev/null || true)"
  [ -z "$canonical_file" ] && return 0
  if ! transfer_path_within "$canonical_file" "$TRANSFER_ALLOWED_SHARED" && \
     ! transfer_path_within "$canonical_file" "$TRANSFER_ALLOWED_PROFILE"; then
    abort "Cannot $action: '$rel' resolves outside the profile's shared state. Remove the link and retry."
  fi
  if transfer_file_refusal "$canonical_file"; then
    abort "Cannot $action: '$rel' $TRANSFER_FILE_REFUSAL. Remove it from shared state or replace it with inspectable non-secret text, then retry."
  fi
  TRANSFER_PLAN_RELS+=("$rel")
  TRANSFER_PLAN_SRCS+=("$canonical_file")
}

# Reset the copy plan and pin the two roots resolved content must stay within
# (the profile itself and its shared state root).
transfer_begin() {
  local profile_dir="$1" shared_root="$2"
  TRANSFER_PLAN_RELS=()
  TRANSFER_PLAN_SRCS=()
  TRANSFER_ALLOWED_PROFILE="$(transfer_canonical "$profile_dir")" || \
    abort "Profile directory '$profile_dir' does not exist."
  TRANSFER_ALLOWED_SHARED="$(transfer_canonical "$shared_root" 2>/dev/null || true)"
}

# Plan the copy of every declared shared path, skipping sessions/credentials
# and resolving each top-level entry before recursing.
transfer_collect_shared() {
  local manifest="$1" profile_dir="$2" shared_root="$3" action="$4"
  local rel
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    transfer_is_session_path "$manifest" "$rel" && continue
    transfer_is_credential_path "$manifest" "$rel" && continue
    transfer_profile_source "$manifest" "$profile_dir" "$rel" "$shared_root" || continue
    transfer_resolve_top "$TRANSFER_SOURCE" "$rel" "$shared_root" "$profile_dir" "$action"
    transfer_collect_path "$TRANSFER_RESOLVED" "$rel" "$manifest" "$action" true
  done < <(runtime_json_arr '.normalState.sharedPaths' "$manifest")
}

# Copy the planned files into dest_root, preserving mtimes and creating
# parents. Only plan entries are copied -- never discovered files.
transfer_materialize() {
  local dest_root="$1" i rel
  [ "${#TRANSFER_PLAN_RELS[@]}" -eq 0 ] && return 0
  for i in "${!TRANSFER_PLAN_RELS[@]}"; do
    rel="${TRANSFER_PLAN_RELS[$i]}"
    mkdir -p "$dest_root/$(dirname "$rel")"
    cp -p "${TRANSFER_PLAN_SRCS[$i]}" "$dest_root/$rel"
  done
}

# Isolated filesystem state lives under normalState.runtimeSubdir when declared.
transfer_isolated_state_root() {
  local manifest="$1" profile_dir="$2" state_subdir
  state_subdir="$(runtime_json_str '.normalState.runtimeSubdir' "$manifest")"
  printf '%s\n' "$profile_dir/${state_subdir:+$state_subdir/}"
}

# Write the transport manifest (adapter id, name, kind) that import and
# template-apply use to prove origin.
transfer_write_manifest() {
  local dest="$1" adapter_id="$2" name="$3" kind="$4"
  jq -n \
    --arg adapter_id "$adapter_id" \
    --arg name "$name" \
    --arg kind "$kind" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schemaVersion:2,adapterId:$adapter_id,name:$name,kind:$kind,createdUtc:$created}' > "$dest"
}

# The adapter's native shared-state root for this platform, or abort.
transfer_shared_root_for() {
  local manifest="$1" adapter_id="$2" root
  root="$(runtime_platform_root "$manifest")"
  [ -n "$root" ] || abort "Adapter '$adapter_id' has no normal-state root for $(platform)."
  printf '%s\n' "$root"
}

# Save a profile's shareable state as a named template under templates_root.
# Refuses an existing name; dry_run only lists the plan.
transfer_save_template() {
  local manifest="$1" profile_dir="$2" templates_root="$3" name="$4" dry_run="${5:-false}"
  local adapter_id shared_root staging dest i
  adapter_id="$(runtime_json_str '.id' "$manifest")"
  [ -n "$adapter_id" ] || abort "Adapter manifest '$manifest' has no id."
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || \
    abort "Template name '$name' invalid: must start with alphanumeric, contain only letters/numbers/hyphens"
  dest="$templates_root/$name"
  if [ "$dry_run" != true ] && [ -e "$dest" ]; then
    abort "Template '$name' already exists"
  fi
  shared_root="$(transfer_shared_root_for "$manifest" "$adapter_id")"
  transfer_begin "$profile_dir" "$shared_root"
  transfer_collect_shared "$manifest" "$profile_dir" "$shared_root" "save template '$name'"
  if [ "$dry_run" = true ]; then
    printf "Template '%s' would contain:\n" "$name"
    if [ "${#TRANSFER_PLAN_RELS[@]}" -gt 0 ]; then
      for i in "${!TRANSFER_PLAN_RELS[@]}"; do
        printf '  %s\n' "${TRANSFER_PLAN_RELS[$i]}"
      done
    fi
    return 0
  fi
  mkdir -p "$templates_root"
  staging="$templates_root/.staging.$name.$$"
  rm -rf "$staging"
  mkdir -p "$staging"
  transfer_materialize "$staging"
  transfer_write_manifest "$staging/$TRANSFER_MANIFEST_NAME" "$adapter_id" "$name" template
  mv "$staging" "$dest"
}

# Print the adapter id recorded in a template's transport manifest; aborts
# when the manifest is missing or invalid (hand-made template dirs rejected).
transfer_template_adapter_id() {
  local template_dir="$1" id
  if [ ! -f "$template_dir/$TRANSFER_MANIFEST_NAME" ]; then
    abort "Template '$(basename "$template_dir")' has no manifest; it was not saved by this version of nini-agents."
  fi
  id="$(runtime_json_str '.adapterId' "$template_dir/$TRANSFER_MANIFEST_NAME")"
  [ -n "$id" ] || abort "Template '$(basename "$template_dir")' manifest is invalid."
  printf '%s\n' "$id"
}

# True when a payload path is one of the adapter-declared shared paths or a
# descendant. Transport/profile metadata are handled separately.
transfer_is_shared_payload_path() {
  local manifest="$1" rel="$2" declared
  while IFS= read -r declared; do
    [ -z "$declared" ] && continue
    case "$rel" in
      "$declared"|"$declared"/*) return 0 ;;
    esac
  done < <(runtime_json_arr '.normalState.sharedPaths' "$manifest")
  return 1
}

# Collect a template payload only after enforcing the same boundary as import.
# Unlike save, forbidden entries are rejected rather than silently omitted.
transfer_collect_template_path() {
  local src="$1" rel="$2" manifest="$3" entry name
  [ "$rel" = "$TRANSFER_MANIFEST_NAME" ] && return 0
  if [ -L "$src" ]; then
    abort "Template '$(basename "$TRANSFER_TEMPLATE_ROOT")' contains link '$rel'; templates may contain only regular files and directories."
  fi
  if transfer_is_credential_path "$manifest" "$rel" || \
     transfer_is_session_path "$manifest" "$rel" || \
     [[ "$rel" == .runtime || "$rel" == .runtime/* ]]; then
    abort "Template '$(basename "$TRANSFER_TEMPLATE_ROOT")' contains forbidden path '$rel'."
  fi
  transfer_is_shared_payload_path "$manifest" "$rel" || \
    abort "Template '$(basename "$TRANSFER_TEMPLATE_ROOT")' contains undeclared path '$rel'."
  if [ -d "$src" ]; then
    while IFS= read -r -d '' entry; do
      name="$(basename "$entry")"
      transfer_collect_template_path "$entry" "$rel/$name" "$manifest"
    done < <(find "$src" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    return 0
  fi
  [ -f "$src" ] || abort "Template entry '$rel' is not a regular file or directory."
  [ "$(file_nlink "$src")" -le 1 ] || abort "Template file '$rel' is a hardlink and cannot be transferred safely."
  if transfer_file_refusal "$src"; then
    abort "Template '$(basename "$TRANSFER_TEMPLATE_ROOT")' file '$rel' $TRANSFER_FILE_REFUSAL."
  fi
  TRANSFER_PLAN_RELS+=("$rel")
  TRANSFER_PLAN_SRCS+=("$src")
}

# Validate adapter ownership and every payload entry, producing the copy plan.
transfer_assert_template_compatible() {
  local template_dir="$1" manifest="$2" tpl_id adapter_id entry name
  tpl_id="$(transfer_template_adapter_id "$template_dir")" || exit 1
  adapter_id="$(runtime_json_str '.id' "$manifest")"
  if [ "$tpl_id" != "$adapter_id" ]; then
    abort "Template '$(basename "$template_dir")' was saved from adapter '$tpl_id' and cannot be applied to '$adapter_id'. Save a new template from a '$adapter_id' profile."
  fi
  TRANSFER_PLAN_RELS=()
  TRANSFER_PLAN_SRCS=()
  TRANSFER_TEMPLATE_ROOT="$template_dir"
  while IFS= read -r -d '' entry; do
    name="$(basename "$entry")"
    transfer_collect_template_path "$entry" "$name" "$manifest"
  done < <(find "$template_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

# Apply a validated template where launch will read it: profile root for an
# isolated profile, native shared root for an ordinary account overlay.
transfer_apply_template() {
  local template_dir="$1" manifest="$2" profile_dir="$3" isolated="$4" destination adapter_id
  transfer_assert_template_compatible "$template_dir" "$manifest"
  if [ "$isolated" = true ]; then
    destination="$(transfer_isolated_state_root "$manifest" "$profile_dir")"
  else
    adapter_id="$(runtime_json_str '.id' "$manifest")"
    destination="$(transfer_shared_root_for "$manifest" "$adapter_id")"
  fi
  mkdir -p "$destination"
  transfer_materialize "$destination"
}

# Install adapter-declared payload from staging into the native shared root.
transfer_install_shared_state() {
  local manifest="$1" staging="$2" adapter_id shared_root rel src dst
  adapter_id="$(runtime_json_str '.id' "$manifest")"
  shared_root="$(transfer_shared_root_for "$manifest" "$adapter_id")"
  mkdir -p "$shared_root"
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    src="$staging/$rel"
    [ -e "$src" ] || continue
    dst="$shared_root/$rel"
    rm -rf "$dst"
    mkdir -p "$(dirname "$dst")"
    mv "$src" "$dst"
  done < <(runtime_json_arr '.normalState.sharedPaths' "$manifest")
}

# Write isolated metadata with a fresh identity and marker.
transfer_write_isolated_metadata() {
  local manifest="$1" dest_dir="$2"
  jq -n \
    --arg adapter_id "$(runtime_json_str '.id' "$manifest")" \
    --arg profile_id "$(runtime_new_profile_id)" \
    '{schemaVersion:2,adapterId:$adapter_id,profileId:$profile_id,mode:"isolated"}' \
    > "$dest_dir/.profile.json"
  : > "$dest_dir/.isolated"
}

# Write a .tar.gz of the profile's shareable state plus transport metadata.
# The staging dir is removed on every path, success or failure.
transfer_export_profile() {
  local manifest="$1" profile_dir="$2" out="$3" profile_name="$4"
  local adapter_id shared_root staging out_abs
  adapter_id="$(runtime_json_str '.id' "$manifest")"
  [ -n "$adapter_id" ] || abort "Adapter manifest '$manifest' has no id."
  shared_root="$(transfer_shared_root_for "$manifest" "$adapter_id")"
  transfer_begin "$profile_dir" "$shared_root"
  transfer_collect_shared "$manifest" "$profile_dir" "$shared_root" "export profile '$profile_name'"
  staging="$(mktemp -d "${TMPDIR:-/tmp}/multicli-export.XXXXXX")" || \
    abort "Cannot create a staging directory for the export."
  if ! transfer_materialize "$staging"; then
    rm -rf "$staging"
    abort "Export failed while staging files."
  fi
  # .profile.json is metadata only (schemaVersion/adapterId/profileId/mode) and
  # holds no secrets; import always regenerates the profileId.
  if [ -f "$profile_dir/.profile.json" ]; then
    cp "$profile_dir/.profile.json" "$staging/.profile.json"
  fi
  transfer_write_manifest "$staging/$TRANSFER_MANIFEST_NAME" "$adapter_id" "$profile_name" export
  mkdir -p "$(dirname "$out")"
  out_abs="$(cd "$(dirname "$out")" && pwd -P)/$(basename "$out")"
  rm -f "$out_abs"
  if ! (cd "$staging" && tar -czf "$out_abs" .); then
    rm -rf "$staging"
    abort "Export failed while writing '$out'."
  fi
  rm -rf "$staging"
}

# One archive entry name with separators normalized and ./ and trailing /
# stripped, so the safety checks see the canonical relative form.
transfer_normalize_entry() {
  local name="$1"
  name="${name//\\//}"
  while [[ "$name" == ./* ]]; do name="${name#./}"; done
  name="${name%/}"
  printf '%s\n' "$name"
}

# True when a payload path is declared shared state, a descendant, or a parent
# directory needed to contain a declared path.
transfer_is_payload_path() {
  local manifest="$1" rel="$2" declared
  while IFS= read -r declared; do
    [ -z "$declared" ] && continue
    case "$rel" in
      "$declared"|"$declared"/*) return 0 ;;
    esac
    case "$declared" in
      "$rel"/*) return 0 ;;
    esac
  done < <(runtime_json_arr '.normalState.sharedPaths' "$manifest")
  return 1
}

# Reject one archive entry name that is unsafe or outside the adapter-declared
# shared-state allowlist. Empty/root and transport metadata entries are allowed.
transfer_assert_entry_safe() {
  local name="$1" manifest="$2"
  case "$name" in
    ""|.) return 0 ;;
  esac
  case "/$name/" in
    */../*) abort "Refusing to import: archive entry '$name' escapes the profile directory." ;;
  esac
  case "$name" in
    /*) abort "Refusing to import: archive entry '$name' is an absolute path." ;;
    [A-Za-z]:*) abort "Refusing to import: archive entry '$name' is a drive-qualified path." ;;
    *:*) abort "Refusing to import: archive entry '$name' contains an alternate data stream." ;;
  esac
  if transfer_is_credential_path "$manifest" "$name"; then
    abort "Refusing to import: archive entry '$name' is a credential path."
  fi
  case "$name" in
    .runtime|.runtime/*) abort "Refusing to import: archive entry '$name' is disposable runtime state." ;;
    "$TRANSFER_MANIFEST_NAME"|.profile.json) return 0 ;;
  esac
  transfer_is_payload_path "$manifest" "$name" || \
    abort "Refusing to import: archive entry '$name' is not adapter-declared shared state."
}

# Inspect every archive entry before anything is extracted: names must be
# relative, unique, and free of credentials; types must be file or directory.
transfer_inspect_archive() {
  local archive="$1" manifest="$2"
  local entry name lower line seen=""
  tar -tzf "$archive" >/dev/null 2>&1 || \
    abort "Import failed: '$archive' is not a readable .tar.gz archive."
  while IFS= read -r entry; do
    name="$(transfer_normalize_entry "$entry")"
    transfer_assert_entry_safe "$name" "$manifest"
    if [ -z "$name" ] || [ "$name" = "." ]; then continue; fi
    lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    if printf '%s' "$seen" | grep -qxF "$lower"; then
      abort "Refusing to import: archive contains duplicate entry '$name'."
    fi
    seen="${seen}${lower}
"
  done < <(tar -tzf "$archive" 2>/dev/null)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "${line:0:1}" in
      -|d) ;;
      *) abort "Refusing to import: archive entry is not a regular file or directory: ${line}" ;;
    esac
  done < <(tar -tzvf "$archive" 2>/dev/null)
}

# Remove the import staging dir and abort with the given message.
transfer_fail_import() {
  local staging="$1" message="$2"
  rm -rf "$staging"
  abort "$message"
}

# Defense in depth behind transfer_inspect_archive: nothing that physically
# appeared in staging may be a link or a special file, and no extracted text
# file may match a secret pattern (the archive may be hand-crafted).
transfer_verify_staging() {
  local staging="$1" entry rel
  while IFS= read -r -d '' entry; do
    rel="${entry#"$staging"/}"
    if [ -L "$entry" ]; then
      transfer_fail_import "$staging" "Refusing to import: extracted entry '$rel' is a link."
    fi
    if [ ! -f "$entry" ] && [ ! -d "$entry" ]; then
      transfer_fail_import "$staging" "Refusing to import: extracted entry '$rel' is not a regular file or directory."
    fi
    if [ -f "$entry" ] && transfer_file_refusal "$entry"; then
      transfer_fail_import "$staging" "Refusing to import: '$rel' $TRANSFER_FILE_REFUSAL."
    fi
  done < <(find "$staging" -mindepth 1 -print0 2>/dev/null)
}

# Import an export archive into a fresh profile dir: entries are inspected
# before extraction, staging is re-verified after extraction, the archived
# adapter must match, and the profile gets a fresh identity and empty
# credential placeholders. Aborts without creating dest_dir on any refusal.
transfer_import_profile() {
  local archive="$1" manifest="$2" dest_dir="$3"
  local adapter_id staging archived_adapter parent
  adapter_id="$(runtime_json_str '.id' "$manifest")"
  [ -n "$adapter_id" ] || abort "Adapter manifest '$manifest' has no id."
  [ -f "$archive" ] || abort "File not found: $archive"
  if [ -e "$dest_dir" ]; then
    abort "Profile destination '$dest_dir' already exists"
  fi
  transfer_inspect_archive "$archive" "$manifest"

  parent="$(dirname "$dest_dir")"
  mkdir -p "$parent"
  staging="$parent/.import-staging.$$"
  rm -rf "$staging"
  (umask 077; mkdir -p "$staging")
  if ! tar -xzf "$archive" -C "$staging" 2>/dev/null; then
    transfer_fail_import "$staging" "Import failed: '$archive' could not be extracted."
  fi
  transfer_verify_staging "$staging"

  if [ ! -f "$staging/$TRANSFER_MANIFEST_NAME" ]; then
    transfer_fail_import "$staging" "Refusing to import: archive has no nini-agents manifest; only archives written by nini-agents export are accepted."
  fi
  archived_adapter="$(runtime_json_str '.adapterId' "$staging/$TRANSFER_MANIFEST_NAME")"
  if [ -z "$archived_adapter" ]; then
    transfer_fail_import "$staging" "Refusing to import: archive manifest is invalid."
  fi
  if [ "$archived_adapter" != "$adapter_id" ]; then
    transfer_fail_import "$staging" "Refusing to import: archive was exported from adapter '$archived_adapter' and cannot be imported as '$adapter_id'."
  fi

  local archived_mode="accountOverlay"
  if [ -f "$staging/.profile.json" ]; then
    [ "$(runtime_json_str '.mode' "$staging/.profile.json" 2>/dev/null || true)" = isolated ] && archived_mode=isolated
    rm -f "$staging/.profile.json"
  fi
  rm -f "$staging/$TRANSFER_MANIFEST_NAME"
  mkdir -p "$dest_dir"
  if [ "$archived_mode" = isolated ]; then
    (
      shopt -s dotglob nullglob
      for item in "$staging"/*; do mv "$item" "$dest_dir"/; done
    )
    transfer_write_isolated_metadata "$manifest" "$dest_dir"
  else
    transfer_install_shared_state "$manifest" "$staging"
    runtime_initialize_profile "$manifest" "$dest_dir"
  fi
  rm -rf "$staging"
}

# =============================================================================
# Credential-bearing transactional movement
# =============================================================================
#
# This protocol is deliberately separate from template/export/import above.
# Those flows remain credential-free. A caller supplies both the candidate
# transport and the process probe; the engine alone decides ownership,
# staging, verification, activation and rollback. Callers must never use a
# probe that cannot prove the relevant tool is closed.

move_set_result() {
  MOVE_RESULT_CODE="$1"
  MOVE_RESULT_STATE="$2"
  MOVE_RESULT_FORMAT="${3:-${MOVE_PROFILE_FORMAT:-unknown}}"
}

move_fail() {
  move_set_result "$1" "$2" "${3:-${MOVE_PROFILE_FORMAT:-unknown}}"
  return 1
}

move_safe_component() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

move_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  else
    return 1
  fi
}

move_file_identity() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null
}

move_expected_runtime_hardlink() {
  local manifest="$1" profile="$2" rel="$3" source="$4" credential_rel state_subdir runtime_path
  [ "$MOVE_PROFILE_FORMAT" = v2 ] && [ "$MOVE_PROFILE_MODE" = accountOverlay ] || return 1
  case "$rel" in auth/*) credential_rel="${rel#auth/}" ;; *) return 1 ;; esac
  move_relative_matches_declaration "$manifest" "$credential_rel" '.account.credentialFiles' || return 1
  [ "$(file_nlink "$source")" -eq 2 ] || return 1
  state_subdir="$(runtime_json_str '.normalState.runtimeSubdir' "$manifest")"
  runtime_path="$profile/.runtime/${state_subdir:+$state_subdir/}$credential_rel"
  [ -f "$runtime_path" ] && [ ! -L "$runtime_path" ] || return 1
  [ "$(move_file_identity "$source")" = "$(move_file_identity "$runtime_path")" ]
}

# True when a relative entry is equal to, below, or a parent of a declared
# adapter path. Parent directories are allowed only to contain declarations.
move_relative_matches_declaration() {
  local manifest="$1" rel="$2" jq_path="$3" declared
  while IFS= read -r declared; do
    [ -n "$declared" ] || continue
    case "$rel" in
      "$declared"|"$declared"/*) return 0 ;;
    esac
    case "$declared" in
      "$rel"/*) return 0 ;;
    esac
  done < <(runtime_json_arr "$jq_path" "$manifest")
  return 1
}

move_relative_allowed() {
  local manifest="$1" rel="$2" format="$3" mode="$4" state_subdir declared_rel
  case "$rel" in
    *:*|*\\*|*$'\n'*|*$'\r'*) return 1 ;;
  esac

  if [ "$format" = v2 ]; then
    case "$rel" in
      .profile.json|.cli) return 0 ;;
      auth) return 0 ;;
      auth/*) move_relative_matches_declaration "$manifest" "${rel#auth/}" '.account.credentialFiles'; return ;;
      .runtime|.runtime/*) return 0 ;;
    esac
    if [ "$mode" = isolated ]; then
      [ "$rel" = .isolated ] && return 0
      state_subdir="$(runtime_json_str '.normalState.runtimeSubdir' "$manifest")"
      declared_rel="$rel"
      if [ -n "$state_subdir" ]; then
        [ "$rel" = "$state_subdir" ] && return 0
        case "$rel" in
          "$state_subdir"/*) declared_rel="${rel#"$state_subdir"/}" ;;
          *) return 1 ;;
        esac
      fi
      move_relative_matches_declaration "$manifest" "$declared_rel" '.normalState.sharedPaths' && return 0
      move_relative_matches_declaration "$manifest" "$declared_rel" '.normalState.sessionPaths' && return 0
      move_relative_matches_declaration "$manifest" "$declared_rel" '.normalState.unsafePaths' && return 0
    fi
    return 1
  fi

  [ "$rel" = .cli ] && return 0
  move_relative_matches_declaration "$manifest" "$rel" '.account.credentialFiles' && return 0
  move_relative_matches_declaration "$manifest" "$rel" '.normalState.sharedPaths' && return 0
  move_relative_matches_declaration "$manifest" "$rel" '.normalState.sessionPaths' && return 0
  move_relative_matches_declaration "$manifest" "$rel" '.normalState.unsafePaths' && return 0
  return 1
}

# Detect and validate profile structure without exposing JSON values. Runtime
# is accepted only for schema v2 and is excluded from transport: it is rebuilt
# from the adapter at the destination and never becomes a credential source.
move_validate_profile() {
  local manifest="$1" profile="$2" adapter_id mechanism metadata mode relative credential entry rel
  MOVE_PROFILE_FORMAT=unknown
  MOVE_PROFILE_MODE=unknown

  [ -d "$profile" ] && [ ! -L "$profile" ] || return 20
  adapter_id="$(runtime_json_str '.id' "$manifest")"
  mechanism="$(runtime_json_str '.account.mechanism' "$manifest")"
  [ -n "$adapter_id" ] && [ "$mechanism" = fileOverlay ] || return 21

  metadata="$profile/.profile.json"
  if [ -e "$metadata" ] || [ -L "$metadata" ]; then
    MOVE_PROFILE_FORMAT=v2
    [ -f "$metadata" ] && [ ! -L "$metadata" ] || return 22
    jq -e --arg adapter "$adapter_id" '
      type == "object" and .schemaVersion == 2 and
      .adapterId == $adapter and (.profileId | type == "string" and length > 0) and
      (.mode == "accountOverlay" or .mode == "isolated")
    ' "$metadata" >/dev/null 2>&1 || return 22
    mode="$(runtime_json_str '.mode' "$metadata")"
    MOVE_PROFILE_MODE="$mode"
    while IFS= read -r relative; do
      [ -n "$relative" ] || continue
      credential="$profile/auth/$relative"
      [ -f "$credential" ] && [ ! -L "$credential" ] || return 23
      if [ "$(basename "$relative")" = auth.json ]; then
        jq -e 'type == "object"' "$credential" >/dev/null 2>&1 || return 24
      fi
    done < <(runtime_json_arr '.account.credentialFiles' "$manifest")
  else
    MOVE_PROFILE_FORMAT=legacy
    MOVE_PROFILE_MODE=legacy
    credential="$profile/auth.json"
    [ -f "$credential" ] && [ ! -L "$credential" ] || return 23
    jq -e 'type == "object"' "$credential" >/dev/null 2>&1 || return 24
  fi

  while IFS= read -r -d '' entry; do
    rel="${entry#"$profile"/}"
    # Schema-v2 runtime is disposable and never crosses the transport. Reject
    # a replaced runtime root, then ignore its derived contents.
    if [ "$MOVE_PROFILE_FORMAT" = v2 ]; then
      case "$rel" in
        .runtime)
          [ -d "$entry" ] && [ ! -L "$entry" ] || return 25
          continue
          ;;
        .runtime/*) continue ;;
      esac
    fi
    move_relative_allowed "$manifest" "$rel" "$MOVE_PROFILE_FORMAT" "$MOVE_PROFILE_MODE" || return 26
    [ ! -L "$entry" ] || return 25
    if [ -f "$entry" ]; then
      if [ "$(file_nlink "$entry")" -gt 1 ]; then
        move_expected_runtime_hardlink "$manifest" "$profile" "$rel" "$entry" || return 27
      fi
    elif [ ! -d "$entry" ]; then
      return 28
    fi
  done < <(find "$profile" -mindepth 1 -print0 2>/dev/null)
  return 0
}

move_validation_failure() {
  case "$1" in
    20) move_fail source_missing preflight_rejected ;;
    21) move_fail unsupported_mechanism preflight_rejected ;;
    22) move_fail invalid_metadata preflight_rejected ;;
    23) move_fail missing_credential preflight_rejected ;;
    24) move_fail invalid_auth_json preflight_rejected ;;
    25) move_fail unsafe_link preflight_rejected ;;
    26) move_fail unknown_content preflight_rejected ;;
    27) move_fail unsafe_hardlink preflight_rejected ;;
    *)  move_fail unsafe_entry preflight_rejected ;;
  esac
}

# Build a deterministic structure/size/hash inventory, excluding disposable
# schema-v2 runtime. The inventory contains no file contents.
move_write_inventory() {
  local root="$1" output="$2" entry rel digest size
  : > "$output"
  while IFS= read -r -d '' entry; do
    rel="${entry#"$root"/}"
    case "$rel" in .runtime|.runtime/*) continue ;; esac
    if [ -d "$entry" ]; then
      printf 'd\t%s\n' "$rel" >> "$output"
    elif [ -f "$entry" ]; then
      digest="$(move_sha256 "$entry")" || return 1
      size="$(file_size "$entry")"
      printf 'f\t%s\t%s\t%s\n' "$rel" "$size" "$digest" >> "$output"
    else
      return 1
    fi
  done < <(find "$root" -mindepth 1 -print0 2>/dev/null)
  LC_ALL=C sort "$output" -o "$output"
}

move_trees_equal() {
  local left="$1" right="$2" left_inventory right_inventory result=1
  left_inventory="$(mktemp "${TMPDIR:-/tmp}/nini-move-left.XXXXXX")" || return 1
  right_inventory="$(mktemp "${TMPDIR:-/tmp}/nini-move-right.XXXXXX")" || {
    rm -f "$left_inventory"
    return 1
  }
  if move_write_inventory "$left" "$left_inventory" &&
     move_write_inventory "$right" "$right_inventory" &&
     cmp -s "$left_inventory" "$right_inventory"; then
    result=0
  fi
  rm -f "$left_inventory" "$right_inventory"
  return "$result"
}

# Default synthetic/local transport. Remote transports may replace this
# callback, but must only populate the already-reserved staging directory.
move_copy_candidate_local() {
  local source="$1" staging="$2" item name
  (
    shopt -s dotglob nullglob
    for item in "$source"/*; do
      name="$(basename "$item")"
      [ "$name" = .runtime ] && continue
      cp -pR -- "$item" "$staging/" || exit 1
    done
  )
}

move_activate_candidate() {
  mv -- "$1" "$2"
}

move_deactivate_source() {
  mv -- "$1" "$2"
}

move_quarantine_destination() {
  local destination="$1" failed="$2"
  [ ! -e "$failed" ] && [ ! -L "$failed" ] || return 1
  mkdir -p "$(dirname "$failed")" || return 1
  mv -- "$destination" "$failed"
}

move_check_probe() {
  local probe="$1" path="$2" rc
  if "$probe" "$path"; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] && return 1
  return 2
}

move_restore_after_failure() {
  local source="$1" backup="$2" destination="$3" failed="$4" code="$5"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if ! move_quarantine_destination "$destination" "$failed"; then
      move_fail rollback_failed ownership_indeterminate
      return 1
    fi
  fi
  if mv -- "$backup" "$source"; then
    move_fail "$code" source_restored
    return 1
  fi
  move_fail rollback_failed ownership_indeterminate
}

# Transactionally move one profile between two local ownership roots. The
# caller-provided process probe returns 0 when busy, 1 when proven idle, and
# any other status when it cannot prove either state. The transport callback
# copies source into the pre-created staging directory without activating it.
move_profile_transaction() {
  local manifest="$1" source_root="$2" destination_root="$3" profile_name="$4"
  local operation_id="$5" process_probe="$6" transport_copy="$7" dry_run="${8:-false}"
  local source destination staging backup failed lock rc

  MOVE_PROFILE_FORMAT=unknown
  MOVE_PROFILE_MODE=unknown
  move_set_result uninitialized preflight unknown

  move_safe_component "$profile_name" && move_safe_component "$operation_id" || {
    move_fail invalid_identifier preflight_rejected unknown
    return 1
  }
  declare -F "$process_probe" >/dev/null 2>&1 && declare -F "$transport_copy" >/dev/null 2>&1 || {
    move_fail invalid_callback preflight_rejected unknown
    return 1
  }
  [ -d "$source_root" ] && [ ! -L "$source_root" ] &&
    [ -d "$destination_root" ] && [ ! -L "$destination_root" ] || {
      move_fail unsafe_root preflight_rejected unknown
      return 1
    }
  [ "$(transfer_canonical "$source_root")" != "$(transfer_canonical "$destination_root")" ] || {
    move_fail unsafe_root preflight_rejected unknown
    return 1
  }
  source="$source_root/$profile_name"
  destination="$destination_root/$profile_name"
  staging="$destination_root/.staging/$profile_name.$operation_id"
  backup="$source_root/.inactive/$profile_name.$operation_id"
  failed="$destination_root/.failed/$profile_name.$operation_id"
  lock="$source_root/.move-lock.$profile_name"

  local transaction_parent
  for transaction_parent in "$(dirname "$staging")" "$(dirname "$backup")" "$(dirname "$failed")"; do
    if [ -e "$transaction_parent" ] || [ -L "$transaction_parent" ]; then
      [ -d "$transaction_parent" ] && [ ! -L "$transaction_parent" ] || {
        move_fail unsafe_root preflight_rejected unknown
        return 1
      }
    fi
  done

  if [ -e "$destination" ] || [ -L "$destination" ]; then
    move_fail destination_active preflight_rejected unknown
    return 1
  fi
  if move_validate_profile "$manifest" "$source"; then
    :
  else
    rc=$?
    move_validation_failure "$rc"
    return 1
  fi
  if [ -e "$staging" ] || [ -L "$staging" ]; then
    move_fail staging_conflict preflight_rejected
    return 1
  fi
  if [ -e "$backup" ] || [ -L "$backup" ]; then
    move_fail backup_conflict preflight_rejected
    return 1
  fi
  if [ -e "$failed" ] || [ -L "$failed" ]; then
    move_fail failed_artifact_conflict preflight_rejected
    return 1
  fi
  if [ -e "$lock" ] || [ -L "$lock" ]; then
    move_fail transaction_locked preflight_rejected
    return 1
  fi

  if move_check_probe "$process_probe" "$source"; then
    move_fail process_active preflight_rejected
    return 1
  else
    rc=$?
    [ "$rc" -eq 1 ] || { move_fail process_probe_failed preflight_rejected; return 1; }
  fi
  if move_check_probe "$process_probe" "$destination"; then
    move_fail process_active preflight_rejected
    return 1
  else
    rc=$?
    [ "$rc" -eq 1 ] || { move_fail process_probe_failed preflight_rejected; return 1; }
  fi

  if [ "$dry_run" = true ]; then
    move_set_result dry_run validated
    return 0
  fi

  mkdir -p "$(dirname "$staging")" || { move_fail staging_create_failed source_active; return 1; }
  (umask 077; mkdir "$staging") || { move_fail staging_create_failed source_active; return 1; }
  if ! "$transport_copy" "$source" "$staging"; then
    move_fail transport_failed staging_preserved
    return 1
  fi
  if ! move_trees_equal "$source" "$staging"; then
    move_fail integrity_mismatch staging_rejected
    return 1
  fi

  # Serialize the ownership swap. Staging is allowed before the lock, but the
  # source, destination and hashes are checked again while it is held.
  if ! mkdir "$lock" 2>/dev/null; then
    move_fail transaction_locked staging_preserved
    return 1
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    rmdir "$lock" 2>/dev/null || true
    move_fail destination_appeared staging_preserved
    return 1
  fi
  if ! move_validate_profile "$manifest" "$source" ||
     ! move_trees_equal "$source" "$staging"; then
    rmdir "$lock" 2>/dev/null || true
    move_fail integrity_mismatch staging_rejected
    return 1
  fi

  if move_check_probe "$process_probe" "$source"; then
    rmdir "$lock" 2>/dev/null || true
    move_fail process_appeared staging_preserved
    return 1
  else
    rc=$?
    [ "$rc" -eq 1 ] || { rmdir "$lock" 2>/dev/null || true; move_fail process_probe_failed staging_preserved; return 1; }
  fi
  if move_check_probe "$process_probe" "$destination"; then
    rmdir "$lock" 2>/dev/null || true
    move_fail process_appeared staging_preserved
    return 1
  else
    rc=$?
    [ "$rc" -eq 1 ] || { rmdir "$lock" 2>/dev/null || true; move_fail process_probe_failed staging_preserved; return 1; }
  fi

  mkdir -p "$(dirname "$backup")" || { rmdir "$lock" 2>/dev/null || true; move_fail backup_prepare_failed source_active; return 1; }
  if ! move_deactivate_source "$source" "$backup"; then
    rmdir "$lock" 2>/dev/null || true
    move_fail source_deactivation_failed source_active
    return 1
  fi
  if ! move_activate_candidate "$staging" "$destination"; then
    move_restore_after_failure "$source" "$backup" "$destination" "$failed" activation_failed_rolled_back
    rmdir "$lock" 2>/dev/null || true
    return 1
  fi

  if move_validate_profile "$manifest" "$destination"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ] || ! move_trees_equal "$backup" "$destination"; then
    move_restore_after_failure "$source" "$backup" "$destination" "$failed" destination_invalid_rolled_back
    rmdir "$lock" 2>/dev/null || true
    return 1
  fi

  if [ "$MOVE_PROFILE_FORMAT" = v2 ] && [ "$MOVE_PROFILE_MODE" = accountOverlay ]; then
    if ! runtime_build_overlay "$manifest" "$destination" >/dev/null; then
      move_restore_after_failure "$source" "$backup" "$destination" "$failed" destination_runtime_failed_rolled_back
      rmdir "$lock" 2>/dev/null || true
      return 1
    fi
    if ! runtime_overlay_is_current "$manifest" "$destination/.runtime"; then
      move_restore_after_failure "$source" "$backup" "$destination" "$failed" destination_runtime_failed_rolled_back
      rmdir "$lock" 2>/dev/null || true
      return 1
    fi
  fi

  # Final byte/hash comparison after runtime reconstruction. Runtime is
  # excluded, so it cannot mask a changed canonical credential or metadata.
  if ! move_trees_equal "$backup" "$destination"; then
    move_restore_after_failure "$source" "$backup" "$destination" "$failed" destination_invalid_rolled_back
    rmdir "$lock" 2>/dev/null || true
    return 1
  fi
  if ! rmdir "$lock" 2>/dev/null; then
    move_set_result lock_release_failed destination_active
    return 1
  fi
  move_set_result ok destination_active
  return 0
}
