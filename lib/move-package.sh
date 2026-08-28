#!/usr/bin/env bash
# Portable, credential-bearing offline move packages.
#
# This contract is intentionally separate from export/import. A package is an
# unencrypted ZIP containing one NDJSON payload. File metadata carries a
# relative path, byte count, and SHA-256 digest; content follows in bounded
# base64 chunk records.
# Import never asks unzip to materialize archive paths: it streams the one fixed
# payload entry and rebuilds regular files inside reserved staging.

MOVE_PACKAGE_ENTRY="nini-agents-move-package.ndjson"
MOVE_PACKAGE_KIND="nini-agents-offline-move"
MOVE_PACKAGE_ERROR=""
MOVE_PACKAGE_ID=""
MOVE_PACKAGE_PROFILE_FORMAT="unknown"
MOVE_PACKAGE_PROFILE_MODE="unknown"
MOVE_PACKAGE_SOURCE_NAME=""
MOVE_PACKAGE_STATE_MANIFEST=""
MOVE_PACKAGE_STATE_DECLARATIONS=()

move_package_error() {
  MOVE_PACKAGE_ERROR="$1"
  return 1
}

move_package_require_commands() {
  command -v zip >/dev/null 2>&1 || { move_package_error "Portable move packages require 'zip'."; return 1; }
  command -v unzip >/dev/null 2>&1 || { move_package_error "Portable move packages require 'unzip'."; return 1; }
  command -v base64 >/dev/null 2>&1 || { move_package_error "Portable move packages require 'base64'."; return 1; }
  command -v dd >/dev/null 2>&1 || { move_package_error "Portable move packages require 'dd'."; return 1; }
}

move_package_safe_relative() {
  local rel="$1" component rest stem upper
  [ -n "$rel" ] || return 1
  case "$rel" in *$'\n'*|*$'\r'*) return 1 ;; esac
  if printf '%s' "$rel" | LC_ALL=C grep -q '[[:cntrl:]]'; then return 1; fi
  case "$rel" in
    /*|*\\*|*:*|*"<"*|*">"*|*"\""*|*"|"*|*"?"*|*"*"*) return 1 ;;
  esac
  rest="$rel"
  while :; do
    case "$rest" in
      */*) component="${rest%%/*}"; rest="${rest#*/}" ;;
      *) component="$rest"; rest="" ;;
    esac
    [ -n "$component" ] && [ "$component" != . ] && [ "$component" != .. ] || return 1
    case "$component" in *. | *" ") return 1 ;; esac
    stem="${component%%.*}"
    upper="$(printf '%s' "$stem" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
    case "$upper" in CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]) return 1 ;; esac
    [ -n "$rest" ] || break
  done
}

move_package_load_state_declarations() {
  local manifest="$1" declared declarations
  [ "$MOVE_PACKAGE_STATE_MANIFEST" = "$manifest" ] && [ "${#MOVE_PACKAGE_STATE_DECLARATIONS[@]}" -gt 0 ] && return 0
  MOVE_PACKAGE_STATE_MANIFEST="$manifest"
  MOVE_PACKAGE_STATE_DECLARATIONS=()
  declarations="$(jq -r '[(.normalState.sharedPaths // [])[], (.normalState.sessionPaths // [])[]] | unique[]' "$manifest" 2>/dev/null)" || return 1
  while IFS= read -r declared; do
    [ -n "$declared" ] || continue
    move_package_safe_relative "$declared" || return 1
    transfer_is_credential_path "$manifest" "$declared" && continue
    MOVE_PACKAGE_STATE_DECLARATIONS+=("$declared")
  done <<< "$declarations"
}

move_package_state_declared() {
  local manifest="$1" rel="$2" declared
  move_package_load_state_declarations "$manifest" || return 1
  for declared in "${MOVE_PACKAGE_STATE_DECLARATIONS[@]}"; do
    case "$rel" in "$declared"|"$declared"/*) return 0 ;; esac
    case "$declared" in "$rel"/*) return 0 ;; esac
  done
  return 1
}

move_package_base64_decode() {
  if printf '' | base64 --decode >/dev/null 2>&1; then
    base64 --decode
  elif printf '' | base64 -D >/dev/null 2>&1; then
    base64 -D
  else
    base64 -d
  fi
}

move_package_tree_inventory() {
  local root="$1" output="$2" entry rel digest size
  : > "$output"
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  while IFS= read -r -d '' entry; do
    rel="${entry#"$root"/}"
    move_package_safe_relative "$rel" || return 1
    if [ -L "$entry" ]; then
      return 1
    elif [ -d "$entry" ]; then
      printf 'd\t%s\n' "$rel" >> "$output"
    elif [ -f "$entry" ]; then
      [ "$(file_nlink "$entry")" -eq 1 ] || return 1
      digest="$(move_sha256 "$entry")" || return 1
      size="$(file_size "$entry")"
      printf 'f\t%s\t%s\t%s\n' "$rel" "$size" "$digest" >> "$output"
    else
      return 1
    fi
  done < <(find "$root" -mindepth 1 -print0 2>/dev/null)
  LC_ALL=C sort "$output" -o "$output"
}

move_package_trees_equal() {
  local left="$1" right="$2" temp left_inventory right_inventory rc=1
  temp="$(mktemp -d "${TMPDIR:-/tmp}/nini-move-compare.XXXXXX")" || return 1
  left_inventory="$temp/left"
  right_inventory="$temp/right"
  if move_package_tree_inventory "$left" "$left_inventory" &&
     move_package_tree_inventory "$right" "$right_inventory" &&
     cmp -s "$left_inventory" "$right_inventory"; then
    rc=0
  fi
  rm -rf "$temp"
  return "$rc"
}

move_package_copy_state_entry() {
  local source="$1" destination="$2" allowed_root="$3" entry rel target parent
  [ -e "$source" ] || [ -L "$source" ] || return 0
  target="$(transfer_canonical "$source" 2>/dev/null || true)"
  [ -n "$target" ] && transfer_path_within "$target" "$allowed_root" || return 1
  if [ -L "$source" ]; then return 1; fi
  if [ -d "$source" ]; then
    mkdir -p "$destination" || return 1
    while IFS= read -r -d '' entry; do
      rel="${entry#"$source"/}"
      move_package_safe_relative "$rel" || return 1
      move_package_copy_state_entry "$entry" "$destination/$rel" "$allowed_root" || return 1
    done < <(find "$source" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    return 0
  fi
  [ -f "$source" ] && [ "$(file_nlink "$source")" -eq 1 ] || return 1
  parent="$(dirname "$destination")"
  mkdir -p "$parent" || return 1
  cp -p -- "$source" "$destination"
}

move_package_collect_state() {
  local manifest="$1" profile="$2" mode="$3" destination="$4"
  local shared_root canonical_shared rel source
  mkdir -p "$destination" || return 1
  [ "$mode" = accountOverlay ] || return 0
  shared_root="$(runtime_platform_root "$manifest")"
  [ -n "$shared_root" ] || return 1
  [ -e "$shared_root" ] || return 0
  [ -d "$shared_root" ] && [ ! -L "$shared_root" ] || return 1
  canonical_shared="$(transfer_canonical "$shared_root")" || return 1
  move_package_load_state_declarations "$manifest" || return 1
  for rel in "${MOVE_PACKAGE_STATE_DECLARATIONS[@]}"; do
    source="$shared_root/$rel"
    [ -e "$source" ] || [ -L "$source" ] || continue
    move_package_copy_state_entry "$source" "$destination/$rel" "$canonical_shared" || return 1
  done
}

move_package_stage_profile() {
  local manifest="$1" source="$2" staging="$3" rc
  mkdir -p "$staging" || return 1
  move_copy_candidate_local "$source" "$staging" || return 1
  if move_validate_profile "$manifest" "$staging"; then rc=0; else rc=$?; fi
  [ "$rc" -eq 0 ] || return "$rc"
  move_prune_staging_links "$manifest" "$staging" || return 1
  move_validate_profile "$manifest" "$staging" || return $?
  move_trees_equal "$manifest" "$source" "$staging"
}

move_package_write_tree() {
  local root="$1" scope="$2" payload="$3" entry rel path_json digest size encoded block
  while IFS= read -r -d '' entry; do
    rel="${entry#"$root"/}"
    move_package_safe_relative "$rel" || return 1
    path_json="$(jq -Rn --arg value "$rel" '$value')" || return 1
    if [ -d "$entry" ] && [ ! -L "$entry" ]; then
      printf '{"type":"directory","scope":"%s","path":%s}\n' "$scope" "$path_json" >> "$payload"
    elif [ -f "$entry" ] && [ ! -L "$entry" ] && [ "$(file_nlink "$entry")" -eq 1 ]; then
      digest="$(move_sha256 "$entry")" || return 1
      size="$(file_size "$entry")"
      printf '{"type":"file-start","scope":%s,"path":%s,"size":%s,"sha256":"%s"}\n' \
        "\"$scope\"" "$path_json" "$size" "$digest" >> "$payload"
      block=0
      while [ $((block * 49152)) -lt "$size" ]; do
        encoded="$(dd if="$entry" bs=49152 skip="$block" count=1 2>/dev/null | base64 | tr -d '\r\n')" || return 1
        [ -n "$encoded" ] && [ "${#encoded}" -le 65536 ] || return 1
        printf '{"type":"chunk","data":"%s"}\n' "$encoded" >> "$payload"
        block=$((block + 1))
      done
      printf '{"type":"file-end"}\n' >> "$payload"
    else
      return 1
    fi
  done < <(find "$root" -mindepth 1 -print0 2>/dev/null)
}

move_package_archive_entries_valid() {
  local archive="$1" entries
  entries="$(unzip -Z1 "$archive" 2>/dev/null | tr -d '\r')" || return 1
  [ "$entries" = "$MOVE_PACKAGE_ENTRY" ]
}

move_package_unpack() {
  local archive="$1" manifest="$2" profile_stage="$3" state_stage="$4"
  local temp payload header header_fields record parsed adapter_id seen scope rel type target parent size digest data
  MOVE_PACKAGE_ID=""; MOVE_PACKAGE_PROFILE_FORMAT=unknown; MOVE_PACKAGE_PROFILE_MODE=unknown; MOVE_PACKAGE_SOURCE_NAME=""
  move_package_require_commands || return 1
  [ -f "$archive" ] && [ ! -L "$archive" ] || { move_package_error "Move package not found or is linked: $archive"; return 1; }
  move_package_archive_entries_valid "$archive" || { move_package_error "Refusing move package: ZIP must contain exactly '$MOVE_PACKAGE_ENTRY'."; return 1; }
  temp="$(mktemp -d "${TMPDIR:-/tmp}/nini-move-unpack.XXXXXX")" || { move_package_error "Cannot reserve package inspection staging."; return 1; }
  payload="$temp/$MOVE_PACKAGE_ENTRY"
  if ! (umask 077; unzip -p "$archive" "$MOVE_PACKAGE_ENTRY" > "$payload"); then
    rm -rf "$temp"; move_package_error "Cannot read move package payload."
    return 1
  fi
  IFS= read -r header < "$payload" || { rm -rf "$temp"; move_package_error "Move package payload is empty."; return 1; }
  if ! printf '%s' "$header" | jq -e --arg kind "$MOVE_PACKAGE_KIND" '
      type == "object" and .schemaVersion == 1 and .kind == $kind and
      (.adapterId | type == "string" and length > 0) and
      (.profileName | type == "string" and length > 0) and
      (.profileFormat == "v2" or .profileFormat == "legacy") and
      (.profileMode == "accountOverlay" or .profileMode == "isolated" or .profileMode == "legacy") and
      (.packageId | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")) and
      .encrypted == false and .includes.credentials == true and
      .includes.chats == true and .includes.globalState == true
    ' >/dev/null 2>&1; then
    rm -rf "$temp"; move_package_error "Move package header is invalid."; return 1
  fi
  header_fields="$(printf '%s' "$header" | jq -er '[.adapterId,.packageId,.profileFormat,.profileMode,.profileName] | @tsv')" || {
    rm -rf "$temp"; move_package_error "Move package header fields are invalid."; return 1;
  }
  IFS=$'\t' read -r adapter_id MOVE_PACKAGE_ID MOVE_PACKAGE_PROFILE_FORMAT MOVE_PACKAGE_PROFILE_MODE MOVE_PACKAGE_SOURCE_NAME <<< "$header_fields"
  [ "$adapter_id" = "$(runtime_json_str '.id' "$manifest")" ] || {
    rm -rf "$temp"; move_package_error "Move package adapter '$adapter_id' does not match this destination adapter."; return 1;
  }
  move_safe_component "$MOVE_PACKAGE_ID" && move_safe_component "$MOVE_PACKAGE_SOURCE_NAME" || {
    rm -rf "$temp"; move_package_error "Move package identifiers are unsafe."; return 1;
  }
  (umask 077; mkdir -p "$profile_stage" "$state_stage") || { rm -rf "$temp"; move_package_error "Cannot create import staging."; return 1; }
  chmod 700 "$profile_stage" "$state_stage" 2>/dev/null || true
  seen="$temp/seen"
  : > "$seen"
  tail -n +2 "$payload" | (
    local current_target="" current_size="" current_digest="" actual_size actual_digest
    while IFS= read -r record; do
      parsed="$(printf '%s' "$record" | jq -er '
        if type != "object" then error("invalid record")
        elif .type == "directory" and (keys | sort) == ["path","scope","type"] and
             (.scope == "profile" or .scope == "state") and (.path | type == "string" and length > 0)
          then ["directory",.scope,.path,"-","-","-"] | @tsv
        elif .type == "file-start" and (keys | sort) == ["path","scope","sha256","size","type"] and
             (.scope == "profile" or .scope == "state") and (.path | type == "string" and length > 0) and
             (.size | type == "number" and . >= 0 and floor == .) and
             (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
          then ["file-start",.scope,.path,(.size|tostring),.sha256,"-"] | @tsv
        elif .type == "chunk" and (keys | sort) == ["data","type"] and
             (.data | type == "string" and length > 0 and length <= 65536 and test("^[A-Za-z0-9+/]*={0,2}$"))
          then ["chunk","-","-","-","-",.data] | @tsv
        elif .type == "file-end" and (keys | sort) == ["type"]
          then ["file-end","-","-","-","-","-"] | @tsv
        else error("invalid record") end
      ' 2>/dev/null)" || exit 41
      IFS=$'\t' read -r type scope rel size digest data <<< "$parsed"

      if [ -n "$current_target" ]; then
        if [ "$type" = chunk ]; then
          printf '%s' "$data" | move_package_base64_decode >> "$current_target" 2>/dev/null || exit 49
          continue
        fi
        [ "$type" = file-end ] || exit 41
        actual_size="$(file_size "$current_target")"
        actual_digest="$(move_sha256 "$current_target")" || exit 50
        [ "$current_size" = "$actual_size" ] && [ "$current_digest" = "$actual_digest" ] || exit 51
        chmod 600 "$current_target" 2>/dev/null || true
        current_target=""; current_size=""; current_digest=""
        continue
      fi

      [ "$type" = directory ] || [ "$type" = file-start ] || exit 41
      move_package_safe_relative "$rel" || exit 42
      if [ "$scope" = state ]; then move_package_state_declared "$manifest" "$rel" || exit 43; fi
      if grep -Fqx "$scope	$rel" "$seen"; then exit 44; fi
      printf '%s\t%s\n' "$scope" "$rel" >> "$seen"
      if [ "$scope" = profile ]; then target="$profile_stage/$rel"; else target="$state_stage/$rel"; fi
      if [ "$type" = directory ]; then
        [ ! -f "$target" ] && [ ! -L "$target" ] || exit 45
        (umask 077; mkdir -p "$target") || exit 46
        chmod 700 "$target" 2>/dev/null || true
        continue
      fi
      [ ! -e "$target" ] && [ ! -L "$target" ] || exit 47
      parent="$(dirname "$target")"
      (umask 077; mkdir -p "$parent"; : > "$target") || exit 48
      current_target="$target"; current_size="$size"; current_digest="$digest"
    done
    [ -z "$current_target" ] || exit 52
  )
  local parse_rc="${PIPESTATUS[1]}"
  rm -rf "$temp"
  [ "$parse_rc" -eq 0 ] || { rm -rf "$profile_stage" "$state_stage"; move_package_error "Move package records are invalid or fail integrity checks."; return 1; }
  if ! move_validate_profile "$manifest" "$profile_stage"; then
    rm -rf "$profile_stage" "$state_stage"; move_package_error "Move package profile failed credential and structure validation."; return 1
  fi
  [ "$MOVE_PROFILE_FORMAT" = "$MOVE_PACKAGE_PROFILE_FORMAT" ] && [ "$MOVE_PROFILE_MODE" = "$MOVE_PACKAGE_PROFILE_MODE" ] || {
    rm -rf "$profile_stage" "$state_stage"; move_package_error "Move package profile metadata does not match its header."; return 1;
  }
}

move_package_probe_idle() {
  local probe="$1" manifest="$2" profile="$3" rc
  if "$probe" "$manifest" "$profile"; then rc=0; else rc=$?; fi
  case "$rc" in
    1) return 0 ;;
    0) move_package_error "An active tool process is using the profile. Close it and retry." ;;
    *) move_package_error "Could not prove that the tool is stopped. No ownership change was made." ;;
  esac
}

move_package_state_preflight() {
  local staged="$1" shared="$2" entry rel destination
  [ -d "$staged" ] && [ ! -L "$staged" ] || return 1
  if [ -e "$shared" ] || [ -L "$shared" ]; then [ -d "$shared" ] && [ ! -L "$shared" ] || return 1; fi
  while IFS= read -r -d '' entry; do
    rel="${entry#"$staged"/}"
    move_package_safe_relative "$rel" || return 1
    destination="$shared/$rel"
    if [ -d "$entry" ]; then
      if [ -e "$destination" ] || [ -L "$destination" ]; then [ -d "$destination" ] && [ ! -L "$destination" ] || return 1; fi
    elif [ -f "$entry" ] && [ ! -L "$entry" ]; then
      if [ -e "$destination" ] || [ -L "$destination" ]; then
        [ -f "$destination" ] && [ ! -L "$destination" ] &&
          [ "$(file_size "$entry")" = "$(file_size "$destination")" ] &&
          [ "$(move_sha256 "$entry")" = "$(move_sha256 "$destination")" ] || return 1
      fi
    else return 1; fi
  done < <(find "$staged" -mindepth 1 -print0 2>/dev/null)
}

move_package_apply_state() {
  local staged="$1" shared="$2" log="$3" entry rel destination parent temporary
  : > "$log"
  if [ ! -e "$shared" ]; then mkdir -p "$shared" || return 1; printf 'r\t%s\n' "$shared" >> "$log"; fi
  while IFS= read -r -d '' entry; do
    rel="${entry#"$staged"/}"
    destination="$shared/$rel"
    if [ -d "$entry" ]; then
      if [ ! -e "$destination" ]; then mkdir "$destination" || return 1; printf 'd\t%s\n' "$destination" >> "$log"; fi
    elif [ -f "$entry" ]; then
      [ ! -e "$destination" ] || continue
      parent="$(dirname "$destination")"
      temporary="$parent/.nini-move-package.$$.$RANDOM.tmp"
      cp -p -- "$entry" "$temporary" || return 1
      mv -- "$temporary" "$destination" || { rm -f "$temporary"; return 1; }
      printf 'f\t%s\n' "$destination" >> "$log"
    fi
  done < <(find "$staged" -mindepth 1 -print0 2>/dev/null)
}

move_package_rollback_state() {
  local log="$1" kinds=() paths=() kind path index
  while IFS=$'\t' read -r kind path; do kinds+=("$kind"); paths+=("$path"); done < "$log"
  for ((index=${#paths[@]}-1; index>=0; index--)); do
    kind="${kinds[$index]}"; path="${paths[$index]}"
    case "$kind" in f) rm -f -- "$path" ;; d|r) rmdir -- "$path" 2>/dev/null || true ;; esac
  done
}

move_package_export() {
  local manifest="$1" source="$2" out="$3" name="$4" probe="$5"
  local temp profile_stage state_stage verify_profile verify_state payload adapter_id package_id mode format
  local out_parent out_abs source_canonical parent_canonical lock backup current_state
  MOVE_PACKAGE_ERROR=""
  move_package_require_commands || return 1
  move_safe_component "$name" || { move_package_error "Invalid profile name '$name'."; return 1; }
  [ -d "$source" ] && [ ! -L "$source" ] || { move_package_error "Profile source does not exist or is linked."; return 1; }
  move_package_probe_idle "$probe" "$manifest" "$source" || return 1
  if ! move_validate_profile "$manifest" "$source"; then move_package_error "Profile failed credential and structure validation."; return 1; fi
  format="$MOVE_PROFILE_FORMAT"; mode="$MOVE_PROFILE_MODE"
  adapter_id="$(runtime_json_str '.id' "$manifest")"
  package_id="$(runtime_new_profile_id | tr -d '\r\n')"
  move_safe_component "$package_id" || { move_package_error "Could not create a safe package identifier."; return 1; }
  out_parent="$(dirname "$out")"; mkdir -p "$out_parent" || { move_package_error "Cannot create package destination."; return 1; }
  parent_canonical="$(cd "$out_parent" && pwd -P)" || return 1
  out_abs="$parent_canonical/$(basename "$out")"
  [ ! -e "$out_abs" ] && [ ! -L "$out_abs" ] || { move_package_error "Refusing to overwrite existing package '$out_abs'."; return 1; }
  source_canonical="$(transfer_canonical "$source")" || return 1
  if transfer_path_within "$out_abs" "$source_canonical"; then move_package_error "Move package cannot be written inside the source profile."; return 1; fi
  temp="$(mktemp -d "${TMPDIR:-/tmp}/nini-move-export.XXXXXX")" || { move_package_error "Cannot reserve export staging."; return 1; }
  profile_stage="$temp/profile"; state_stage="$temp/state"; verify_profile="$temp/verify-profile"; verify_state="$temp/verify-state"
  payload="$temp/$MOVE_PACKAGE_ENTRY"
  if ! move_package_stage_profile "$manifest" "$source" "$profile_stage" ||
     ! move_package_collect_state "$manifest" "$source" "$mode" "$state_stage"; then
    rm -rf "$temp"; move_package_error "Cannot stage a safe profile/state snapshot."; return 1
  fi
  jq -cn --arg kind "$MOVE_PACKAGE_KIND" --arg adapter "$adapter_id" --arg name "$name" \
    --arg format "$format" --arg mode "$mode" --arg package_id "$package_id" '
    {schemaVersion:1,kind:$kind,adapterId:$adapter,profileName:$name,
     profileFormat:$format,profileMode:$mode,packageId:$package_id,
     includes:{credentials:true,chats:true,globalState:true},encrypted:false}
  ' > "$payload" || { rm -rf "$temp"; move_package_error "Cannot write package header."; return 1; }
  if ! move_package_write_tree "$profile_stage" profile "$payload" ||
     ! move_package_write_tree "$state_stage" state "$payload"; then
    rm -rf "$temp"; move_package_error "Cannot serialize package files."; return 1
  fi
  if ! (cd "$temp" && zip -q "$out_abs" "$MOVE_PACKAGE_ENTRY") || ! chmod 600 "$out_abs" 2>/dev/null || ! unzip -tqq "$out_abs" >/dev/null 2>&1; then
    rm -f "$out_abs"; rm -rf "$temp"; move_package_error "Cannot create and verify ZIP package."; return 1
  fi
  if ! move_package_unpack "$out_abs" "$manifest" "$verify_profile" "$verify_state" ||
     ! move_trees_equal "$manifest" "$profile_stage" "$verify_profile" ||
     ! move_package_trees_equal "$state_stage" "$verify_state"; then
    rm -f "$out_abs"; rm -rf "$temp"; [ -n "$MOVE_PACKAGE_ERROR" ] || MOVE_PACKAGE_ERROR="ZIP self-verification failed."; return 1
  fi
  lock="$(dirname "$source")/.move-lock.$name"
  backup="$(dirname "$source")/.inactive/$name.$package_id"
  [ ! -e "$backup" ] && [ ! -L "$backup" ] || { rm -f "$out_abs"; rm -rf "$temp"; move_package_error "Inactive recovery destination already exists."; return 1; }
  if ! mkdir "$lock" 2>/dev/null; then rm -f "$out_abs"; rm -rf "$temp"; move_package_error "Profile movement is locked by another operation."; return 1; fi
  current_state="$temp/current-state"
  if ! move_package_probe_idle "$probe" "$manifest" "$source" ||
     ! move_validate_profile "$manifest" "$source" ||
     ! move_trees_equal "$manifest" "$source" "$profile_stage" ||
     ! move_package_collect_state "$manifest" "$source" "$mode" "$current_state" ||
     ! move_package_trees_equal "$state_stage" "$current_state"; then
    rmdir "$lock" 2>/dev/null || true; rm -f "$out_abs"; rm -rf "$temp"
    [ -n "$MOVE_PACKAGE_ERROR" ] || MOVE_PACKAGE_ERROR="Profile or shared state changed while packaging; no ownership change was made."
    return 1
  fi
  mkdir -p "$(dirname "$backup")" || { rmdir "$lock" 2>/dev/null || true; rm -f "$out_abs"; rm -rf "$temp"; move_package_error "Cannot prepare inactive recovery storage."; return 1; }
  if ! mv -- "$source" "$backup"; then
    rmdir "$lock" 2>/dev/null || true; rm -f "$out_abs"; rm -rf "$temp"; move_package_error "Could not deactivate source profile; package was removed."; return 1
  fi
  if ! rmdir "$lock" 2>/dev/null; then
    rm -rf "$temp"; move_package_error "Source is inactive and ZIP is valid, but the movement lock could not be released."; return 1
  fi
  rm -rf "$temp"
  MOVE_PACKAGE_ID="$package_id"
  MOVE_PACKAGE_ERROR=""
}

move_package_import() {
  local archive="$1" manifest="$2" destination="$3" name="$4" probe="$5"
  local parent temp profile_stage state_stage shared lock log mode
  MOVE_PACKAGE_ERROR=""
  move_safe_component "$name" || { move_package_error "Invalid profile name '$name'."; return 1; }
  parent="$(dirname "$destination")"
  [ -d "$parent" ] || mkdir -p "$parent" || { move_package_error "Cannot create destination profile root."; return 1; }
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || { move_package_error "Profile destination already exists."; return 1; }
  temp="$(mktemp -d "$parent/.move-package-import.XXXXXX")" || { move_package_error "Cannot reserve import staging."; return 1; }
  profile_stage="$temp/profile"; state_stage="$temp/state"; log="$temp/state-rollback"
  if ! move_package_unpack "$archive" "$manifest" "$profile_stage" "$state_stage"; then rm -rf "$temp"; return 1; fi
  mode="$MOVE_PACKAGE_PROFILE_MODE"
  shared="$(runtime_platform_root "$manifest")"
  if [ "$mode" = accountOverlay ]; then
    [ -n "$shared" ] || { rm -rf "$temp"; move_package_error "Adapter has no shared-state root on this platform."; return 1; }
    move_package_state_preflight "$state_stage" "$shared" || { rm -rf "$temp"; move_package_error "Destination shared state has a conflicting file; nothing was imported."; return 1; }
  fi
  move_package_probe_idle "$probe" "$manifest" "$destination" || { rm -rf "$temp"; return 1; }
  lock="$parent/.move-lock.$name"
  if ! mkdir "$lock" 2>/dev/null; then rm -rf "$temp"; move_package_error "Profile movement is locked by another operation."; return 1; fi
  if [ -e "$destination" ] || [ -L "$destination" ] || ! move_package_probe_idle "$probe" "$manifest" "$destination"; then
    rmdir "$lock" 2>/dev/null || true; rm -rf "$temp"; [ -n "$MOVE_PACKAGE_ERROR" ] || MOVE_PACKAGE_ERROR="Destination appeared while acquiring the lock."; return 1
  fi
  if [ "$mode" = accountOverlay ]; then
    if ! move_package_state_preflight "$state_stage" "$shared" ||
       ! move_package_apply_state "$state_stage" "$shared" "$log" ||
       ! move_package_state_preflight "$state_stage" "$shared"; then
      [ -f "$log" ] && move_package_rollback_state "$log"
      rmdir "$lock" 2>/dev/null || true; rm -rf "$temp"; move_package_error "Shared state installation failed and was rolled back."; return 1
    fi
  else
    : > "$log"
  fi
  if ! mv -- "$profile_stage" "$destination"; then
    move_package_rollback_state "$log"; rmdir "$lock" 2>/dev/null || true; rm -rf "$temp"; move_package_error "Profile activation failed and shared state was rolled back."; return 1
  fi
  if ! move_validate_profile "$manifest" "$destination" ||
     { [ "$mode" = accountOverlay ] && { ! runtime_build_overlay "$manifest" "$destination" >/dev/null || ! runtime_overlay_is_current "$manifest" "$destination/.runtime"; }; }; then
    rm -rf "$destination/.runtime" 2>/dev/null || true
    if mv -- "$destination" "$profile_stage" 2>/dev/null; then
      move_package_rollback_state "$log"
      rmdir "$lock" 2>/dev/null || true; rm -rf "$temp"; move_package_error "Destination validation failed; profile and shared state were rolled back."; return 1
    fi
    rmdir "$lock" 2>/dev/null || true; move_package_error "Destination validation failed and ownership is indeterminate; preserve '$destination' and '$temp'."; return 1
  fi
  if ! rmdir "$lock" 2>/dev/null; then rm -rf "$temp"; move_package_error "Profile is active but the movement lock could not be released."; return 1; fi
  rm -rf "$temp"
  MOVE_PACKAGE_ERROR=""
}
