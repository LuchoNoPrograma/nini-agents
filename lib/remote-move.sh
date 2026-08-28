#!/usr/bin/env bash
# remote-move.sh -- public, transactional cross-device profile movement.
#
# The coordinator owns discovery, process probes, staging, integrity checks,
# ownership locks, activation and rollback. SSH and rsync are transports only;
# the same Nini Agents endpoint validates both sides. No credential values,
# profile IDs, hashes or absolute paths are emitted by the JSON interface.

REMOTE_MOVE_CONFIG=""
REMOTE_MOVE_THIS_DEVICE=""
REMOTE_MOVE_ROOT_MODE=""
REMOTE_MOVE_LOCAL_CONFIG_ROOT=""
REMOTE_MOVE_DEVICE_NAMES=()
REMOTE_MOVE_DEVICE_SSH=()
REMOTE_MOVE_DEVICE_ROOTS=()
REMOTE_MOVE_OWNER=""
REMOTE_MOVE_OWNER_COUNT=0
REMOTE_MOVE_FOUND_SSH=""
REMOTE_MOVE_FOUND_CONFIG_ROOT=""
REMOTE_MOVE_MESSAGE=""

remote_move_error() {
  REMOTE_MOVE_MESSAGE="$1"
  return 1
}

remote_move_fail_result() {
  move_set_result "$1" "$2" "${3:-${MOVE_PROFILE_FORMAT:-unknown}}"
  REMOTE_MOVE_MESSAGE="$4"
  return 1
}

remote_move_validation_result() {
  local rc="$1" state="$2" code
  case "$rc" in
    20) code=source_missing ;;
    21) code=unsupported_mechanism ;;
    22) code=invalid_metadata ;;
    23) code=missing_credential ;;
    24) code=invalid_auth_json ;;
    25) code=unsafe_link ;;
    26) code=unknown_content ;;
    27) code=unsafe_hardlink ;;
    *) code=unsafe_entry ;;
  esac
  move_set_result "$code" "$state" "${MOVE_PROFILE_FORMAT:-unknown}"
}

remote_move_valid_ssh_target() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._@:-]*$ ]]
}

remote_move_load_config() {
  local config="$1" kind first second third rest name
  REMOTE_MOVE_CONFIG="$config"
  REMOTE_MOVE_THIS_DEVICE=""
  REMOTE_MOVE_ROOT_MODE=""
  REMOTE_MOVE_LOCAL_CONFIG_ROOT=""
  REMOTE_MOVE_DEVICE_NAMES=()
  REMOTE_MOVE_DEVICE_SSH=()
  REMOTE_MOVE_DEVICE_ROOTS=()
  [ -r "$config" ] || { remote_move_error "Cannot read devices configuration '$config'."; return 1; }

  while IFS='|' read -r kind first second third rest; do
    [ -z "$kind" ] && continue
    case "$kind" in \#*) continue ;; esac
    [ -z "${rest:-}" ] || { remote_move_error "Invalid line in devices configuration '$config'."; return 1; }
    case "$kind" in
      this_device)
        [ -z "$second" ] && [ -z "$third" ] || { remote_move_error 'this_device accepts exactly one value.'; return 1; }
        move_safe_component "$first" || { remote_move_error "Invalid this_device value '$first'."; return 1; }
        [ -z "$REMOTE_MOVE_THIS_DEVICE" ] || { remote_move_error "Duplicate this_device entry."; return 1; }
        REMOTE_MOVE_THIS_DEVICE="$first"
        ;;
      profiles_home|profiles_root)
        [ -z "$second" ] && [ -z "$third" ] || { remote_move_error "$kind accepts exactly one path."; return 1; }
        [ -z "$REMOTE_MOVE_LOCAL_CONFIG_ROOT" ] || { remote_move_error "Configure only one profiles_home or profiles_root entry."; return 1; }
        case "$first" in /*) ;; *) remote_move_error "$kind must be an absolute path."; return 1 ;; esac
        REMOTE_MOVE_ROOT_MODE="$kind"
        REMOTE_MOVE_LOCAL_CONFIG_ROOT="${first%/}"
        ;;
      device)
        [ -n "$first" ] && [ -n "$second" ] && [ -n "$third" ] || { remote_move_error 'device requires name, SSH target, and root.'; return 1; }
        move_safe_component "$first" || { remote_move_error "Invalid device name '$first'."; return 1; }
        remote_move_valid_ssh_target "$second" || { remote_move_error "Invalid SSH target for device '$first'."; return 1; }
        case "$third" in /*) ;; *) remote_move_error "Device '$first' root must be an absolute path."; return 1 ;; esac
        for name in "${REMOTE_MOVE_DEVICE_NAMES[@]}"; do
          [ "$name" != "$first" ] || { remote_move_error "Duplicate device '$first'."; return 1; }
        done
        REMOTE_MOVE_DEVICE_NAMES+=("$first")
        REMOTE_MOVE_DEVICE_SSH+=("$second")
        REMOTE_MOVE_DEVICE_ROOTS+=("${third%/}")
        ;;
      *) remote_move_error "Unknown devices configuration key '$kind'."; return 1 ;;
    esac
  done < "$config"

  [ -n "$REMOTE_MOVE_THIS_DEVICE" ] || { remote_move_error "devices configuration is missing this_device."; return 1; }
  [ -n "$REMOTE_MOVE_LOCAL_CONFIG_ROOT" ] || { remote_move_error "devices configuration is missing profiles_home or profiles_root."; return 1; }
  for name in "${REMOTE_MOVE_DEVICE_NAMES[@]}"; do
    [ "$name" != "$REMOTE_MOVE_THIS_DEVICE" ] || { remote_move_error "this_device must not also be declared as a remote device."; return 1; }
  done
}

remote_move_tool_root() {
  local configured_root="$1" tool="$2"
  if [ "$REMOTE_MOVE_ROOT_MODE" = profiles_home ]; then
    printf '%s/%s\n' "$configured_root" "$tool"
    return
  fi
  [ "$(basename "$configured_root")" = "$tool" ] || {
    remote_move_error "Legacy profiles_root '$configured_root' is for '$(basename "$configured_root")', not '$tool'."
    return 1
  }
  printf '%s\n' "$configured_root"
}

remote_move_find_device() {
  local wanted="$1" index
  REMOTE_MOVE_FOUND_SSH=""
  REMOTE_MOVE_FOUND_CONFIG_ROOT=""
  for ((index = 0; index < ${#REMOTE_MOVE_DEVICE_NAMES[@]}; index++)); do
    if [ "${REMOTE_MOVE_DEVICE_NAMES[$index]}" = "$wanted" ]; then
      REMOTE_MOVE_FOUND_SSH="${REMOTE_MOVE_DEVICE_SSH[$index]}"
      REMOTE_MOVE_FOUND_CONFIG_ROOT="${REMOTE_MOVE_DEVICE_ROOTS[$index]}"
      return 0
    fi
  done
  remote_move_error "Device '$wanted' is not configured."
}

remote_move_remote_run() {
  local target="$1" script="$2" quoted arg ssh_command
  shift 2
  ssh_command="${NINI_AGENTS_SSH_COMMAND:-ssh}"
  command -v "$ssh_command" >/dev/null 2>&1 || return 127
  quoted='bash -s --'
  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    quoted="$quoted $arg"
  done
  "$ssh_command" -o BatchMode=yes -o ConnectTimeout=8 "$target" "$quoted" <<< "$script"
}

remote_move_remote_endpoint() {
  local target="$1" root="$2"; shift 2
  remote_move_remote_run "$target" '
    profiles_home=$1
    shift
    nini=$(command -v nini-agents 2>/dev/null || true)
    [ -n "$nini" ] || [ ! -x "$HOME/.local/bin/nini-agents" ] || nini=$HOME/.local/bin/nini-agents
    [ -n "$nini" ] || nini=$HOME/.local/share/nini-agents/nini-agents
    [ -x "$nini" ] || { printf "nini-agents is not installed on the remote device\n" >&2; exit 127; }
    exec env MULTICLI_HOME="$profiles_home" "$nini" _move-endpoint "$@"
  ' "$(dirname "$root")" "$@"
}

remote_move_call() {
  local location="$1" ssh_target="$2" action="$3" tool="$4" root="$5" profile="$6" operation="$7"
  local detail="${8:-}"
  if [ "$location" = local ]; then
    remote_move_endpoint "$action" "$tool" "$root" "$profile" "$operation" "$detail"
  else
    remote_move_remote_endpoint "$ssh_target" "$root" "$action" "$tool" "$root" "$profile" "$operation" "$detail"
  fi
}

remote_move_assert_root() {
  local root="$1"
  case "$root" in /*) ;; *) return 1 ;; esac
  [ -d "$root" ] && [ ! -L "$root" ]
}

remote_move_artifact_path() {
  local root="$1" relative="$2"
  is_safe_adapter_path "$relative" || return 1
  printf '%s/%s\n' "$root" "${relative//\\//}"
}

# Return 0 when a profile is busy, 1 when it is proven idle, and 2 when the
# platform cannot prove either state. Values are compared but never printed.
remote_move_process_probe() {
  local manifest="$1" profile="$2" metadata profile_id="" mode=legacy runtime_root shared_root auth_dir
  local proc command_line environment key raw expanded candidate
  local probes=()
  metadata="$profile/.profile.json"
  if [ -f "$metadata" ] && [ ! -L "$metadata" ]; then
    profile_id="$(runtime_json_str '.profileId' "$metadata")"
    mode="$(runtime_json_str '.mode' "$metadata")"
  fi
  runtime_root="$profile"
  [ "$mode" != accountOverlay ] || runtime_root="$profile/.runtime"
  auth_dir="$profile/auth"
  shared_root="$(runtime_platform_root "$manifest")"
  while IFS=$'\t' read -r key raw; do
    [ -n "$key" ] || continue
    case "$raw" in
      *'{profileDir}'*|*'{profileId}'*|*'{authDir}'*|*'{runtimeRoot}'*)
        expanded="$(runtime_expand_value "$raw" "$profile" "$profile_id" "$auth_dir" "$runtime_root" "$shared_root")"
        probes+=("$key=$expanded")
        # A destination may be absent while a stale schema-v2 process still
        # points at its former runtime. Probe both whole-root and overlay forms.
        if [ ! -e "$metadata" ] && [[ "$raw" == *'{runtimeRoot}'* ]]; then
          expanded="$(runtime_expand_value "$raw" "$profile" "$profile_id" "$auth_dir" "$profile/.runtime" "$shared_root")"
          probes+=("$key=$expanded")
        fi
        ;;
    esac
  done < <(jq -r '.isolation.env // {} | to_entries[] | [.key, .value] | @tsv' "$manifest" 2>/dev/null | tr -d '\r')
  [ -z "$profile_id" ] || probes+=("MULTICLI_PROFILE_ID=$profile_id")
  [ "${#probes[@]}" -gt 0 ] || return 2
  if [ -d /proc ]; then
    for proc in /proc/[0-9]*; do
      [ -r "$proc/environ" ] || continue
      while IFS= read -r -d '' environment; do
        for candidate in "${probes[@]}"; do [ "$environment" != "$candidate" ] || return 0; done
      done 2>/dev/null < "$proc/environ" || true
    done
    return 1
  fi
  case "$(uname -s 2>/dev/null || true)" in
    Darwin)
      while IFS= read -r command_line; do
        for candidate in "${probes[@]}"; do
          case "$command_line" in *"$candidate "*|*"$candidate") return 0 ;; esac
        done
      done < <(ps eww -axo command= 2>/dev/null) || return 2
      return 1
      ;;
    *) return 2 ;;
  esac
}

remote_move_write_launcher() {
  local tool="$1" profile="$2" root="$3" launcher_root launcher temporary
  launcher_root="$(dirname "$root")/bin"
  launcher="$launcher_root/$tool-$profile"
  mkdir -p "$launcher_root" || return 1
  temporary="$launcher.tmp.${BASHPID:-$$}"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export MULTICLI_HOME=%q\n' "$(dirname "$root")"
    printf 'exec %q launch %q "$@"\n' "$SCRIPT_DIR/nini-agents" "$tool/$profile"
  } > "$temporary" || return 1
  chmod 755 "$temporary" || return 1
  mv -- "$temporary" "$launcher"
}

# Internal endpoint used locally and through authenticated SSH. Every path is
# reconstructed below an explicitly configured tool root.
remote_move_endpoint() {
  local action="$1" tool="$2" root="$3" profile="$4" operation="${5:-unused}"
  local detail="${6:-}"
  local manifest target relative path staging backup failed lock tmp rc format mode
  move_safe_component "$tool" && move_safe_component "$profile" || return 64
  [ "$operation" = unused ] || move_safe_component "$operation" || return 64
  remote_move_assert_root "$root" || return 65
  target="$root/$profile"
  staging="$root/.staging/$profile.$operation"
  backup="$root/.inactive/$profile.$operation"
  failed="$root/.failed/$profile.$operation"
  lock="$root/.move-lock.$profile"

  # Ownership discovery and atomic filesystem transitions do not consume an
  # adapter. Avoid reparsing it for every SSH round trip; `health` validates
  # the remote manifest exhaustively and compares its digest before staging.
  case "$action" in
    state) if [ -d "$target" ] && [ ! -L "$target" ]; then printf 'active\n'; elif [ -e "$target" ] || [ -L "$target" ]; then return 70; else printf 'absent\n'; fi; return ;;
    acquire-lock) [ ! -e "$lock" ] && [ ! -L "$lock" ] || return 75; mkdir "$lock"; return ;;
    release-lock) rmdir "$lock"; return ;;
    deactivate) [ -d "$target" ] && [ ! -L "$target" ] && [ ! -e "$backup" ] && [ ! -L "$backup" ] || return 76; mkdir -p "$root/.inactive" && [ ! -L "$root/.inactive" ] && mv -- "$target" "$backup"; return ;;
    restore-source) [ ! -e "$target" ] && [ ! -L "$target" ] && [ -d "$backup" ] && [ ! -L "$backup" ] || return 77; mv -- "$backup" "$target"; return ;;
    activate)
      [ ! -e "$target" ] && [ ! -L "$target" ] && [ -d "$staging" ] && [ ! -L "$staging" ] || return 78
      mv -- "$staging" "$target" || return 78
      rmdir "$root/.staging" 2>/dev/null || true
      return
      ;;
    quarantine) [ -d "$target" ] && [ ! -L "$target" ] && [ ! -e "$failed" ] && [ ! -L "$failed" ] || return 79; mkdir -p "$root/.failed" && [ ! -L "$root/.failed" ] && mv -- "$target" "$failed"; return ;;
    discard-backup)
      [ -d "$lock" ] && [ ! -L "$lock" ] && [ -d "$root/.inactive" ] && [ ! -L "$root/.inactive" ] || return 81
      [ -d "$backup" ] && [ ! -L "$backup" ] || return 81
      [ "${NINI_AGENTS_TEST_FAIL_BACKUP_DISCARD:-0}" != 1 ] || return 81
      rm -rf -- "$backup" || return 81
      [ ! -e "$backup" ] && [ ! -L "$backup" ] || return 81
      rmdir "$root/.inactive" 2>/dev/null || true
      return
      ;;
  esac

  manifest="$(adapter_path "$tool")"
  [ -f "$manifest" ] || return 66
  # The coordinator exhaustively validates its adapter, then requires this
  # byte-for-byte digest before any remote profile validation or mutation.
  # Re-running the exhaustive validator here would add dozens of SSH-side jq
  # parses without strengthening that equality proof.
  [ "$(runtime_json_str '.account.mechanism' "$manifest")" = fileOverlay ] || return 67

  case "$action" in
    health)
      case "$(uname -s 2>/dev/null || true)" in Linux|Darwin) ;; *) return 68 ;; esac
      command -v jq >/dev/null 2>&1 && command -v rsync >/dev/null 2>&1 || return 69
      move_sha256 "$manifest"
      ;;
    validate)
      if move_validate_profile "$manifest" "$target"; then printf '%s|%s\n' "$MOVE_PROFILE_FORMAT" "$MOVE_PROFILE_MODE"; else return $?; fi
      ;;
    prepare-destination)
      [ ! -e "$target" ] && [ ! -L "$target" ] && [ ! -e "$staging" ] && [ ! -L "$staging" ] &&
        [ ! -e "$failed" ] && [ ! -L "$failed" ] && [ ! -e "$lock" ] && [ ! -L "$lock" ] || return 71
      if remote_move_process_probe "$manifest" "$target"; then return 72; else rc=$?; [ "$rc" -eq 1 ] || return 73; fi
      ;;
    probe)
      if remote_move_process_probe "$manifest" "$target"; then return 0; else return $?; fi
      ;;
    reserve-staging)
      [ ! -e "$target" ] && [ ! -L "$target" ] && [ ! -e "$staging" ] && [ ! -L "$staging" ] || return 71
      mkdir -p "$root/.staging" || return 74
      [ ! -L "$root/.staging" ] || return 74
      (umask 077; mkdir "$staging")
      ;;
    validate-staging)
      move_validate_profile "$manifest" "$staging" || return $?
      format="$MOVE_PROFILE_FORMAT"; mode="$MOVE_PROFILE_MODE"
      move_prune_staging_links "$manifest" "$staging" || return 25
      move_validate_profile "$manifest" "$staging" || return $?
      [ "$MOVE_PROFILE_FORMAT" = "$format" ] && [ "$MOVE_PROFILE_MODE" = "$mode" ] || return 22
      printf '%s|%s\n' "$MOVE_PROFILE_FORMAT" "$MOVE_PROFILE_MODE"
      ;;
    inventory)
      case "$detail" in source) path="$target" ;; staging) path="$staging" ;; backup) path="$backup" ;; destination) path="$target" ;; *) return 64 ;; esac
      move_validate_profile "$manifest" "$path" || return $?
      tmp="$(mktemp "${TMPDIR:-/tmp}/nini-remote-inventory.XXXXXX")" || return 1
      if move_write_inventory "$manifest" "$path" "$tmp"; then cat "$tmp"; rc=0; else rc=1; fi
      rm -f "$tmp"
      return "$rc"
      ;;
    finalize)
      move_validate_profile "$manifest" "$target" || return $?
      format="$MOVE_PROFILE_FORMAT"; mode="$MOVE_PROFILE_MODE"
      if [ "$format" = v2 ] && [ "$mode" = accountOverlay ]; then
        TOOL="$tool"
        runtime_build_overlay "$manifest" "$target" >/dev/null || return 80
        runtime_overlay_is_current "$manifest" "$target/.runtime" || return 80
      fi
      remote_move_write_launcher "$tool" "$profile" "$root"
      ;;
    *) return 64 ;;
  esac
}

remote_move_location_state() {
  remote_move_call "$1" "$2" state "$3" "$4" "$5" unused
}

remote_move_locate_owner() {
  local tool="$1" profile="$2" local_root index state root
  REMOTE_MOVE_OWNER=""
  REMOTE_MOVE_OWNER_COUNT=0
  local_root="$(remote_move_tool_root "$REMOTE_MOVE_LOCAL_CONFIG_ROOT" "$tool")" || return 1
  if state="$(remote_move_location_state local '' "$tool" "$local_root" "$profile")"; then
    if [ "$state" = active ]; then REMOTE_MOVE_OWNER="$REMOTE_MOVE_THIS_DEVICE"; REMOTE_MOVE_OWNER_COUNT=1; fi
  else
    remote_move_error "Cannot inspect the local profile root."
    return 1
  fi
  for ((index = 0; index < ${#REMOTE_MOVE_DEVICE_NAMES[@]}; index++)); do
    root="$(remote_move_tool_root "${REMOTE_MOVE_DEVICE_ROOTS[$index]}" "$tool")" || return 1
    if ! state="$(remote_move_location_state remote "${REMOTE_MOVE_DEVICE_SSH[$index]}" "$tool" "$root" "$profile")"; then
      remote_move_error "Device '${REMOTE_MOVE_DEVICE_NAMES[$index]}' is unreachable or failed its ownership probe."
      return 1
    fi
    if [ "$state" = active ]; then
      REMOTE_MOVE_OWNER="${REMOTE_MOVE_DEVICE_NAMES[$index]}"
      REMOTE_MOVE_OWNER_COUNT=$((REMOTE_MOVE_OWNER_COUNT + 1))
    fi
  done
  [ "$REMOTE_MOVE_OWNER_COUNT" -gt 0 ] || { remote_move_error "Profile '$tool/$profile' is not active on any configured device."; return 1; }
  [ "$REMOTE_MOVE_OWNER_COUNT" -eq 1 ] || { remote_move_error "Profile '$tool/$profile' is active on more than one configured device."; return 1; }
}

remote_move_transport() {
  local direction="$1" source="$2" ssh_target="$3" destination="$4" callback rsync_command
  callback="${NINI_AGENTS_TEST_REMOTE_COPY_COMMAND:-}"
  if [ -n "$callback" ]; then
    [ -x "$callback" ] || return 1
    "$callback" "$direction" "$source" "$ssh_target" "$destination"
    return
  fi
  rsync_command="${NINI_AGENTS_RSYNC_COMMAND:-rsync}"
  command -v "$rsync_command" >/dev/null 2>&1 || return 1
  case "$direction" in
    to-remote)
      "$rsync_command" -e 'ssh -o BatchMode=yes -o ConnectTimeout=8' -a --delete --protect-args --exclude=/.runtime -- "$source/" "$ssh_target:$destination/"
      ;;
    from-remote)
      "$rsync_command" -e 'ssh -o BatchMode=yes -o ConnectTimeout=8' -a --delete --protect-args --exclude=/.runtime -- "$ssh_target:$source/" "$destination/"
      ;;
    *) return 1 ;;
  esac
}

remote_move_compare_inventory() {
  local left_location="$1" left_ssh="$2" right_location="$3" right_ssh="$4" tool="$5" left_root="$6" right_root="$7" profile="$8" operation="$9" left_kind="${10}" right_kind="${11}"
  local left_inventory right_inventory rc=1
  left_inventory="$(mktemp "${TMPDIR:-/tmp}/nini-public-move-left.XXXXXX")" || return 1
  right_inventory="$(mktemp "${TMPDIR:-/tmp}/nini-public-move-right.XXXXXX")" || { rm -f "$left_inventory"; return 1; }
  if remote_move_call "$left_location" "$left_ssh" inventory "$tool" "$left_root" "$profile" "$operation" "$left_kind" > "$left_inventory" &&
     remote_move_call "$right_location" "$right_ssh" inventory "$tool" "$right_root" "$profile" "$operation" "$right_kind" > "$right_inventory" &&
     cmp -s "$left_inventory" "$right_inventory"; then
    rc=0
  fi
  rm -f "$left_inventory" "$right_inventory"
  return "$rc"
}

remote_move_release_locks() {
  remote_move_call "$1" "$2" release-lock "$5" "$3" "$4" unused >/dev/null 2>&1 || true
  remote_move_call "$6" "$7" release-lock "$5" "$8" "$4" unused >/dev/null 2>&1 || true
}

remote_move_rollback_active_destination() {
  local source_location="$1" source_ssh="$2" source_root="$3" destination_location="$4" destination_ssh="$5" destination_root="$6" tool="$7" profile="$8" operation="$9" code="${10}"
  if remote_move_call "$destination_location" "$destination_ssh" quarantine "$tool" "$destination_root" "$profile" "$operation" >/dev/null 2>&1 &&
     remote_move_call "$source_location" "$source_ssh" restore-source "$tool" "$source_root" "$profile" "$operation" >/dev/null 2>&1; then
    move_set_result "$code" source_restored "$MOVE_PROFILE_FORMAT"
    return 0
  fi
  move_set_result rollback_failed ownership_indeterminate "$MOVE_PROFILE_FORMAT"
  return 1
}

remote_move_execute() {
  local json_mode="$1"; shift
  local spec="${1:-}" destination_device="${2:-}"; shift 2 2>/dev/null || true
  local dry_run=false discard_source_backup=false config="${NINI_AGENTS_DEVICES_CONFIG:-${CODEXPORTER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/nini-agents/devices.conf}}"
  local tool profile local_root source_location source_ssh source_root destination_location destination_ssh destination_root
  local source_info operation local_digest remote_digest source_device rc
  MOVE_PROFILE_FORMAT=unknown
  MOVE_PROFILE_MODE=unknown
  move_set_result uninitialized preflight unknown
  REMOTE_MOVE_MESSAGE=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=true ;;
      --discard-source-backup) discard_source_backup=true ;;
      --devices-config|--config)
        shift
        [ "$#" -gt 0 ] || { remote_move_fail_result invalid_arguments preflight_rejected unknown 'Missing path after --devices-config.'; return 1; }
        config="$1"
        ;;
      *) remote_move_fail_result invalid_arguments preflight_rejected unknown "Unknown move option '$1'."; return 1 ;;
    esac
    shift
  done
  case "$spec" in */*) tool="${spec%%/*}"; profile="${spec#*/}" ;; *) remote_move_fail_result invalid_identifier preflight_rejected unknown 'Move requires <tool>/<profile>.'; return 1 ;; esac
  move_safe_component "$tool" && move_safe_component "$profile" && move_safe_component "$destination_device" || {
    remote_move_fail_result invalid_identifier preflight_rejected unknown 'Tool, profile, and destination must be safe identifiers.'; return 1;
  }
  remote_move_load_config "$config" || { remote_move_fail_result invalid_configuration preflight_rejected unknown "$REMOTE_MOVE_MESSAGE"; return 1; }
  local_root="$(remote_move_tool_root "$REMOTE_MOVE_LOCAL_CONFIG_ROOT" "$tool")" || { remote_move_fail_result invalid_configuration preflight_rejected unknown "$REMOTE_MOVE_MESSAGE"; return 1; }
  remote_move_assert_root "$local_root" || { remote_move_fail_result unsafe_root preflight_rejected unknown "Local profile root '$local_root' must exist and must not be a link."; return 1; }
  # Public movement consumes the same security-sensitive path contract as
  # launch. Validate that contract in one parse; repository doctor/validation
  # remains the exhaustive schema audit for bundled adapters.
  [ -f "$(adapter_path "$tool")" ] && (load_adapter_launch_contract "$tool") >/dev/null 2>&1 || {
    remote_move_fail_result invalid_adapter preflight_rejected unknown "Adapter '$tool' is missing or invalid."; return 1;
  }
  [ "$(runtime_json_str '.account.mechanism' "$(adapter_path "$tool")")" = fileOverlay ] || {
    remote_move_fail_result unsupported_mechanism preflight_rejected unknown "Adapter '$tool' does not use filesystem credentials."; return 1;
  }
  remote_move_locate_owner "$tool" "$profile" || { remote_move_fail_result ownership_unproven preflight_rejected unknown "$REMOTE_MOVE_MESSAGE"; return 1; }
  source_device="$REMOTE_MOVE_OWNER"
  [ "$REMOTE_MOVE_OWNER" != "$destination_device" ] || { remote_move_fail_result destination_active preflight_rejected unknown "Profile '$spec' is already active on '$destination_device'."; return 1; }

  if [ "$REMOTE_MOVE_OWNER" = "$REMOTE_MOVE_THIS_DEVICE" ]; then
    source_location=local; source_ssh=''; source_root="$local_root"
  else
    remote_move_find_device "$REMOTE_MOVE_OWNER" || { remote_move_fail_result invalid_configuration preflight_rejected unknown "$REMOTE_MOVE_MESSAGE"; return 1; }
    source_location=remote; source_ssh="$REMOTE_MOVE_FOUND_SSH"
    source_root="$(remote_move_tool_root "$REMOTE_MOVE_FOUND_CONFIG_ROOT" "$tool")" || { remote_move_fail_result invalid_configuration preflight_rejected unknown "$REMOTE_MOVE_MESSAGE"; return 1; }
  fi
  if [ "$destination_device" = "$REMOTE_MOVE_THIS_DEVICE" ]; then
    destination_location=local; destination_ssh=''; destination_root="$local_root"
  else
    remote_move_find_device "$destination_device" || { remote_move_fail_result invalid_configuration preflight_rejected unknown "$REMOTE_MOVE_MESSAGE"; return 1; }
    destination_location=remote; destination_ssh="$REMOTE_MOVE_FOUND_SSH"
    destination_root="$(remote_move_tool_root "$REMOTE_MOVE_FOUND_CONFIG_ROOT" "$tool")" || { remote_move_fail_result invalid_configuration preflight_rejected unknown "$REMOTE_MOVE_MESSAGE"; return 1; }
  fi
  [ "$source_location" = local ] || [ "$destination_location" = local ] || {
    remote_move_fail_result remote_to_remote_unsupported preflight_rejected unknown "Move through '$REMOTE_MOVE_THIS_DEVICE' first."; return 1;
  }

  local_digest="$(move_sha256 "$(adapter_path "$tool")")" || { remote_move_fail_result dependency_missing preflight_rejected unknown 'SHA-256 support is required.'; return 1; }
  if [ "$source_location" = remote ]; then
    remote_digest="$(remote_move_call remote "$source_ssh" health "$tool" "$source_root" "$profile" unused)" || { remote_move_fail_result remote_health_failed preflight_rejected unknown "Source device '$REMOTE_MOVE_OWNER' failed its Nini Agents health check."; return 1; }
    [ "$remote_digest" = "$local_digest" ] || { remote_move_fail_result adapter_mismatch preflight_rejected unknown 'Source and controller adapters differ.'; return 1; }
  fi
  if [ "$destination_location" = remote ]; then
    remote_digest="$(remote_move_call remote "$destination_ssh" health "$tool" "$destination_root" "$profile" unused)" || { remote_move_fail_result remote_health_failed preflight_rejected unknown "Destination device '$destination_device' failed its Nini Agents health check."; return 1; }
    [ "$remote_digest" = "$local_digest" ] || { remote_move_fail_result adapter_mismatch preflight_rejected unknown 'Destination and controller adapters differ.'; return 1; }
  fi

  if source_info="$(remote_move_call "$source_location" "$source_ssh" validate "$tool" "$source_root" "$profile" unused)"; then :; else
    rc=$?
    remote_move_validation_result "$rc" preflight_rejected
    REMOTE_MOVE_MESSAGE='The active source profile failed structural validation.'
    return 1
  fi
  MOVE_PROFILE_FORMAT="${source_info%%|*}"
  MOVE_PROFILE_MODE="${source_info#*|}"
  if remote_move_call "$source_location" "$source_ssh" probe "$tool" "$source_root" "$profile" unused >/dev/null 2>&1; then
    remote_move_fail_result process_active preflight_rejected "$MOVE_PROFILE_FORMAT" 'The source profile is in use.'; return 1
  else rc=$?; [ "$rc" -eq 1 ] || { remote_move_fail_result process_probe_failed preflight_rejected "$MOVE_PROFILE_FORMAT" 'The source process probe was inconclusive.'; return 1; }; fi
  remote_move_call "$destination_location" "$destination_ssh" prepare-destination "$tool" "$destination_root" "$profile" unused >/dev/null 2>&1 || {
    remote_move_fail_result destination_unavailable preflight_rejected "$MOVE_PROFILE_FORMAT" 'The destination is active, unsafe, busy, or has conflicting artifacts.'; return 1;
  }
  if [ "$dry_run" = true ]; then
    move_set_result dry_run validated "$MOVE_PROFILE_FORMAT"
    REMOTE_MOVE_MESSAGE="Move preflight succeeded; no files were copied or activated."
    return 0
  fi

  operation="$(date -u +%Y%m%dT%H%M%SZ)-${BASHPID:-$$}"
  remote_move_call "$destination_location" "$destination_ssh" reserve-staging "$tool" "$destination_root" "$profile" "$operation" >/dev/null 2>&1 || {
    remote_move_fail_result staging_create_failed source_active "$MOVE_PROFILE_FORMAT" 'Could not reserve destination staging.'; return 1;
  }
  if [ "$source_location" = local ]; then
    remote_move_transport to-remote "$source_root/$profile" "$destination_ssh" "$destination_root/.staging/$profile.$operation" || {
      remote_move_fail_result transport_failed staging_preserved "$MOVE_PROFILE_FORMAT" 'Transport to remote staging failed.'; return 1;
    }
  else
    remote_move_transport from-remote "$source_root/$profile" "$source_ssh" "$destination_root/.staging/$profile.$operation" || {
      remote_move_fail_result transport_failed staging_preserved "$MOVE_PROFILE_FORMAT" 'Transport from remote staging failed.'; return 1;
    }
  fi
  if remote_move_call "$destination_location" "$destination_ssh" validate-staging "$tool" "$destination_root" "$profile" "$operation" >/dev/null 2>&1; then :; else
    rc=$?
    remote_move_validation_result "$rc" staging_rejected
    REMOTE_MOVE_MESSAGE='The staged profile failed structural validation.'
    return 1
  fi
  remote_move_compare_inventory "$source_location" "$source_ssh" "$destination_location" "$destination_ssh" "$tool" "$source_root" "$destination_root" "$profile" "$operation" source staging || {
    remote_move_fail_result integrity_mismatch staging_rejected "$MOVE_PROFILE_FORMAT" 'Source and staged profile inventories differ.'; return 1;
  }

  remote_move_call "$source_location" "$source_ssh" acquire-lock "$tool" "$source_root" "$profile" unused >/dev/null 2>&1 || {
    remote_move_fail_result transaction_locked staging_preserved "$MOVE_PROFILE_FORMAT" 'Could not acquire the source ownership lock.'; return 1;
  }
  if ! remote_move_call "$destination_location" "$destination_ssh" acquire-lock "$tool" "$destination_root" "$profile" unused >/dev/null 2>&1; then
    remote_move_call "$source_location" "$source_ssh" release-lock "$tool" "$source_root" "$profile" unused >/dev/null 2>&1 || true
    remote_move_fail_result transaction_locked staging_preserved "$MOVE_PROFILE_FORMAT" 'Could not acquire the destination ownership lock.'; return 1
  fi

  if ! remote_move_locate_owner "$tool" "$profile" || [ "$REMOTE_MOVE_OWNER" != "$source_device" ]; then
    remote_move_release_locks "$source_location" "$source_ssh" "$source_root" "$profile" "$tool" "$destination_location" "$destination_ssh" "$destination_root"
    remote_move_fail_result ownership_changed staging_preserved "$MOVE_PROFILE_FORMAT" 'Profile ownership changed during the transaction.'; return 1
  fi
  remote_move_compare_inventory "$source_location" "$source_ssh" "$destination_location" "$destination_ssh" "$tool" "$source_root" "$destination_root" "$profile" "$operation" source staging || {
    remote_move_release_locks "$source_location" "$source_ssh" "$source_root" "$profile" "$tool" "$destination_location" "$destination_ssh" "$destination_root"
    remote_move_fail_result integrity_mismatch staging_rejected "$MOVE_PROFILE_FORMAT" 'The source changed after staging.'; return 1;
  }
  if remote_move_call "$source_location" "$source_ssh" probe "$tool" "$source_root" "$profile" unused >/dev/null 2>&1; then
    remote_move_release_locks "$source_location" "$source_ssh" "$source_root" "$profile" "$tool" "$destination_location" "$destination_ssh" "$destination_root"
    remote_move_fail_result process_appeared staging_preserved "$MOVE_PROFILE_FORMAT" 'A source process appeared during the transaction.'; return 1
  else rc=$?; if [ "$rc" -ne 1 ]; then remote_move_release_locks "$source_location" "$source_ssh" "$source_root" "$profile" "$tool" "$destination_location" "$destination_ssh" "$destination_root"; remote_move_fail_result process_probe_failed staging_preserved "$MOVE_PROFILE_FORMAT" 'The source process probe became inconclusive.'; return 1; fi; fi
  if remote_move_call "$destination_location" "$destination_ssh" probe "$tool" "$destination_root" "$profile" unused >/dev/null 2>&1; then
    remote_move_release_locks "$source_location" "$source_ssh" "$source_root" "$profile" "$tool" "$destination_location" "$destination_ssh" "$destination_root"
    remote_move_fail_result process_appeared staging_preserved "$MOVE_PROFILE_FORMAT" 'A destination process appeared during the transaction.'; return 1
  else rc=$?; if [ "$rc" -ne 1 ]; then remote_move_release_locks "$source_location" "$source_ssh" "$source_root" "$profile" "$tool" "$destination_location" "$destination_ssh" "$destination_root"; remote_move_fail_result process_probe_failed staging_preserved "$MOVE_PROFILE_FORMAT" 'The destination process probe became inconclusive.'; return 1; fi; fi

  if ! remote_move_call "$source_location" "$source_ssh" deactivate "$tool" "$source_root" "$profile" "$operation" >/dev/null 2>&1; then
    remote_move_release_locks "$source_location" "$source_ssh" "$source_root" "$profile" "$tool" "$destination_location" "$destination_ssh" "$destination_root"
    remote_move_fail_result source_deactivation_failed source_active "$MOVE_PROFILE_FORMAT" 'Could not deactivate the source profile.'; return 1
  fi
  if ! remote_move_call "$destination_location" "$destination_ssh" activate "$tool" "$destination_root" "$profile" "$operation" >/dev/null 2>&1; then
    if remote_move_call "$source_location" "$source_ssh" restore-source "$tool" "$source_root" "$profile" "$operation" >/dev/null 2>&1; then
      move_set_result activation_failed_rolled_back source_restored "$MOVE_PROFILE_FORMAT"
    else
      move_set_result rollback_failed ownership_indeterminate "$MOVE_PROFILE_FORMAT"
    fi
    remote_move_release_locks "$source_location" "$source_ssh" "$source_root" "$profile" "$tool" "$destination_location" "$destination_ssh" "$destination_root"
    REMOTE_MOVE_MESSAGE='Destination activation failed.'
    return 1
  fi
  if ! remote_move_call "$destination_location" "$destination_ssh" finalize "$tool" "$destination_root" "$profile" "$operation" >/dev/null 2>&1; then
    remote_move_rollback_active_destination "$source_location" "$source_ssh" "$source_root" "$destination_location" "$destination_ssh" "$destination_root" "$tool" "$profile" "$operation" destination_runtime_failed_rolled_back || true
    remote_move_release_locks "$source_location" "$source_ssh" "$source_root" "$profile" "$tool" "$destination_location" "$destination_ssh" "$destination_root"
    REMOTE_MOVE_MESSAGE='Destination validation or runtime reconstruction failed.'
    return 1
  fi
  if ! remote_move_compare_inventory "$source_location" "$source_ssh" "$destination_location" "$destination_ssh" "$tool" "$source_root" "$destination_root" "$profile" "$operation" backup destination; then
    remote_move_rollback_active_destination "$source_location" "$source_ssh" "$source_root" "$destination_location" "$destination_ssh" "$destination_root" "$tool" "$profile" "$operation" destination_invalid_rolled_back || true
    remote_move_release_locks "$source_location" "$source_ssh" "$source_root" "$profile" "$tool" "$destination_location" "$destination_ssh" "$destination_root"
    REMOTE_MOVE_MESSAGE='Destination content changed after activation.'
    return 1
  fi
  if [ "$discard_source_backup" = true ] &&
     ! remote_move_call "$source_location" "$source_ssh" discard-backup "$tool" "$source_root" "$profile" "$operation" >/dev/null 2>&1; then
    remote_move_release_locks "$source_location" "$source_ssh" "$source_root" "$profile" "$tool" "$destination_location" "$destination_ssh" "$destination_root"
    remote_move_fail_result backup_cleanup_failed destination_active "$MOVE_PROFILE_FORMAT" 'The destination is active, but its verified source backup could not be discarded.'
    return 1
  fi
  if ! remote_move_call "$source_location" "$source_ssh" release-lock "$tool" "$source_root" "$profile" unused >/dev/null 2>&1 ||
     ! remote_move_call "$destination_location" "$destination_ssh" release-lock "$tool" "$destination_root" "$profile" unused >/dev/null 2>&1; then
    move_set_result lock_release_failed destination_active "$MOVE_PROFILE_FORMAT"
    REMOTE_MOVE_MESSAGE='The destination is active, but an ownership lock could not be released.'
    return 1
  fi
  move_set_result ok destination_active "$MOVE_PROFILE_FORMAT"
  if [ "$discard_source_backup" = true ]; then
    REMOTE_MOVE_MESSAGE="Moved '$spec' from '$source_device' to '$destination_device'; the source backup was discarded."
  else
    REMOTE_MOVE_MESSAGE="Moved '$spec' from '$source_device' to '$destination_device'; the source backup was retained."
  fi
  return 0
}

cmd_move() {
  if remote_move_execute false "$@"; then
    printf '%s\n' "$REMOTE_MOVE_MESSAGE"
    return 0
  fi
  printf 'Error: %s [%s; %s]\n' "$REMOTE_MOVE_MESSAGE" "$MOVE_RESULT_CODE" "$MOVE_RESULT_STATE" >&2
  return 1
}

remote_move_devices_command() {
  local subcommand="${1:-}"; shift || true
  local tool=codex spec config="${NINI_AGENTS_DEVICES_CONFIG:-${CODEXPORTER_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/nini-agents/devices.conf}}" profile root state index failed=0 local_digest="" remote_digest=""
  case "$subcommand" in
    list|doctor) if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then tool="$1"; shift; fi ;;
    status) spec="${1:-}"; shift || true; case "$spec" in */*) tool="${spec%%/*}"; profile="${spec#*/}" ;; *) remote_move_error 'Status requires <tool>/<profile>.'; return 2 ;; esac ;;
    *) remote_move_error 'Usage: nini-agents devices <list|status|doctor> ...'; return 2 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in --devices-config|--config) shift; [ "$#" -gt 0 ] || return 2; config="$1" ;; *) remote_move_error "Unknown devices option '$1'."; return 2 ;; esac
    shift
  done
  move_safe_component "$tool" || return 2
  [ "$subcommand" != status ] || move_safe_component "$profile" || return 2
  remote_move_load_config "$config" || return 1
  root="$(remote_move_tool_root "$REMOTE_MOVE_LOCAL_CONFIG_ROOT" "$tool")" || return 1
  case "$subcommand" in
    list)
      printf "Active %s profiles on %s:\n" "$tool" "$REMOTE_MOVE_THIS_DEVICE"
      if [ -d "$root" ] && [ ! -L "$root" ]; then
        local directory
        for directory in "$root"/*/; do [ -d "$directory" ] && [ ! -L "$directory" ] && basename "${directory%/}"; done | LC_ALL=C sort
      fi
      ;;
    status)
      if state="$(remote_move_location_state local '' "$tool" "$root" "$profile" 2>/dev/null)"; then printf '%s: %s\n' "$REMOTE_MOVE_THIS_DEVICE" "$state"; else printf '%s: inaccessible\n' "$REMOTE_MOVE_THIS_DEVICE"; failed=1; fi
      for ((index = 0; index < ${#REMOTE_MOVE_DEVICE_NAMES[@]}; index++)); do
        root="$(remote_move_tool_root "${REMOTE_MOVE_DEVICE_ROOTS[$index]}" "$tool")" || return 1
        if state="$(remote_move_location_state remote "${REMOTE_MOVE_DEVICE_SSH[$index]}" "$tool" "$root" "$profile" 2>/dev/null)"; then printf '%s: %s\n' "${REMOTE_MOVE_DEVICE_NAMES[$index]}" "$state"; else printf '%s: inaccessible\n' "${REMOTE_MOVE_DEVICE_NAMES[$index]}"; failed=1; fi
      done
      return "$failed"
      ;;
    doctor)
      command -v "${NINI_AGENTS_SSH_COMMAND:-ssh}" >/dev/null 2>&1 || { printf 'Missing ssh.\n' >&2; failed=1; }
      command -v "${NINI_AGENTS_RSYNC_COMMAND:-rsync}" >/dev/null 2>&1 || { printf 'Missing rsync.\n' >&2; failed=1; }
      remote_move_assert_root "$root" || { printf 'Invalid local profile root: %s\n' "$root" >&2; failed=1; }
      if [ -f "$(adapter_path "$tool")" ] && (load_adapter_launch_contract "$tool") >/dev/null 2>&1; then
        local_digest="$(move_sha256 "$(adapter_path "$tool")")" || { printf 'Missing local SHA-256 support.\n' >&2; failed=1; }
      else
        printf "Invalid local adapter: %s\n" "$tool" >&2
        failed=1
      fi
      for ((index = 0; index < ${#REMOTE_MOVE_DEVICE_NAMES[@]}; index++)); do
        root="$(remote_move_tool_root "${REMOTE_MOVE_DEVICE_ROOTS[$index]}" "$tool")" || return 1
        if remote_digest="$(remote_move_call remote "${REMOTE_MOVE_DEVICE_SSH[$index]}" health "$tool" "$root" probe unused 2>/dev/null)" &&
           [ -n "$local_digest" ] && [ "$remote_digest" = "$local_digest" ]; then
          printf '%s: ready\n' "${REMOTE_MOVE_DEVICE_NAMES[$index]}"
        else
          printf '%s: unavailable or incompatible\n' "${REMOTE_MOVE_DEVICE_NAMES[$index]}" >&2
          failed=1
        fi
      done
      [ "$failed" -eq 0 ] && printf 'Nini Agents device movement: ready\n'
      return "$failed"
      ;;
  esac
}
