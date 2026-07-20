#!/usr/bin/env bash
# Allowlist-driven profile transfer (templates, export, import) for schema-v2
# profiles. Only adapter-declared normalState.sharedPaths content is copied;
# credentials, sessions, links, hardlinks, and unclassified files never travel.
#
# Sourced by multi-cli after lib/multicli-runtime.sh; relies on the launcher's
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

# Credential paths are the adapter-declared credential files, the legacy
# hardcoded credential basenames at any depth, and the profile auth boundary.
transfer_is_credential_path() {
  local manifest="$1" rel="$2"
  transfer_is_declared_path '.account.credentialFiles' "$rel" "$manifest" && return 0
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

# Where the profile resolves a declared shared path to: the overlay view when
# it exists, otherwise the native shared root. Sets TRANSFER_SOURCE.
transfer_profile_source() {
  local profile_dir="$1" rel="$2" shared_root="$3" candidate
  TRANSFER_SOURCE=""
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
      abort "Cannot $action: '$rel' is a link with no resolvable target. Rebuild the profile runtime with \`multi-cli launch\` and retry."
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

# True when a text file below the scan cap matches a secret-shaped pattern;
# oversized and binary files are never scanned (and never match).
transfer_file_has_secret() {
  local src="$1"
  [ "$(file_size "$src")" -gt "$TRANSFER_SECRET_SCAN_MAX_BYTES" ] && return 1
  # grep -I treats binary files as non-matching, so binaries are skipped.
  grep -Iq -e 'sk-' -e 'access_token' -e 'refresh_token' -e 'id_token' -e 'Bearer ' -- "$src" 2>/dev/null
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
  if transfer_file_has_secret "$canonical_file"; then
    abort "Cannot $action: '$rel' looks like it contains a secret (credential pattern match). Remove the secret from shared state and retry."
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
    transfer_profile_source "$profile_dir" "$rel" "$shared_root" || continue
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
    abort "Template '$(basename "$template_dir")' has no manifest; it was not saved by this version of multi-cli."
  fi
  id="$(runtime_json_str '.adapterId' "$template_dir/$TRANSFER_MANIFEST_NAME")"
  [ -n "$id" ] || abort "Template '$(basename "$template_dir")' manifest is invalid."
  printf '%s\n' "$id"
}

# Abort unless the template was saved from the same adapter it is applied to.
transfer_assert_template_compatible() {
  local template_dir="$1" manifest="$2" tpl_id adapter_id
  tpl_id="$(transfer_template_adapter_id "$template_dir")" || exit 1
  adapter_id="$(runtime_json_str '.id' "$manifest")"
  if [ "$tpl_id" != "$adapter_id" ]; then
    abort "Template '$(basename "$template_dir")' was saved from adapter '$tpl_id' and cannot be applied to '$adapter_id'. Save a new template from a '$adapter_id' profile."
  fi
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

# Reject one archive entry name that is absolute, drive-qualified, carries an
# alternate data stream, escapes via '..', is a credential, or is runtime
# state. Empty/root entries are allowed.
transfer_assert_entry_safe() {
  local name="$1" manifest="$2"
  case "$name" in
    ""|.) return 0 ;;
    /*) abort "Refusing to import: archive entry '$name' is an absolute path." ;;
    [A-Za-z]:*) abort "Refusing to import: archive entry '$name' is a drive-qualified path." ;;
    *:*) abort "Refusing to import: archive entry '$name' contains an alternate data stream." ;;
  esac
  case "/$name/" in
    */../*) abort "Refusing to import: archive entry '$name' escapes the profile directory." ;;
  esac
  if transfer_is_credential_path "$manifest" "$name"; then
    abort "Refusing to import: archive entry '$name' is a credential path."
  fi
  case "$name" in
    .runtime|.runtime/*) abort "Refusing to import: archive entry '$name' is disposable runtime state." ;;
  esac
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
    if [ -f "$entry" ] && transfer_file_has_secret "$entry"; then
      transfer_fail_import "$staging" "Refusing to import: '$rel' looks like it contains a secret (credential pattern match)."
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
    transfer_fail_import "$staging" "Refusing to import: archive has no multi-cli manifest; only archives written by multi-cli export are accepted."
  fi
  archived_adapter="$(runtime_json_str '.adapterId' "$staging/$TRANSFER_MANIFEST_NAME")"
  if [ -z "$archived_adapter" ]; then
    transfer_fail_import "$staging" "Refusing to import: archive manifest is invalid."
  fi
  if [ "$archived_adapter" != "$adapter_id" ]; then
    transfer_fail_import "$staging" "Refusing to import: archive was exported from adapter '$archived_adapter' and cannot be imported as '$adapter_id'."
  fi

  # The manifest is transport metadata, not profile content.
  rm -f "$staging/$TRANSFER_MANIFEST_NAME"
  mkdir -p "$dest_dir"
  (
    shopt -s dotglob nullglob
    for item in "$staging"/*; do mv "$item" "$dest_dir"/; done
  )
  rmdir "$staging"
  # Fresh stable identity and empty credential placeholders: the imported
  # profile must authenticate again.
  runtime_initialize_profile "$manifest" "$dest_dir"
}
