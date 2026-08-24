#!/usr/bin/env bash
# Persistent shared Codex permission presets for nini-agents.

codex_permissions_values() {
  local mode="$1"
  case "$mode" in
    read-only)
      CODEX_PERMISSION_PROFILE=':read-only'
      CODEX_APPROVAL_POLICY='on-request'
      ;;
    workspace)
      CODEX_PERMISSION_PROFILE=':workspace'
      CODEX_APPROVAL_POLICY='on-request'
      ;;
    full-access)
      CODEX_PERMISSION_PROFILE=':danger-full-access'
      CODEX_APPROVAL_POLICY='never'
      ;;
    *) abort "Unknown permission preset '$mode'. Use: read-only, workspace, or full-access" ;;
  esac
}

codex_permissions_mode_from_profile() {
  case "$1" in
    :read-only) printf 'read-only\n' ;;
    :workspace) printf 'workspace\n' ;;
    :danger-full-access) printf 'full-access\n' ;;
    '') printf 'unset\n' ;;
    *) printf 'custom (%s)\n' "$1" ;;
  esac
}

codex_permissions_root_key_count() {
  local config="$1" key="$2"
  [ -f "$config" ] || { printf '0\n'; return; }
  awk -v key="$key" '
    BEGIN { root = 1; count = 0 }
    /^[[:space:]]*\[/ { root = 0 }
    root && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { count++ }
    END { print count }
  ' "$config"
}

codex_permissions_root_value() {
  local config="$1" key="$2"
  [ -f "$config" ] || return 0
  awk -v key="$key" '
    BEGIN { root = 1 }
    /^[[:space:]]*\[/ { root = 0 }
    root && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      value = $0
      sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", value)
      sub(/[[:space:]]*#[^\"]*$/, "", value)
      sub(/^[[:space:]]*\"/, "", value)
      sub(/\"[[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "$config"
}

codex_permissions_show() {
  local config="$1" profile approval mode legacy
  profile="$(codex_permissions_root_value "$config" default_permissions)"
  approval="$(codex_permissions_root_value "$config" approval_policy)"
  legacy="$(codex_permissions_root_value "$config" sandbox_mode)"
  mode="$(codex_permissions_mode_from_profile "$profile")"
  [ -n "$approval" ] || approval=unset
  printf 'Codex shared permissions\n'
  printf '  mode: %s\n' "$mode"
  printf '  approval: %s\n' "$approval"
  printf '  config: %s\n' "$config"
  printf '  scope: shared Codex profiles; new sessions\n'
  [ -z "$legacy" ] || printf '  warning: legacy sandbox_mode=%s overrides permission profiles\n' "$legacy"
}

codex_permissions_rewrite() {
  local source="$1" destination="$2" profile="$3" approval="$4"
  awk -v profile="$profile" -v approval="$approval" '
    function emit_missing() {
      if (!profile_written) { print "default_permissions = \"" profile "\""; profile_written = 1 }
      if (!approval_written) { print "approval_policy = \"" approval "\""; approval_written = 1 }
    }
    BEGIN { root = 1; skip_legacy_table = 0; profile_written = 0; approval_written = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*\[/) {
        if (root) { emit_missing(); root = 0 }
        if (line ~ /^[[:space:]]*\[sandbox_workspace_write([.][^]]+)?\][[:space:]]*(#.*)?$/) {
          skip_legacy_table = 1
          next
        }
        skip_legacy_table = 0
      }
      if (skip_legacy_table) { next }
      if (root && line ~ /^[[:space:]]*default_permissions[[:space:]]*=/) {
        print "default_permissions = \"" profile "\""
        profile_written = 1
        next
      }
      if (root && line ~ /^[[:space:]]*approval_policy[[:space:]]*=/) {
        print "approval_policy = \"" approval "\""
        approval_written = 1
        next
      }
      if (root && line ~ /^[[:space:]]*sandbox_mode[[:space:]]*=/) { next }
      print line
    }
    END { if (root) { emit_missing() } }
  ' "$source" > "$destination"
}

codex_permissions_set() {
  local config="$1" mode="$2" codex_binary="$3"
  local config_dir temp validation_dir='' key count source
  codex_permissions_values "$mode"
  config_dir="$(dirname "$config")"
  [ ! -L "$config" ] || abort "Refusing to update Codex permissions: config.toml is a link."
  [ ! -e "$config" ] || [ -f "$config" ] || abort "Refusing to update Codex permissions: config.toml is not a regular file."
  mkdir -p "$config_dir"

  for key in default_permissions approval_policy sandbox_mode; do
    count="$(codex_permissions_root_key_count "$config" "$key")"
    [ "$count" -le 1 ] || abort "Refusing to update Codex permissions: duplicate top-level '$key' keys."
  done

  temp="$(mktemp "$config_dir/.config.toml.nini.XXXXXX")" || abort "Cannot create a staged Codex config."
  trap 'rm -f "$temp" 2>/dev/null || true; [ -z "$validation_dir" ] || rm -rf "$validation_dir" 2>/dev/null || true' EXIT HUP INT TERM
  if [ -f "$config" ]; then
    source="$config"
  else
    source=/dev/null
  fi
  codex_permissions_rewrite "$source" "$temp" "$CODEX_PERMISSION_PROFILE" "$CODEX_APPROVAL_POLICY"
  if ! runtime_is_windows_shell; then chmod 600 "$temp"; fi

  validation_dir="$(mktemp -d "${TMPDIR:-/tmp}/nini-permissions.XXXXXX")" || abort "Cannot create a Codex config validation directory."
  cp "$temp" "$validation_dir/config.toml"
  if ! CODEX_HOME="$validation_dir" "$codex_binary" --strict-config --version >/dev/null 2>&1; then
    abort "Codex rejected the staged permissions config; the existing config was not changed."
  fi
  rm -rf "$validation_dir"
  validation_dir=''
  [ ! -L "$config" ] || abort "Refusing to replace Codex permissions: config.toml became a link."
  mv -f "$temp" "$config"
  if ! runtime_is_windows_shell; then chmod 600 "$config"; fi
  trap - EXIT HUP INT TERM
  printf "Saved Codex permission preset '%s' for shared Codex profiles. New sessions will use it.\n" "$mode"
}
