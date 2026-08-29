<p align="center">
  <img src="assets/banner.svg" alt="Nini Agents. Use multiple accounts simultaneously without switching." width="760"/>
</p>

<p align="center">Use multiple accounts simultaneously without switching.</p>

> [!IMPORTANT]
> Nini Agents is currently evolving from the Multi-CLI `6efb0d2` engine base.
> Cross-machine movement for filesystem-credential profiles is public on the
> Bash launcher (Linux verified; macOS transport implemented but not yet
> exercised here). Windows PowerShell still rejects SSH transport, but supports
> portable offline `move-export`/`move-import` ZIPs. Read-only queries, profile
> `new`/`rename`/`delete`, and Bash `move` use the stable JSON v1 envelope.

<p align="center">
  <a href="#supported-ai-tools"><img src="https://img.shields.io/badge/support-17%20AI%20tools-255C60?style=flat-square&labelColor=14101F" alt="17 supported AI tools"/></a>
  <a href="release/VERSION"><img src="https://img.shields.io/badge/version-v1.0.0-255C60?style=flat-square&labelColor=14101F" alt="Version v1.0.0"/></a>
  <a href="#install"><img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-255C60?style=flat-square&labelColor=14101F" alt="macOS, Linux, and Windows"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-255C60?style=flat-square&labelColor=14101F" alt="License MIT"/></a>
</p>

<p align="center">
  <a href="README.md"><b>English</b></a> |
  <a href="docs/translations/es.md">Español</a> |
  <a href="docs/translations/ar.md">العربية</a> |
  <a href="docs/translations/zh.md">中文</a> |
  <a href="docs/translations/ru.md">Русский</a> |
  <a href="docs/translations/he.md">עברית</a>
</p>

## Contents

[Install](#install) · [Quick start](#quick-start) · [AI tools](#supported-ai-tools) · [Commands](#commands) · [Isolation](#how-isolation-works) · [Move sessions](#move-sessions-between-accounts) · [Troubleshooting](#troubleshooting) · [Uninstall](#uninstall)

## Install

### Requirements

- macOS or Linux: [Bash 3.2 or newer](https://www.gnu.org/software/bash/)
- Windows: [Windows PowerShell 5.1](https://www.microsoft.com/download/details.aspx?id=54616)
- [jq 1.7.1](https://jqlang.github.io/jq/download/), installed automatically when missing
- One of the [supported AI tools](#supported-ai-tools)
- Cross-device movement additionally requires SSH, rsync, and the same Nini
  Agents adapter version on each device
- Portable move ZIPs additionally require `zip`, `unzip`, `base64`, and `dd` on
  macOS/Linux; Windows uses the built-in .NET ZIP implementation

### Install from source

[Git](https://git-scm.com/downloads) is required for this method.

```bash
git clone https://github.com/LuchoNoPrograma/nini-agents.git
cd nini-agents
./install/install.sh --local
```

Windows PowerShell:

```powershell
git clone https://github.com/LuchoNoPrograma/nini-agents.git
cd nini-agents
.\install\install.ps1 -Local
```

## Quick start

```bash
nini-agents doctor
nini-agents new claude-cli/work
nini-agents claude-cli/work
```

## Supported AI tools

| AI tool | ID | Platforms | Account boundary |
|---|---|---|---|
| [AGY CLI](docs/adapters/agy-cli.md) | `agy-cli` | Windows | OS user |
| [Antigravity](docs/adapters/antigravity.md) | `antigravity` | Windows | OS user |
| [Claude Code](docs/adapters/claude-cli.md) | `claude-cli` | Windows, Linux, macOS API keys | File overlay |
| [Codex CLI](docs/adapters/codex.md) | `codex` | Windows, macOS, Linux | File overlay |
| [Codex Desktop](docs/adapters/codex-gui.md) | `codex-gui` | Windows | OS user |
| [Command Code](docs/adapters/commandcode.md) | `commandcode` | Windows, macOS, Linux | File overlay |
| [GitHub Copilot CLI](docs/adapters/copilot-cli.md) | `copilot-cli` | Windows, macOS, Linux | Process secret |
| [GitHub Copilot in VS Code](docs/adapters/copilot-vscode.md) | `copilot-vscode` | Windows | OS user |
| [Cursor CLI](docs/adapters/cursor-cli.md) | `cursor-cli` | Windows, macOS, Linux | Process secret |
| [Cursor Desktop](docs/adapters/cursor.md) | `cursor` | Windows, macOS, Linux | Isolated tool home |
| [Gemini CLI](docs/adapters/gemini-cli.md) | `gemini-cli` | Windows, macOS, Linux | File overlay |
| [Grok Build CLI](docs/adapters/grok-cli.md) | `grok-cli` | Windows, macOS, Linux | Process secret |
| [Kimi Code CLI](docs/adapters/kimi-cli.md) | `kimi-cli` | Windows, macOS, Linux | Process secret |
| [Kiro](docs/adapters/kiro.md) | `kiro` | Windows, macOS, Linux | OS user |
| [OpenCode](docs/adapters/opencode.md) | `opencode` | Windows, macOS, Linux | Isolated tool home |
| [Windsurf](docs/adapters/windsurf.md) | `windsurf` | Windows, macOS, Linux | OS user |
| [Zed](docs/adapters/zed.md) | `zed` | Windows | OS user |

See platform limits in the [support matrix](docs/support-matrix.md). Run `nini-agents tools` to check your machine.

## Commands

### Profiles

| Command | Action |
|---|---|
| `nini-agents new <tool>/<name>` | Create an account profile (credentials separate; normal state shared) |
| `nini-agents new <tool>/<name> --isolated` | Create a whole-root isolated profile when the AI tool supports it; aliases: `--isolate`, `-i` |
| `nini-agents new <tool>/<name> --from <template>` | Create a schema-v2 profile from a schema-v2 template |
| `nini-agents <tool>/<name>` | Launch a profile |
| `nini-agents launch <tool>/<name> [-- args...]` | Launch and pass arguments to the tool |
| `nini-agents exec <tool>/<name> [-- args...]` | Run a foreground file-overlay profile with machine-clean stdio |
| `nini-agents list [<tool>]` | List profiles |
| `nini-agents clone <tool>/<src> <tool>/<dest>` | Copy a schema-v2 profile |
| `nini-agents rename <tool>/<old> <tool>/<new>` | Rename a profile |
| `nini-agents delete <tool>/<name>` | Delete a profile after confirmation |

### Credentials and portability

| Command | Action |
|---|---|
| `nini-agents auth set <tool>/<profile>` | Store a process secret in the OS credential store |
| `nini-agents auth status <tool>/<profile>` | Check whether that secret exists |
| `nini-agents auth clear <tool>/<profile>` | Remove that secret |
| `nini-agents permissions show` | Show the shared Codex permission default |
| `nini-agents permissions set <read-only\|workspace\|full-access>` | Save the shared Codex permission default for new sessions |
| `nini-agents continue <tool> <src> <dest> [--dry-run] [--no-merge]` | Copy supported session state, never credentials |
| `nini-agents template save <tool>/<profile> <name>` | Save a credential-free schema-v2 template |
| `nini-agents template list \| delete <name>` | List or delete templates |
| `nini-agents export <tool>/<name> [path]` | Export a schema-v2 profile |
| `nini-agents import <archive> <tool>/<name>` | Import a schema-v2 archive |
| `nini-agents move-export <tool>/<name> [package.zip]` | Create an unencrypted portable ZIP with credentials, chats, and adapter-declared global state; deactivate the source after verification |
| `nini-agents move-import <package.zip> <tool>/<name>` | Verify and install a portable move ZIP on Linux, macOS, or Windows |
| `nini-agents move <tool>/<name> <device> [--dry-run] [--discard-source-backup] [--devices-config <path>]` | Move a legacy or schema-v2 filesystem-credential profile to one configured device |
| `nini-agents devices list [tool]` | List active local profiles through the device registry |
| `nini-agents devices status <tool>/<name>` | Show active/absent/inaccessible state on every configured device |
| `nini-agents devices doctor [tool]` | Verify the SSH movement boundary |

### Maintenance

| Command | Action |
|---|---|
| `nini-agents migrate <tool>/<name> [--dry-run] [--prefer-profile] [--preserve-unknown]` | Migrate a legacy profile to schema v2 |
| `nini-agents status` | Show profiles and sizes |
| `nini-agents stats` | Show profile storage use |
| `nini-agents doctor [--deep]` | Diagnose setup and optionally audit runtimes |
| `nini-agents completion {bash\|zsh\|powershell}` | Print shell completion setup |
| `nini-agents help` | Show every command |
| `nini-agents version` | Show the installed version |

Add `--json` to `version`, `list/status`, `tools`, `doctor`, `stats`,
`template list`, `new`, `rename`, `delete`, or Bash `move` for the stable
consumer interface. These mutations keep the same profile and adapter rules as
their human forms while reporting machine-safe mutation states. JSON deletion
is noninteractive and requires the exact target twice:

```bash
nini-agents --json delete codex/work --confirm codex/work
```

See the [JSON CLI contract](docs/json-cli.md). Other mutation commands reject
JSON mode before doing work.

`exec` is a raw process transport rather than a JSON-envelope command. It emits
no launcher notice on stdout, inherits the child's stdin/stdout/stderr, applies
the same profile overlay and enforced adapter arguments as `launch`, and
propagates the child exit code. Its supported boundary is deliberately limited
to foreground `accountOverlay/fileOverlay` profiles, including legacy
whole-root profiles. This is the integration surface for consumers such as
`codex app-server --stdio`; see the [exec contract](docs/exec-contract.md).

### Move profiles between devices

Create a private devices file. New configurations should use a profile home:

```text
this_device|mint
profiles_home|/home/you/MultiCliProfiles
device|ubuntu|ubuntu|/home/you/MultiCliProfiles
```

The third `device` field is an SSH host or alias. Codexporter's historical
`profiles_root|.../codex` format remains accepted for its migration.

```bash
nini-agents devices doctor codex --devices-config ~/.config/nini-agents/devices.conf
nini-agents devices status codex/work --devices-config ~/.config/nini-agents/devices.conf
nini-agents move codex/work ubuntu --dry-run --devices-config ~/.config/nini-agents/devices.conf
nini-agents move codex/work ubuntu --discard-source-backup --devices-config ~/.config/nini-agents/devices.conf
nini-agents --json move codex/work ubuntu --devices-config ~/.config/nini-agents/devices.conf
```

Nini Agents proves one active owner, rejects active or inconclusive processes,
copies into operation-specific staging, compares structure/size/SHA-256,
revalidates under locks on both devices, then activates the destination. The
source remains under `.inactive/`; older backups are never pruned automatically.
Failed activated candidates are quarantined under `.failed/` before rollback.
Schema-v2 `.runtime/` is excluded and rebuilt at the destination. See the
[movement protocol](docs/move-protocol.md).

`--discard-source-backup` keeps the operation-owned backup through destination
activation, runtime reconstruction, and the final integrity comparison, then
deletes only that backup. It never prunes earlier backups. If cleanup fails,
the command reports `backup_cleanup_failed` with the destination still active.

Only adapter-declared profile content is movable. Unknown files, arbitrary
links, unexpected hardlinks, malformed metadata, and malformed credential JSON
fail closed before ownership changes. Expected shared-state links and exact
link residue recorded by an older completed migration are never followed: the
link objects are omitted from destination staging, while the original objects
remain in the source backup until any requested backup discard succeeds.

### Portable offline move ZIPs

Use the separate offline movement commands when SSH is unavailable or the
destination is Windows:

```bash
nini-agents move-export codex/work ./codex-work-move.zip
# Copy the ZIP by USB, file share, SCP, etc.
nini-agents move-import ./codex-work-move.zip codex/work
```

The ZIP contract is intentionally different from normal `export`/`import`.
Normal exports remain credential- and session-free. A move ZIP includes the
validated profile credentials plus adapter-declared `sharedPaths` and
`sessionPaths`; for Codex this includes shared chats and global `skills` (as
well as the other paths declared by the Codex adapter).

The archive is **not encrypted** and must be protected like a password. It has
one fixed NDJSON payload whose file records carry size and SHA-256 integrity;
import reconstructs only validated relative regular files in private staging.
Existing destination state is merged only when missing or byte-identical. Any
different file is a conflict and aborts before profile activation.

After a successful export, the active source profile moves to
`.inactive/<name>.<package-id>` and the verified ZIP is kept. Shared global
state is not deleted because other local profiles may still use it. After a
successful import, the ZIP is also retained as a recovery copy. Offline media
cannot enforce a single destination if the same ZIP is replayed, so delete or
secure every extra copy once ownership is confirmed. Windows implementation is
present but was not executed in this Linux checkout.

### Shared Codex permissions

Standard account-overlay Codex profiles share `config.toml`, so one command
sets the default across those Nini Agents-managed accounts:

```bash
nini-agents permissions show
nini-agents permissions set read-only
nini-agents permissions set workspace
nini-agents permissions set full-access
```

The presets write Codex's built-in `:read-only`, `:workspace`, or
`:danger-full-access` permission profile together with an approval policy of
`on-request`, `on-request`, or `never`, respectively. `set` removes legacy
top-level sandbox settings that would override the profile, validates a staged
copy with the installed Codex CLI, and then replaces `config.toml` atomically;
it does not read or modify `auth.json`.

The saved default applies to new Codex sessions. A permission selected inside
an already-running session remains session-local; restart that session to load
the new shared default. See Codex's official
[permissions](https://learn.chatgpt.com/docs/permissions) and
[configuration](https://learn.chatgpt.com/docs/config-file/config-reference)
documentation.

## How isolation works

| Mode | What stays separate | What stays shared |
|---|---|---|
| File overlay | Declared credential files | Native configuration and conversations |
| Process secret | One credential injected into the child process | The tool's normal state |
| OS user | The product's fixed OS credential identity | Nothing unless the AI tool allows it |
| Isolated tool home | The entire tool home | Nothing |

Profiles use the narrowest supported boundary. `--isolated` creates a separate tool home. Fixed OS credentials use a Nini Agents-owned OS user and require an elevated terminal on Windows.

AI tools using a process secret require one extra step:

```bash
nini-agents new cursor-cli/work
nini-agents auth set cursor-cli/work
nini-agents cursor-cli/work
```

Older profiles keep their original whole-root behavior. Preview migration with:

```bash
nini-agents migrate codex/work --dry-run
```

Migration fails closed when a legacy profile contains paths its adapter does
not declare. After reviewing the dry-run refusal, `--preserve-unknown` can be
used explicitly to rename those objects into
`.inactive/migrations/<tool>/<profile>/unknown-state/` under the profile store.
They are not read, merged, deleted, or activated in the schema-v2 runtime, and
automatic rollback returns them to the legacy profile. Overlapping or
adapter-declared unsafe paths remain hard failures. Use the flag only with a
reviewed profile and preview the resulting preservation operations with
`--dry-run` first.

Adapters may also declare exact `normalState.migrationPreservePaths` for
transactional or volatile normal state that must remain usable in schema v2
but cannot be safely combined with an unrelated live state family during a
legacy migration. Existing objects at those paths are renamed into
`.inactive/migrations/<tool>/<profile>/profile-state/`; they are not merged or
activated automatically, and rollback returns them to the legacy profile.

Adapters that need a deliberately small migration may declare
`normalState.migrationActivatePaths`. Only that exact shared/session subset is
merged into the live root; all other declared shared/session objects are moved
whole into the same inactive `profile-state/` recovery area. This avoids
walking large histories while retaining them for manual recovery. Adapters
without the field keep the previous all-declared-state behavior.

Legacy links selected for ordinary shared/session activation are moved as
opaque objects into
`.inactive/migrations/<tool>/<profile>/linked-state/`. Migration never reads or
follows their targets, the active schema-v2 profile contains no such links,
and automatic rollback restores them if the transaction fails. With a
`migrationActivatePaths` allowlist, non-selected objects—including links—are
instead preserved whole under `profile-state/` before merge planning.

Only schema-v2 profiles, templates, and archives are portable. Migrate legacy profiles first.

## Move sessions between accounts

Copy supported conversation state when one account reaches a limit:

```bash
nini-agents continue codex work personal --dry-run
nini-agents continue codex work personal
nini-agents codex/personal
codex resume
```

`base` refers to the tool's normal home, so either side can be a profile or the default installation. Credentials are never copied. Session transfer is supported for `codex`, `claude-cli`, `gemini-cli`, and `commandcode`.

## Shell aliases

Each profile gets a shortcut such as `claude-cli-work`.

| Platform | Location |
|---|---|
| macOS and Linux | `~/MultiCliProfiles/bin/` |
| Windows | `~/MultiCliProfiles/bin/`, plus Start Menu shortcuts for GUI profiles |

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `MULTICLI_HOME` | `~/MultiCliProfiles` | Profile storage |
| `MULTICLI_OVERRIDE_BINARY` | unset | Override binary discovery for one launch |
| `NINI_AGENTS_REPO` | Nini Agents GitHub repository | Override the install source |
| `NINI_AGENTS_INSTALL_DIR` | platform default | Override the installation directory |
| `NINI_AGENTS_BIN_LINK` | `~/.local/bin/nini-agents` | Override the primary POSIX launcher |
| `NINI_AGENTS_BIN_DIR` | platform default | Override the Windows command directory |

`MULTICLI_REPO`, `MULTICLI_INSTALL_DIR`, `MULTICLI_BIN_LINK`, and
`MULTICLI_BIN_DIR` remain temporary installer compatibility variables.
`MULTICLI_HOME`, `MULTICLI_OVERRIDE_BINARY`, `MULTICLI_PROFILE_ID`, the
`~/MultiCliProfiles` layout, and existing credential-store targets remain
unchanged so current profiles do not require migration or authentication.

## Temporary command compatibility

`nini-agents` is the canonical command. `multi-cli` is a thin compatibility
shim that delegates to the same engine for existing aliases and consumers.
It contains no profile or credential logic and will remain available until the
coordinated MultiCLI AI and Codexporter migration is complete.

## Troubleshooting

```bash
nini-agents doctor
nini-agents doctor --deep
nini-agents tools
```

Restart the terminal if `nini-agents` or a new profile alias is not found after installation. The [support matrix](docs/support-matrix.md) covers product-specific requirements.

## Uninstall

macOS and Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/LuchoNoPrograma/nini-agents/main/install/uninstall.sh | bash
```

Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/LuchoNoPrograma/nini-agents/main/install/uninstall.ps1 | iex
```

Profile data is preserved unless you confirm its removal.

## Links

- [Support matrix](docs/support-matrix.md)
- [JSON CLI contract](docs/json-cli.md)
- [Security policy](docs/SECURITY.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Support](docs/SUPPORT.md)

## License

[MIT](LICENSE). See [NOTICE](NOTICE) for the Multi-CLI fork attribution and
fixed upstream baseline.
