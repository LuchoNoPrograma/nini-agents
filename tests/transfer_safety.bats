#!/usr/bin/env bats

load helpers/common

# Allowlist-driven template/export/import safety for schema-v2 profiles.
# Every test builds real temp trees: real junctions/hardlinks via the same
# mechanisms the runtime uses, real tar archives, no mocks.

setup() {
  setup_scratch
  export PATH="$MULTICLI_HOME/bin:$PATH"
  TOOLS_ROOT="$MULTICLI_SCRATCH/tools"
  mkdir -p "$TOOLS_ROOT/fixture" "$TOOLS_ROOT/fixture2"
  export USERPROFILE="$HOME"
  export APPDATA="$HOME/AppData/Roaming"
  export LOCALAPPDATA="$HOME/AppData/Local"
  write_transfer_fixture_adapters
  FIXTURE_MANIFEST="$TOOLS_ROOT/fixture/adapter.json"
  FIXTURE2_MANIFEST="$TOOLS_ROOT/fixture2/adapter.json"
  SHARED_ROOT="$HOME/.fixture"
  TEMPLATES_ROOT="$MULTICLI_HOME/.templates"
}

teardown() {
  teardown_scratch
}

# Invoke a transfer/runtime function in a child shell that has sourced the
# real launcher (providing abort/platform/resolve_path_token and the runtime
# libs) and lib/transfer.sh, mirroring how nini-agents itself will call them.
transfer_run() {
  bash -c '
    root="$1"; shift
    args=("$@")
    cd "$root" || exit 1
    set -- help
    source ./nini-agents >/dev/null 2>&1
    source ./lib/transfer.sh
    "${args[@]+"${args[@]}"}"
  ' transfer-run "$MULTICLI_REPO_ROOT" "$@"
}

write_transfer_fixture_adapters() {
  cat > "$TOOLS_ROOT/fixture/adapter.json" <<'JSON'
{
  "schemaVersion": 2,
  "id": "fixture",
  "displayName": "Fixture CLI",
  "kind": "cli",
  "binary": {
    "windows": ["fixture.exe"],
    "macos": ["fixture"],
    "linux": ["fixture"]
  },
  "isolation": {
    "strategy": "accountOverlay",
    "mode": "foreground",
    "env": { "FIXTURE_HOME": "{runtimeRoot}" },
    "clearEnv": []
  },
  "account": {
    "mechanism": "fileOverlay",
    "credentialFiles": ["auth.json"],
    "credentialPrecedence": ["auth.json"],
    "logoutScope": "profile"
  },
  "normalState": {
    "root": {
      "windows": "%USERPROFILE%\\.fixture",
      "macos": "$HOME/.fixture",
      "linux": "$HOME/.fixture"
    },
    "sharedPaths": ["config.toml", "agents"],
    "sessionPaths": ["sessions", "history.jsonl"],
    "filePaths": ["config.toml", "history.jsonl"],
    "unsafePaths": []
  },
  "concurrency": {
    "level": "multiWriter",
    "singletonScope": "none"
  },
  "support": {
    "windows": { "level": "supported", "reason": "Fixture only." },
    "macos": { "level": "supported", "reason": "Fixture only." },
    "linux": { "level": "supported", "reason": "Fixture only." }
  },
  "install": "https://example.test/install",
  "versionCommand": ["--version"]
}
JSON
  sed 's/"id": "fixture"/"id": "fixture2"/' "$TOOLS_ROOT/fixture/adapter.json" > "$TOOLS_ROOT/fixture2/adapter.json"
}

# Populate the native shared root with ordinary state, sessions, and decoy
# credential files that must never travel.
seed_transfer_shared_root() {
  mkdir -p "$SHARED_ROOT/agents/nested" "$SHARED_ROOT/sessions"
  printf 'model = "gpt-5"\n' > "$SHARED_ROOT/config.toml"
  printf '# reviewer agent\n' > "$SHARED_ROOT/agents/reviewer.md"
  printf '{"OPENAI_API_KEY":"sk-decoy-nested"}\n' > "$SHARED_ROOT/agents/auth.json"
  printf '{"token":"sk-decoy-deep"}\n' > "$SHARED_ROOT/agents/nested/.credentials.json"
  printf 'session-bytes\n' > "$SHARED_ROOT/sessions/rollout.jsonl"
  printf 'history-bytes\n' > "$SHARED_ROOT/history.jsonl"
}

# Create a schema-v2 profile and build its real overlay (junctions/hardlinks).
# Sets TRANSFER_PROFILE_DIR.
make_overlay_profile() {
  local name="$1"
  run multicli new "fixture/$name" --no-seed
  [ "$status" -eq 0 ]
  TRANSFER_PROFILE_DIR="$MULTICLI_HOME/fixture/$name"
  build_test_overlay "$TRANSFER_PROFILE_DIR"
}

# runtime_build_overlay's no-op cleanup path returns non-zero when .runtime is
# absent, so it only survives set -e in a status-checked context (the launcher
# calls it inside a command substitution). Mirror that context here and verify
# the overlay physically appeared.
build_test_overlay() {
  local profile_dir="$1"
  run bash -c '
    root="$1"; manifest="$2"; pdir="$3"
    cd "$root" || exit 1
    set -- help
    source ./nini-agents >/dev/null 2>&1
    runtime_build_overlay "$manifest" "$pdir" || true
    [ -e "$pdir/.runtime" ]
  ' _ "$MULTICLI_REPO_ROOT" "$FIXTURE_MANIFEST" "$profile_dir"
  [ "$status" -eq 0 ]
}

# A directory link via the platform's own mechanism, mirroring the runtime
# (lib/multicli-runtime.sh): symlink on POSIX, real NTFS junction on Windows.
make_junction() {
  local target="$1" link="$2"
  if command -v cygpath >/dev/null 2>&1 && command -v powershell.exe >/dev/null 2>&1; then
    local target_win link_win
    target_win="$(cygpath -w "$target")"
    link_win="$(cygpath -w "$link")"
    powershell.exe -NoProfile -Command "New-Item -ItemType Junction -Path '$link_win' -Target '$target_win' | Out-Null" >/dev/null
  else
    ln -s "$target" "$link"
  fi
  [ -e "$link" ]
}

need_gnu_tar() {
  tar --version 2>/dev/null | grep -q 'GNU tar' || skip "hostile name fixtures require GNU tar"
}

# Archive whose entries have hostile names but regular-file types, built live.
make_hostile_name_archive() {
  local kind="$1" out="$2" dir
  dir="$(mktemp -d "$MULTICLI_SCRATCH/hostile.XXXXXX")"
  printf 'evil\n' > "$dir/seed.txt"
  printf 'other\n' > "$dir/other.txt"
  case "$kind" in
    traversal) (cd "$dir" && tar -czf "$out" --transform 's|^seed.txt|../evil.txt|' seed.txt 2>/dev/null) ;;
    absolute)  (cd "$dir" && tar -czpf "$out" --transform 's|^seed.txt|/evil.txt|' seed.txt 2>/dev/null) ;;
    drive)     (cd "$dir" && tar -czf "$out" --transform 's|^seed.txt|C:/evil.txt|' seed.txt 2>/dev/null) ;;
    ads)       (cd "$dir" && tar -czf "$out" --transform 's|^seed.txt|evil.txt:stream|' seed.txt 2>/dev/null) ;;
    duplicate) (cd "$dir" && tar -czf "$out" --transform 's|^seed.txt|agents/Note.md|' --transform 's|^other.txt|agents/note.md|' seed.txt other.txt 2>/dev/null) ;;
    *) return 1 ;;
  esac
  tar -tzf "$out" >/dev/null 2>&1
}

# Archives containing link entries (type bytes cannot be forged by tar
# --transform), pinned as base64 blobs produced with python tarfile.
write_link_archive() {
  local kind="$1" out="$2"
  case "$kind" in
    symlink)
      base64 -d > "$out" <<'B64'
H4sICD5QWmoC/3N5bWxpbmsudGFyAO3SQQqDQAyF4ax7Ci9g0UGb80gZRJQRNAW9fYNLXbhSKP2/TbJLyMucYtOv+dCl/mmLyRUK96qqrbp9PfZl0LqQLFgztdEu22vzmX2Kj5f/dMeJT/MvdfcLqhokuyUT8vf88/eYLCZ7CAAAAAAAAAAAAAAAAIDf8QWP880MACgAAA==
B64
      ;;
    hardlink)
      base64 -d > "$out" <<'B64'
H4sICD5QWmoC/2hhcmRsaW5rLnRhcgDt1DsKhUAMheHUrsIVyMTXfqYQGRiuoKO4fIOVWNkoXOb/moTTpDqZ5jCGn49V2pO8xJm+bc9p7tN0l91ydY1FpZMPrEvys52XPA1biIUgVz4Gv7xZ/kf9v+1aa6NS6vTBc8q8/wAAAAAAAAAAAAAAAPhvB2U/2PcAKAAA
B64
      ;;
    *) return 1 ;;
  esac
}

# Stage a directory and pack it as an import candidate archive.
pack_staged_archive() {
  local staging="$1" out="$2"
  (cd "$staging" && tar -czf "$out" .)
}

write_staged_manifest() {
  local adapter_id="$1" staging="$2"
  jq -n --arg id "$adapter_id" \
    '{schemaVersion:2,adapterId:$id,name:"staged",kind:"export",createdUtc:"2026-07-17T00:00:00Z"}' \
    > "$staging/.multicli-manifest.json"
}

archive_entries() {
  tar -tzf "$1" | sed 's|^\./||' | grep -v '^\.$' | grep -v '^$' | sort
}

@test "template save copies only shared ordinary state and excludes credentials at root and nested" {
  seed_transfer_shared_root
  make_overlay_profile account-a
  local profile_dir="$TRANSFER_PROFILE_DIR"
  printf '{"OPENAI_API_KEY":"sk-live-must-stay"}\n' > "$profile_dir/auth/auth.json"
  make_hardlink "$SHARED_ROOT/config.toml" "$SHARED_ROOT/agents/hardlinked.md" || skip "host cannot create hardlinks"

  run transfer_run transfer_save_template "$FIXTURE_MANIFEST" "$profile_dir" "$TEMPLATES_ROOT" mytpl false

  [ "$status" -eq 0 ]
  local tpl="$TEMPLATES_ROOT/mytpl"
  [ -f "$tpl/config.toml" ]
  [ "$(cat "$tpl/config.toml" | tr -d '\r')" = 'model = "gpt-5"' ]
  [ -f "$tpl/agents/reviewer.md" ]
  [ -f "$tpl/.multicli-manifest.json" ]
  # credential files are never included, at any depth
  [ ! -e "$tpl/auth.json" ]
  [ ! -e "$tpl/agents/auth.json" ]
  [ ! -e "$tpl/agents/nested/.credentials.json" ]
  [ ! -e "$tpl/agents/nested" ]
  # hardlinks are never included (nlink > 1 cannot prove what it aliases)
  [ ! -e "$tpl/agents/hardlinked.md" ]
  # sessions, runtime, auth boundary, and profile identity never travel
  [ ! -e "$tpl/sessions" ]
  [ ! -e "$tpl/history.jsonl" ]
  [ ! -e "$tpl/.runtime" ]
  [ ! -e "$tpl/auth" ]
  [ ! -e "$tpl/.profile.json" ]
  # the template contains no link artifacts of any kind
  [ -z "$(find "$tpl" -type l -print -quit)" ]
  run jq -er '.adapterId == "fixture" and .schemaVersion == 2 and .name == "mytpl" and .kind == "template" and (.createdUtc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$tpl/.multicli-manifest.json"
  [ "$status" -eq 0 ]
}

@test "template save excludes a nested junction into the shared root without following it" {
  seed_transfer_shared_root
  make_overlay_profile account-a
  local profile_dir="$TRANSFER_PROFILE_DIR"
  make_junction "$SHARED_ROOT" "$SHARED_ROOT/agents/loop"

  run transfer_run transfer_save_template "$FIXTURE_MANIFEST" "$profile_dir" "$TEMPLATES_ROOT" mytpl false

  [ "$status" -eq 0 ]
  local tpl="$TEMPLATES_ROOT/mytpl"
  [ -f "$tpl/agents/reviewer.md" ]
  [ ! -e "$tpl/agents/loop" ]
  [ -z "$(find "$tpl" -type l -print -quit)" ]
}

@test "template save refuses an overlay link pointing outside the profile shared state" {
  seed_transfer_shared_root
  make_overlay_profile account-a
  local profile_dir="$TRANSFER_PROFILE_DIR"
  run transfer_run runtime_remove_overlay "$FIXTURE_MANIFEST" "$profile_dir/.runtime"
  [ "$status" -eq 0 ]
  mkdir -p "$HOME/outside"
  printf 'secret\n' > "$HOME/outside/secret.txt"
  mkdir -p "$profile_dir/.runtime"
  make_junction "$HOME/outside" "$profile_dir/.runtime/agents"

  run transfer_run transfer_save_template "$FIXTURE_MANIFEST" "$profile_dir" "$TEMPLATES_ROOT" mytpl false

  [ "$status" -eq 1 ]
  [[ "$output" == *"outside"* ]]
  [ ! -e "$TEMPLATES_ROOT/mytpl" ]
}

@test "template save refuses shared content that matches secret patterns" {
  seed_transfer_shared_root
  make_overlay_profile account-a
  local profile_dir="$TRANSFER_PROFILE_DIR"
  printf 'note: use sk-live-12345 to authenticate\n' > "$SHARED_ROOT/agents/notes.md"

  run transfer_run transfer_save_template "$FIXTURE_MANIFEST" "$profile_dir" "$TEMPLATES_ROOT" mytpl false

  [ "$status" -eq 1 ]
  [[ "$output" == *"secret"* ]]
  [ ! -e "$TEMPLATES_ROOT/mytpl" ]
}

@test "template save refuses oversized and binary files it cannot scan" {
  seed_transfer_shared_root
  make_overlay_profile account-a
  local profile_dir="$TRANSFER_PROFILE_DIR"
  python - "$SHARED_ROOT/agents/big.txt" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(b'x' * (1024 * 1024 + 1) + b'OPENAI_API_KEY=sk-large')
PY

  run transfer_run transfer_save_template "$FIXTURE_MANIFEST" "$profile_dir" "$TEMPLATES_ROOT" large false

  [ "$status" -eq 1 ]
  [[ "$output" == *"larger than"*"secret-scan limit"* ]]
  rm -f "$SHARED_ROOT/agents/big.txt"
  printf '\0sk-binary-secret\n' > "$SHARED_ROOT/agents/binary.dat"

  run transfer_run transfer_save_template "$FIXTURE_MANIFEST" "$profile_dir" "$TEMPLATES_ROOT" binary false

  [ "$status" -eq 1 ]
  [[ "$output" == *"binary"*"secret-scanned safely"* ]]
}

@test "template save dry-run reports the plan and writes nothing" {
  seed_transfer_shared_root
  make_overlay_profile account-a
  local profile_dir="$TRANSFER_PROFILE_DIR"

  run transfer_run transfer_save_template "$FIXTURE_MANIFEST" "$profile_dir" "$TEMPLATES_ROOT" mytpl true

  [ "$status" -eq 0 ]
  [[ "$output" == *"config.toml"* ]]
  [[ "$output" == *"agents/reviewer.md"* ]]
  [ ! -e "$TEMPLATES_ROOT" ]
}

@test "template from another adapter is refused at apply time" {
  seed_transfer_shared_root
  make_overlay_profile account-a
  local profile_dir="$TRANSFER_PROFILE_DIR"
  run transfer_run transfer_save_template "$FIXTURE_MANIFEST" "$profile_dir" "$TEMPLATES_ROOT" mytpl false
  [ "$status" -eq 0 ]

  run transfer_run transfer_assert_template_compatible "$TEMPLATES_ROOT/mytpl" "$FIXTURE2_MANIFEST"

  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be applied to 'fixture2'"* ]]
  run transfer_run transfer_assert_template_compatible "$TEMPLATES_ROOT/mytpl" "$FIXTURE_MANIFEST"
  [ "$status" -eq 0 ]
}

@test "export then import round-trips ordinary state with a fresh profile id and empty credential placeholders" {
  seed_transfer_shared_root
  local profile_dir archive original_id
  make_overlay_profile account-a
  local profile_dir="$TRANSFER_PROFILE_DIR"
  printf '{"OPENAI_API_KEY":"sk-live-must-stay"}\n' > "$profile_dir/auth/auth.json"
  original_id="$(jq -r '.profileId' "$profile_dir/.profile.json")"
  archive="$MULTICLI_SCRATCH/export.tar.gz"

  run transfer_run transfer_export_profile "$FIXTURE_MANIFEST" "$profile_dir" "$archive" account-a

  [ "$status" -eq 0 ]
  [ -f "$archive" ]
  local entries
  entries="$(archive_entries "$archive")"
  printf '%s\n' "$entries" | grep -qx 'config.toml'
  printf '%s\n' "$entries" | grep -qx 'agents/reviewer.md'
  printf '%s\n' "$entries" | grep -qx '.profile.json'
  printf '%s\n' "$entries" | grep -qx '.multicli-manifest.json'
  ! printf '%s\n' "$entries" | grep -qx 'auth.json'
  ! printf '%s\n' "$entries" | grep -qx 'auth'
  ! printf '%s\n' "$entries" | grep -qx 'sessions'
  ! printf '%s\n' "$entries" | grep -qx 'history.jsonl'
  ! printf '%s\n' "$entries" | grep -qx '.runtime'

  local dest="$MULTICLI_HOME/fixture/account-b"
  run transfer_run transfer_import_profile "$archive" "$FIXTURE_MANIFEST" "$dest"

  [ "$status" -eq 0 ]
  [ "$(cat "$SHARED_ROOT/config.toml" | tr -d '\r')" = 'model = "gpt-5"' ]
  [ -f "$SHARED_ROOT/agents/reviewer.md" ]
  [ ! -e "$dest/config.toml" ]
  [ ! -e "$dest/sessions" ]
  [ ! -e "$dest/history.jsonl" ]
  [ ! -e "$dest/.runtime" ]
  [ -z "$(find "$dest" -type l -print -quit)" ]
  # a fresh stable identity is generated; the exported one is never reused
  run jq -er '.schemaVersion == 2 and .adapterId == "fixture" and .mode == "accountOverlay" and (.profileId | test("^[a-f0-9-]{36}$"))' "$dest/.profile.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.profileId' "$dest/.profile.json")" != "$original_id" ]
  # credential placeholders are recreated empty; exported secrets never cross
  [ -f "$dest/auth/auth.json" ]
  [ ! -s "$dest/auth/auth.json" ]
}

@test "import rejects archive entries that escape, qualify, stream, or duplicate paths" {
  need_gnu_tar
  seed_transfer_shared_root
  local kind expected archive dest
  local kinds=(traversal absolute drive ads duplicate)
  local expectations=("escapes the profile" "absolute path" "drive-qualified" "alternate data stream" "duplicate")
  for i in "${!kinds[@]}"; do
    kind="${kinds[$i]}"
    expected="${expectations[$i]}"
    archive="$MULTICLI_SCRATCH/hostile-$kind.tar.gz"
    dest="$MULTICLI_HOME/fixture/evil-$kind"
    make_hostile_name_archive "$kind" "$archive"

    run transfer_run transfer_import_profile "$archive" "$FIXTURE_MANIFEST" "$dest"

    [ "$status" -eq 1 ]
    [[ "$output" == *"$expected"* ]] || {
      printf 'hostile case %s expected %s, got: %s\n' "$kind" "$expected" "$output" >&2
      false
    }
    [ ! -e "$dest" ]
  done
}

@test "import rejects link entries inside archives" {
  seed_transfer_shared_root
  local kind archive dest expected
  for kind in symlink hardlink; do
    archive="$MULTICLI_SCRATCH/hostile-$kind.tar.gz"
    dest="$MULTICLI_HOME/fixture/evil-$kind"
    write_link_archive "$kind" "$archive"

    run transfer_run transfer_import_profile "$archive" "$FIXTURE_MANIFEST" "$dest"

    [ "$status" -eq 1 ]
    [[ "$output" == *"not adapter-declared shared state"* || "$output" == *"not a regular file or directory"* ]]
    [ ! -e "$dest" ]
  done
}

@test "import rejects credential entries at root and nested" {
  seed_transfer_shared_root
  local staging archive dest
  staging="$(mktemp -d "$MULTICLI_SCRATCH/staged.XXXXXX")"
  printf 'model = "gpt-5"\n' > "$staging/config.toml"
  printf '{"OPENAI_API_KEY":"sk-forged"}\n' > "$staging/auth.json"
  write_staged_manifest fixture "$staging"
  archive="$MULTICLI_SCRATCH/cred-root.tar.gz"
  pack_staged_archive "$staging" "$archive"
  dest="$MULTICLI_HOME/fixture/evil-cred-root"

  run transfer_run transfer_import_profile "$archive" "$FIXTURE_MANIFEST" "$dest"

  [ "$status" -eq 1 ]
  [[ "$output" == *"credential"* ]]
  [ ! -e "$dest" ]

  local staging2 archive2 dest2
  staging2="$(mktemp -d "$MULTICLI_SCRATCH/staged.XXXXXX")"
  mkdir -p "$staging2/agents"
  printf 'x\n' > "$staging2/agents/.credentials.json"
  write_staged_manifest fixture "$staging2"
  archive2="$MULTICLI_SCRATCH/cred-nested.tar.gz"
  pack_staged_archive "$staging2" "$archive2"
  dest2="$MULTICLI_HOME/fixture/evil-cred-nested"

  run transfer_run transfer_import_profile "$archive2" "$FIXTURE_MANIFEST" "$dest2"

  [ "$status" -eq 1 ]
  [[ "$output" == *"credential"* ]]
  [ ! -e "$dest2" ]
}

@test "import refuses archives with a foreign or missing adapter manifest" {
  seed_transfer_shared_root
  local staging archive dest
  staging="$(mktemp -d "$MULTICLI_SCRATCH/staged.XXXXXX")"
  printf 'model = "gpt-5"\n' > "$staging/config.toml"
  write_staged_manifest other-adapter "$staging"
  archive="$MULTICLI_SCRATCH/foreign.tar.gz"
  pack_staged_archive "$staging" "$archive"
  dest="$MULTICLI_HOME/fixture/foreign"

  run transfer_run transfer_import_profile "$archive" "$FIXTURE_MANIFEST" "$dest"

  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be imported as 'fixture'"* ]]
  [ ! -e "$dest" ]

  local staging2 archive2 dest2
  staging2="$(mktemp -d "$MULTICLI_SCRATCH/staged.XXXXXX")"
  printf 'model = "gpt-5"\n' > "$staging2/config.toml"
  archive2="$MULTICLI_SCRATCH/nomanifest.tar.gz"
  pack_staged_archive "$staging2" "$archive2"
  dest2="$MULTICLI_HOME/fixture/nomanifest"

  run transfer_run transfer_import_profile "$archive2" "$FIXTURE_MANIFEST" "$dest2"

  [ "$status" -eq 1 ]
  [[ "$output" == *"no nini-agents manifest"* ]]
  [ ! -e "$dest2" ]
}

@test "import refuses staged content that matches secret patterns" {
  seed_transfer_shared_root
  local staging archive dest
  staging="$(mktemp -d "$MULTICLI_SCRATCH/staged.XXXXXX")"
  printf 'model = "gpt-5"\n' > "$staging/config.toml"
  mkdir -p "$staging/agents"
  printf 'Authorization: Bearer abc123\n' > "$staging/agents/notes.md"
  write_staged_manifest fixture "$staging"
  archive="$MULTICLI_SCRATCH/secret.tar.gz"
  pack_staged_archive "$staging" "$archive"
  dest="$MULTICLI_HOME/fixture/secret"

  run transfer_run transfer_import_profile "$archive" "$FIXTURE_MANIFEST" "$dest"

  [ "$status" -eq 1 ]
  [[ "$output" == *"secret"* ]]
  [ ! -e "$dest" ]
}

@test "export refuses shared content that matches secret patterns and writes no archive" {
  seed_transfer_shared_root
  local profile_dir archive
  make_overlay_profile account-a
  local profile_dir="$TRANSFER_PROFILE_DIR"
  printf '{"access_token":"ya29.forged"}\n' > "$SHARED_ROOT/config.toml"
  archive="$MULTICLI_SCRATCH/export.tar.gz"

  run transfer_run transfer_export_profile "$FIXTURE_MANIFEST" "$profile_dir" "$archive" account-a

  [ "$status" -eq 1 ]
  [[ "$output" == *"secret"* ]]
  [ ! -e "$archive" ]
}

@test "new --from with an incompatible template refuses before creating the profile" {
  seed_transfer_shared_root
  make_overlay_profile account-a
  run transfer_run transfer_save_template "$FIXTURE_MANIFEST" "$TRANSFER_PROFILE_DIR" "$TEMPLATES_ROOT" tpl false
  [ "$status" -eq 0 ]

  run multicli new fixture2/wrong --from tpl
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot be applied to 'fixture2'"* ]]
  [ ! -e "$MULTICLI_HOME/fixture2/wrong" ]
}

@test "ordinary template and import install state where account-overlay launch reads it" {
  seed_transfer_shared_root
  make_overlay_profile account-a
  local profile_dir="$TRANSFER_PROFILE_DIR"

  run multicli template save fixture/account-a tpl
  [ "$status" -eq 0 ]
  printf 'shared-after-save\n' > "$SHARED_ROOT/config.toml"

  run multicli new fixture/fromtpl --from tpl
  [ "$status" -eq 0 ]
  [ -f "$MULTICLI_HOME/fixture/fromtpl/.profile.json" ]
  [ "$(cat "$SHARED_ROOT/config.toml" | tr -d '\r')" = 'model = "gpt-5"' ]
  [ ! -e "$MULTICLI_HOME/fixture/fromtpl/config.toml" ]

  local archive="$MULTICLI_SCRATCH/roundtrip.tar.gz"
  run multicli export fixture/fromtpl "$archive"
  [ "$status" -eq 0 ]
  printf 'shared-before-import\n' > "$SHARED_ROOT/config.toml"

  run multicli import "$archive" fixture/imported
  [ "$status" -eq 0 ]
  [ "$(cat "$SHARED_ROOT/config.toml" | tr -d '\r')" = 'model = "gpt-5"' ]
  [ ! -e "$MULTICLI_HOME/fixture/imported/config.toml" ]
  [ "$(jq -r '.profileId' "$MULTICLI_HOME/fixture/imported/.profile.json")" != "$(jq -r '.profileId' "$MULTICLI_HOME/fixture/fromtpl/.profile.json")" ]
}

@test "isolated template and export round-trip only profile-local state and preserve isolation" {
  run multicli new fixture/iso-a --isolated --no-seed
  [ "$status" -eq 0 ]
  local source="$MULTICLI_HOME/fixture/iso-a"
  printf 'isolated-config\n' > "$source/config.toml"
  mkdir -p "$source/agents"
  printf 'isolated-agent\n' > "$source/agents/reviewer.md"
  mkdir -p "$SHARED_ROOT"
  printf 'native-must-not-travel\n' > "$SHARED_ROOT/config.toml"

  run multicli template save fixture/iso-a isotpl
  [ "$status" -eq 0 ]
  [ "$(cat "$TEMPLATES_ROOT/isotpl/config.toml" | tr -d '\r')" = 'isolated-config' ]

  run multicli new fixture/iso-b --isolated --from isotpl
  [ "$status" -eq 0 ]
  [ "$(cat "$MULTICLI_HOME/fixture/iso-b/config.toml" | tr -d '\r')" = 'isolated-config' ]
  [ "$(cat "$SHARED_ROOT/config.toml" | tr -d '\r')" = 'native-must-not-travel' ]

  local archive="$MULTICLI_SCRATCH/isolated.tar.gz"
  run multicli export fixture/iso-a "$archive"
  [ "$status" -eq 0 ]
  run multicli import "$archive" fixture/iso-imported
  [ "$status" -eq 0 ]
  [ -f "$MULTICLI_HOME/fixture/iso-imported/.isolated" ]
  [ "$(jq -r '.mode' "$MULTICLI_HOME/fixture/iso-imported/.profile.json")" = isolated ]
  [ "$(cat "$MULTICLI_HOME/fixture/iso-imported/config.toml" | tr -d '\r')" = 'isolated-config' ]
  [ "$(cat "$SHARED_ROOT/config.toml" | tr -d '\r')" = 'native-must-not-travel' ]
}

@test "tampered templates with credentials or undeclared files are refused before profile creation" {
  seed_transfer_shared_root
  make_overlay_profile account-a
  run multicli template save fixture/account-a tpl
  [ "$status" -eq 0 ]
  mkdir -p "$TEMPLATES_ROOT/tpl/auth"
  printf '{"token":"sk-injected"}\n' > "$TEMPLATES_ROOT/tpl/auth/auth.json"

  run multicli new fixture/credential-victim --from tpl
  [ "$status" -eq 1 ]
  [[ "$output" == *"forbidden path 'auth'"* || "$output" == *"forbidden path 'auth/auth.json'"* ]]
  [ ! -e "$MULTICLI_HOME/fixture/credential-victim" ]

  rm -rf "$TEMPLATES_ROOT/tpl/auth"
  printf 'undeclared\n' > "$TEMPLATES_ROOT/tpl/random.txt"
  run multicli new fixture/undeclared-victim --from tpl
  [ "$status" -eq 1 ]
  [[ "$output" == *"undeclared path 'random.txt'"* ]]
  [ ! -e "$MULTICLI_HOME/fixture/undeclared-victim" ]
}
