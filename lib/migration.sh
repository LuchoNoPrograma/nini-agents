#!/usr/bin/env bash
# Legacy -> schema-v2 migration engine for multi-cli.
#
# Sourced by the multi-cli launcher (which provides abort, adapter_path,
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
#   - legacy --shared links are recognized and left in place;
#   - entries the adapter does not declare (or that match both credential and
#     shared declarations) refuse the migration before anything is written;
#   - every filesystem operation is journaled to
#     <profile>/.migration-journal.json so a failure leaves a
#     roll-forward/rollback report on disk. All moves are same-volume atomic.

MIGRATION_JOURNAL_NAME=".migration-journal.json"

# Unit separator: ops carry empty fields, so tab/space IFS collapsing is
# unacceptable here.
MIGRATION_OP_SEP=$'\x1f'

MIGRATION_CREDS=()
MIGRATION_SHARED=()
MIGRATION_SESSION=()
MIGRATION_ENTRIES=()
MIGRATION_UNKNOWN=()
MIGRATION_OVERLAP=()
MIGRATION_OPS=()

# True when pdir is a profile directory without schema-v2 metadata.
migration_is_legacy_profile() {
  local pdir="$1"
  [ -d "$pdir" ] && [ ! -e "$pdir/.profile.json" ]
}

# =============================================================================
# Classification
# =============================================================================

# Load the adapter's credential/shared/session declarations into the
# MIGRATION_* arrays, separators normalized to '/'.
migration_load_declarations() {
  local manifest="$1" p
  MIGRATION_CREDS=(); MIGRATION_SHARED=(); MIGRATION_SESSION=()
  while IFS= read -r p; do
    [ -n "$p" ] && MIGRATION_CREDS+=("${p//\\//}")
  done < <(runtime_json_arr '.account.credentialFiles' "$manifest")
  while IFS= read -r p; do
    [ -n "$p" ] && MIGRATION_SHARED+=("${p//\\//}")
  done < <(runtime_json_arr '.normalState.sharedPaths' "$manifest")
  while IFS= read -r p; do
    [ -n "$p" ] && MIGRATION_SESSION+=("${p//\\//}")
  done < <(runtime_json_arr '.normalState.sessionPaths' "$manifest")
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

# Launcher/migration-owned entries that are never tool state. 'auth' and
# '.runtime' predate this migration only in partial/failed runs; a legacy
# profile cannot meaningfully own them.
migration_is_meta_entry() {
  local rel="$1"
  case "$rel" in
    .shared|.cli|.profile.json|.runtime|.isolated|auth) return 0 ;;
    "$MIGRATION_JOURNAL_NAME"*) return 0 ;;
  esac
  return 1
}

migration_classify() {
  local pdir="$1"
  MIGRATION_ENTRIES=(); MIGRATION_UNKNOWN=(); MIGRATION_OVERLAP=()
  migration_classify_dir "$pdir" ""
}

# Walk one level of the profile tree, classifying each entry against the
# adapter declarations. Directories that are strict ancestors of a declared
# path are descended into so undeclared siblings are caught; directories that
# are themselves declared are adopted whole.
migration_classify_dir() {
  local pdir="$1" prefix="$2"
  local entry name rel m_cred m_shared m_session m_state kind
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    name="$(basename "$entry")"
    rel="${prefix:+$prefix/}$name"
    if migration_is_meta_entry "$rel"; then
      MIGRATION_ENTRIES+=("metadata	$rel")
      continue
    fi
    m_cred=""; m_shared=""; m_session=""
    m_cred="$(migration_match_declared "$rel" "${MIGRATION_CREDS[@]+"${MIGRATION_CREDS[@]}"}")" || true
    m_shared="$(migration_match_declared "$rel" "${MIGRATION_SHARED[@]+"${MIGRATION_SHARED[@]}"}")" || true
    m_session="$(migration_match_declared "$rel" "${MIGRATION_SESSION[@]+"${MIGRATION_SESSION[@]}"}")" || true
    m_state="${m_shared:-$m_session}"
    if [ -n "$m_cred" ] && [ -n "$m_state" ]; then
      MIGRATION_OVERLAP+=("$rel")
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
    if [ -n "$m_state" ]; then
      kind="shared"; [ -z "$m_shared" ] && kind="session"
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
  message="$message
Declare the paths in the adapter (sharedPaths, sessionPaths, credentialFiles) or remove them from the profile. No changes were made."
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
  local entry class
  MIGRATION_OPS=()
  # Credentials first (profile-local moves), then state merges, then metadata.
  for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
    class="${entry%%	*}"
    [ "$class" = credential ] && migration_plan_credential "$pdir" "${entry#*	}" "$spec"
  done
  for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
    class="${entry%%	*}"
    case "$class" in
      shared|session) migration_plan_shared "$pdir" "$shared_root" "${entry#*	}" "$class" "$prefer_profile" ;;
    esac
  done
  for entry in "${MIGRATION_ENTRIES[@]+"${MIGRATION_ENTRIES[@]}"}"; do
    class="${entry%%	*}"
    [ "$class" = metadata ] && migration_add_op keep-metadata "${entry#*	}" "" "" ""
  done
  migration_plan_placeholders "$pdir"
  migration_add_op write-metadata ".profile.json" "" "$pdir/.profile.json" ""
}

# Plan one credential move into auth/. Links refuse the run; an existing
# target with different content refuses it too -- credentials are never
# overwritten. Identical content dedupes instead of moving.
migration_plan_credential() {
  local pdir="$1" rel="$2" spec="$3"
  local from="$pdir/$rel" to="$pdir/auth/$rel"
  if [ -L "$from" ]; then
    abort "Cannot migrate $spec: credential '$rel' is a link. Replace it with the real credential file before migrating. No changes were made."
  fi
  if [ -e "$to" ]; then
    if [ -f "$to" ] && [ -f "$from" ] && cmp -s "$from" "$to"; then
      migration_add_op remove-duplicate-credential "$rel" "$from" "$to" ""
    else
      abort "Cannot migrate $spec: credential target 'auth/$rel' already exists with different content; refusing to overwrite credentials. Resolve the conflict manually. No changes were made."
    fi
    return
  fi
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

# Plan one shared/session entry: whole links are kept, files merge per the
# conflict policy, clean new directories move whole, and everything else
# falls back to per-file merging.
migration_plan_shared() {
  local pdir="$1" shared_root="$2" rel="$3" kind="$4" prefer_profile="$5"
  local from="$pdir/$rel" to="$shared_root/$rel" target
  if [ -L "$from" ]; then
    target="$(readlink "$from" 2>/dev/null || echo '?')"
    migration_add_op keep-link "$rel" "$from" "$to" "target: $target"
    return
  fi
  if [ -f "$from" ]; then
    migration_plan_file_merge "$from" "$to" "$rel" "$kind" "$prefer_profile"
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
      migration_add_op skip-link "$rel/$sub" "$f" "" "left in profile"
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
    migration_plan_file_merge "$f" "$to/$sub" "$rel/$sub" "$kind" "$prefer_profile"
  done < <(find "$from" -mindepth 1 \( -type f -o -type l \) | LC_ALL=C sort)
}

# Plan one file against its shared-root target: move when absent, dedupe when
# identical, replace only with --prefer-profile, otherwise skip the conflict.
migration_plan_file_merge() {
  local from="$1" to="$2" rel="$3" kind="$4" prefer_profile="$5"
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
  local pdir="$1" cred existing covered
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
    migration_add_op ensure-placeholder "$cred" "" "$pdir/auth/$cred" ""
  done
}

# =============================================================================
# Journal
# =============================================================================

# Write the journal atomically (temp + rename): overall status plus every op
# with its current status, so a crash mid-migration leaves a truthful record.
migration_journal_write() {
  local journal="$1" overall="$2" tool="$3" name="$4" shared_root="$5" prefer_profile="$6"
  local tmp="$journal.tmp" ops_json="[]" i rec
  for i in "${!MIGRATION_OPS[@]}"; do
    migration_op_unpack "${MIGRATION_OPS[$i]}"
    rec="$(jq -cn \
      --arg op "$MIG_OP" --arg rel "$MIG_REL" --arg from "$MIG_FROM" --arg to "$MIG_TO" \
      --arg status "$MIG_STATUS" --arg note "$MIG_NOTE" \
      '{op:$op,rel:$rel,from:$from,to:$to,status:$status,note:$note}')"
    ops_json="$(jq -c --argjson rec "$rec" '. + [$rec]' <<< "$ops_json")"
  done
  jq -n \
    --arg tool "$tool" \
    --arg profile "$name" \
    --arg shared_root "$shared_root" \
    --arg status "$overall" \
    --argjson prefer_profile "$prefer_profile" \
    --arg action "Re-run 'multi-cli migrate $tool/$name' to roll forward; to roll back, move each 'done' entry from 'to' back to 'from'." \
    --argjson operations "$ops_json" \
    '{tool:$tool,profile:$profile,sharedRoot:$shared_root,status:$status,preferProfile:$prefer_profile,action:$action,operations:$operations}' \
    > "$tmp"
  mv -f "$tmp" "$journal"
}

# =============================================================================
# Reporting
# =============================================================================

migration_op_line() {
  local op="$1" rel="$2" to="$3" note="$4"
  case "$op" in
    move-credential)              printf '  move credential %s -> auth/%s\n' "$rel" "$rel" ;;
    remove-duplicate-credential)  printf '  remove duplicate credential %s (already migrated)\n' "$rel" ;;
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
  local from="$1" to="$2"
  mkdir -p "$(dirname "$to")"
  mv -- "$from" "$to"
}

migration_do_replace() {
  local from="$1" to="$2"
  rm -rf -- "$to"
  mkdir -p "$(dirname "$to")"
  mv -- "$from" "$to"
}

migration_do_placeholder() {
  local to="$1"
  mkdir -p "$(dirname "$to")"
  [ -e "$to" ] || : > "$to"
}

# Run one filesystem operation; on failure mark it failed, finalize the
# journal, and abort with the roll-forward instructions.
migration_run_fs_op() {
  local index="$1" journal="$2" tool="$3" name="$4" shared_root="$5" prefer_profile="$6"
  shift 6
  local err
  if err="$("$@" 2>&1)"; then
    migration_set_op_status "$index" done
    return 0
  fi
  migration_set_op_status "$index" failed
  migration_journal_write "$journal" failed "$tool" "$name" "$shared_root" "$prefer_profile"
  abort "Migration failed: $err
Roll-forward/rollback journal written to $journal
Re-run 'multi-cli migrate $tool/$name' to roll forward."
}

# Run every planned op in order, journaling after each. Any failure marks the
# op failed, finalizes the journal, and aborts with roll-forward guidance.
migration_exec_ops() {
  local pdir="$1" manifest="$2" journal="$3" tool="$4" name="$5" shared_root="$6" prefer_profile="$7"
  local i
  for i in "${!MIGRATION_OPS[@]}"; do
    migration_op_unpack "${MIGRATION_OPS[$i]}"
    case "$MIG_OP" in
      keep-metadata|keep-link|skip-conflict|skip-link|skip-credential-lookalike)
        migration_set_op_status "$i" skipped
        migration_op_line "$MIG_OP" "$MIG_REL" "$MIG_TO" "$MIG_NOTE"
        ;;
      remove-duplicate|remove-duplicate-credential)
        migration_run_fs_op "$i" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile" \
          rm -f -- "$MIG_FROM"
        migration_op_line "$MIG_OP" "$MIG_REL" "$MIG_TO" "$MIG_NOTE"
        ;;
      move-credential|merge-move)
        migration_run_fs_op "$i" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile" \
          migration_do_move "$MIG_FROM" "$MIG_TO"
        migration_op_line "$MIG_OP" "$MIG_REL" "$MIG_TO" "$MIG_NOTE"
        ;;
      replace-shared)
        migration_run_fs_op "$i" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile" \
          migration_do_replace "$MIG_FROM" "$MIG_TO"
        migration_op_line "$MIG_OP" "$MIG_REL" "$MIG_TO" "$MIG_NOTE"
        ;;
      ensure-placeholder)
        migration_run_fs_op "$i" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile" \
          migration_do_placeholder "$MIG_TO"
        migration_op_line "$MIG_OP" "$MIG_REL" "$MIG_TO" "$MIG_NOTE"
        ;;
      write-metadata)
        migration_run_fs_op "$i" "$journal" "$tool" "$name" "$shared_root" "$prefer_profile" \
          runtime_write_profile_metadata "$manifest" "$pdir"
        migration_op_line "$MIG_OP" "$MIG_REL" "$MIG_TO" "$MIG_NOTE"
        ;;
      *)
        migration_set_op_status "$i" failed
        migration_journal_write "$journal" failed "$tool" "$name" "$shared_root" "$prefer_profile"
        abort "Migration failed: unknown operation '$MIG_OP'. Journal written to $journal"
        ;;
    esac
    migration_journal_write "$journal" running "$tool" "$name" "$shared_root" "$prefer_profile"
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
# Entry point -- wired into the launcher as `multi-cli migrate`
# =============================================================================

# multi-cli migrate <tool>/<name> [--dry-run] [--prefer-profile]: refuse
# unclassifiable profiles before writing, plan, then either print the plan
# (dry run) or execute it under the journal.
cmd_migrate() {
  local spec="" dry_run=false prefer_profile=false
  local positionals=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)        dry_run=true ;;
      --prefer-profile) prefer_profile=true ;;
      --*)              abort "Unknown option '$1'. Usage: multi-cli migrate <tool>/<name> [--dry-run] [--prefer-profile]" ;;
      *)                positionals+=("$1") ;;
    esac
    shift
  done
  spec="${positionals[0]:-}"
  [ -n "$spec" ] || abort "Usage: multi-cli migrate <tool>/<name> [--dry-run] [--prefer-profile]"
  split_profile_spec "$spec"
  validate_name "$NAME"
  local manifest pdir shared_root mechanism journal
  manifest="$(adapter_path "$TOOL")"
  assert_adapter_valid "$TOOL"
  pdir="$(profile_dir "$TOOL" "$NAME")"
  [ -d "$pdir" ] || abort "Profile '$spec' does not exist"

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

  migration_load_declarations "$manifest"
  migration_classify "$pdir"
  if [ "${#MIGRATION_UNKNOWN[@]}" -gt 0 ] || [ "${#MIGRATION_OVERLAP[@]}" -gt 0 ]; then
    migration_refuse_unclassified "$spec"
  fi

  migration_assert_same_volume "$pdir" "$shared_root" "$spec"
  migration_plan_ops "$pdir" "$shared_root" "$prefer_profile" "$spec"

  if [ "$dry_run" = true ]; then
    migration_print_plan "$spec"
    return 0
  fi

  echo "Migrating $spec (legacy-isolated -> accountOverlay):"
  mkdir -p "$shared_root"
  journal="$pdir/$MIGRATION_JOURNAL_NAME"
  migration_journal_write "$journal" running "$TOOL" "$NAME" "$shared_root" "$prefer_profile"
  migration_exec_ops "$pdir" "$manifest" "$journal" "$TOOL" "$NAME" "$shared_root" "$prefer_profile"
  migration_prune_empty_dirs "$pdir"
  migration_journal_write "$journal" completed "$TOOL" "$NAME" "$shared_root" "$prefer_profile"
  echo "Migrated $spec to schema-v2 (accountOverlay)."
  if [ "$mechanism" = processSecret ]; then
    echo "Note: adapter '$TOOL' uses process-secret credentials. Run: multi-cli auth set $spec before launching."
  fi
}
