# codex: OpenAI Codex CLI

**Account boundary:** `fileOverlay`: `auth.json` is profile-local; MCP OAuth is
one engine-owned shared credential group; configuration and sessions are
shared normal state.

Codex honors `CODEX_HOME`. The adapter points it at a per-profile runtime view
where `auth.json` belongs to the profile. Ordinary declared paths link back to
the native shared root, MCP OAuth links to one store below `MULTICLI_HOME`, and
the SQLite database family is accessed directly through an enforced
`sqlite_home` configuration.

Codex persists `auth.json` with an atomic replacement. After a foreground
launch exits, Nini Agents promotes that replacement back into the profile's
`auth/auth.json` and recreates the managed runtime link. A successful deletion
is persisted as a profile logout. The same recovery runs before rebuilding a
warm overlay, which covers a prior process-replacing `nini-agents exec` launch.
Unexpected links, directories, or hardlinks fail closed without overwriting the
profile credential.

## Install

```bash
npm i -g @openai/codex
```

Binary discovery: `%APPDATA%\npm\codex.cmd` (Windows); `/usr/local/bin/codex`, `$HOME/.npm-global/bin/codex`, or `$HOME/.local/bin/codex` (macOS); `$HOME/.npm-global/bin/codex`, `/usr/local/bin/codex`, or `$HOME/.local/bin/codex` (Linux); then `codex` on PATH.

## Quickstart

```bash
nini-agents new codex/work
nini-agents launch codex/work        # sign in on first run; auth.json stays profile-local
nini-agents new codex/personal
nini-agents launch codex/personal
```

Conversations are shared normal state, so `nini-agents continue` is not needed between schema-v2 profiles (it remains available for legacy profiles).

## Shared permission defaults

Standard account-overlay Codex profiles use the same shared `config.toml`.
Manage its default permission profile without editing every account separately:

```bash
nini-agents permissions show
nini-agents permissions set read-only
nini-agents permissions set workspace
nini-agents permissions set full-access
```

| Nini preset | Codex permission profile | Approval policy |
|---|---|---|
| `read-only` | `:read-only` | `on-request` |
| `workspace` | `:workspace` | `on-request` |
| `full-access` | `:danger-full-access` | `never` |

`set` preserves unrelated configuration and comments, removes legacy
top-level `sandbox_mode` and `[sandbox_workspace_write]` settings that would
override permission profiles, validates a staged copy with
`codex --strict-config --version`, and atomically replaces the shared file.
On POSIX the resulting file is private (`0600`). The command does not inspect
or change primary or MCP credentials.

The new value is a default for new sessions. Codex's `/permissions` control is
session-level, so an already-running process keeps its current choice until it
is restarted. Whole-root profiles created with `--isolated` keep their own
configuration and are outside this shared default. See the official Codex
[permissions](https://learn.chatgpt.com/docs/permissions) and
[configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

Launching `codex/work` and `codex/personal` at the same time therefore gives
each process its own `auth.json`, while both processes use the same MCP OAuth
file and the same MCP refresh-lock directory. Signing into an MCP server from
one Nini Agents-managed Codex profile makes that MCP authorization available to
the other profiles; it does not change their primary Codex accounts.

## Account boundary

- Profile-local credentials: `auth.json` (sole primary account credential).
- Launch env: `CODEX_HOME={runtimeRoot}`.
- Account-overlay launch clears inherited `CODEX_SQLITE_HOME` and appends
  enforced `cli_auth_credentials_store="file"`,
  `mcp_oauth_credentials_store="file"`, and
  `sqlite_home="{sharedStateRoot}"` settings after user options and before a
  literal `--`. Main auth and MCP OAuth therefore use their declared file
  boundaries, while live SQLite files are not linked into the reconstructible
  runtime.
- Logout scope: profile.
- Login/logout writes are reconciled only for the adapter-declared
  profile-local credential path. Nini Agents does not parse or print the
  credential value during reconciliation.

## Shared MCP OAuth credential state

Backing root: `MULTICLI_HOME/.shared/codex/mcp`.

- `.credentials.json`: initialized as an empty JSON object only when absent.
- `mcp-oauth-locks/`: shared with the credential file so Codex can serialize
  refresh/persist operations across simultaneous profiles.
- Both paths are linked into every schema-v2 Codex runtime. The runtime never
  copies them as a fallback and never reads an existing credential value.
- Templates, exports, imports, clones, and profile moves do not transport this
  store. It belongs to the local Nini Agents installation, not to one profile.

During legacy migration, existing entries with these names, plus dot-suffix
backup siblings such as `.credentials.json.before-*` and
`mcp-oauth-locks.before-*`, are not selected as
the active shared store. Their file, directory, or link objects are preserved
inactive below `.inactive/migrations/codex/<profile>/shared-credentials/` by
same-volume rename. The target of a legacy link is neither followed nor shown.
The active shared store remains absent until the first schema-v2 launch, so the
migration itself cannot trigger MCP login, logout, refresh, or revocation.

## Shared normal state

Shared root: `%USERPROFILE%\.codex` (Windows), `~/.codex` (macOS/Linux).

- Config and global guidance: `config.toml`, `hooks.json`, `AGENTS.md`,
  `AGENTS.override.md`,
  `installation_id`, `skills/`, `agents/`, `prompts/`, `mcp-configs/`,
  `plugins/`, `rules/`.
- Logs: `log/`.
- Sessions: `sessions/`, `history.jsonl`, `archived_sessions/`,
  `shell_snapshots/`, `thread-writer-locks/`, and `session_index.jsonl`.
- Direct SQLite session state: the exact `goals_1`, `logs_2`, `memories_1`,
  `queue_1`, `state_5`, and `thread_history_1` `.sqlite` files and their
  `-shm`/`-wal` sidecars. These names were characterized with a synthetic home
  using the locally installed Codex 0.147.0; a future unknown database name
  remains fail-closed instead of being captured by a broad pattern.

Credential-free templates and normal exports continue to exclude sessions.
The explicit `move-export` offline ZIP instead snapshots all of the declared
shared and session paths above after proving Codex is stopped. That includes
global skills and conversations, but not the separate shared MCP OAuth store.
`move-import` installs missing state, accepts byte-identical existing files,
and rejects any differing file rather than merging SQLite or text content.

## Selective legacy migration

Codex migration activates only the compact state selected by
`normalState.migrationActivatePaths`: `config.toml`, `hooks.json`,
`AGENTS.md`, `AGENTS.override.md`, `skills/`, `agents/`, `prompts/`,
`mcp-configs/`, `plugins/`, and `rules/`. The main `auth.json` remains governed
by the credential transaction and moves to the profile-local `auth/` tree.

`config.toml` is the primary MCP server configuration, so those definitions
are retained. Legacy MCP OAuth objects (`.credentials.json` and
`mcp-oauth-locks/`) remain inactive by design; migration never imports or
activates them, and the first MCP use can require authentication again.

Current Codex also discovers user skills under `$HOME/.agents/skills`, which
is already outside the legacy `CODEX_HOME` profile and is therefore not moved.
The adapter still activates a legacy profile's `skills/` directory for
compatibility with Codex versions and installations that use
`$CODEX_HOME/skills`.

All other declared ordinary state is preserved whole under
`.inactive/migrations/codex/<profile>/profile-state/`: `installation_id`,
`log/`, conversations, history, archived sessions, shell snapshots, session
index, writer locks, and the declared SQLite families. A large `sessions/`
tree therefore produces one journaled rename instead of one merge operation
per contained file. It remains available for recovery but is not activated in
the new profile.

## Legacy transactional state

Schema-v2 Codex still uses the shared `sqlite_home` and declares
`thread-writer-locks/` as session state. Migration applies a narrower rule to
their legacy instances: `thread-writer-locks/` and every exact `.sqlite`,
`-shm`, and `-wal` member listed above are
`normalState.migrationPreservePaths`. Existing objects are renamed whole under
`.inactive/migrations/codex/<profile>/profile-state/`; they are not compared,
deduplicated, merged into `~/.codex`, or activated automatically.

This prevents a database from one legacy profile being combined with sidecars
or writer locks belonging to another database already active in the shared
root. The broader selective migration policy now preserves sessions, history,
snapshots, logs, and installation identity in the same recovery area as well;
configuration, plugins, and skills are activated. A failed apply returns all
preserved objects to the legacy profile through the migration journal and
rollback.

## Reconstructible runtime state

Codex 0.147.0 identifies `.sandbox_migration`, `cache/`, `models_cache.json`,
and `version.json` as tool-managed cache or migration state. These exact paths
are allowed only inside the per-profile runtime. Nini Agents does not link or
pre-create them: empty `models_cache.json` and `version.json` files are not
valid upstream state, so Codex must write their complete formats itself.

If these objects exist in a legacy profile, migration preserves them inactive
under `.inactive/migrations/codex/<profile>/runtime-state/` using journaled
same-volume renames and rollback. They do not travel through templates,
export, import, clone, or profile move.

## Known limitations

- Requires file-based credential storage (`auth.json`); OS-keychain credential modes are outside this account boundary.
- The first MCP use after migration may require one MCP reauthentication for
  the new shared store. That is intentionally separate from the existing
  profile-local `auth.json` and is not performed by `nini-agents migrate`.
- Inactive legacy MCP recovery artifacts are retained deliberately. Nini Agents
  does not delete them automatically; cleanup needs a later explicit decision.
- Inactive legacy SQLite families and writer locks are also retained
  deliberately. Nini Agents does not open or recover those databases and does
  not select one profile's database as the active shared store automatically.
- Six observed local paths remain deliberately unclassified:
  `.personality_migration`, `.tmp`, `tmp`, two local `config.toml.bak-*`
  objects, and `gpt-5.5-no-intermediary-updates.md`. A legacy profile that
  contains any of them still fails closed by default. After reviewing the
  exact dry-run refusal, an operator may add `--preserve-unknown`; the objects
  are then renamed whole under
  `.inactive/migrations/codex/<profile>/unknown-state/`, remain outside the
  active runtime, and participate in journaled rollback. The option does not
  claim those paths are Codex state and never overrides overlap or unsafe-path
  failures.
- The SQLite routing is backed by Codex's documented `sqlite_home` setting.
  Codex documents `auth.json` and MCP OAuth as separate credential stores. The
  `.credentials.json` and `mcp-oauth-locks/` filenames and the serialized
  file-store behavior were characterized locally with Codex 0.147.0 using
  synthetic homes; they are not claimed as a portable cross-machine profile
  boundary. See the official [authentication documentation](https://learn.chatgpt.com/docs/auth)
  and [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
- Codex rules remain subject to upstream changes. Nini Agents shares the user-level `rules/` directory as ordinary configuration; it never treats rules as credentials or session state.
- Concurrent profiles write to the shared session store; keep simultaneous writers in mind.
- Bash behavior is executed on Linux. Equivalent Windows PowerShell code and
  tests, including portable move ZIP support, are present, but Windows
  hardlink/junction behavior and macOS have not been executed in the current
  environment. SSH movement remains Bash-only.

## Support

| Windows | macOS | Linux |
|---|---|---|
| supported (file overlay; file credential store mode) | supported | supported |
