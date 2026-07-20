**English** | [Español](README.es.md) | [العربية](README.ar.md) | [中文](README.zh.md) | [Русский](README.ru.md) | [עברית](README.he.md)

# multi-cli

**Run multiple account profiles for AI coding tools simultaneously.**

A schema-v2 profile isolates the account credential and quota identity while sharing the tool's normal state — conversations, configuration, agents, skills, and plugins — where the vendor exposes a safe boundary. Products that combine auth with sessions or fixed keychain state are marked experimental or unsupported instead of being given a false isolation claim. No adapter has passed the verified dual-account gate yet; see [the support matrix](docs/support-matrix.md) for the exact product, platform, and auth-mode status.

Existing schema-v1 profiles remain legacy whole-root profiles until migrated — see [Legacy Profiles](#legacy-profiles).

[![GitHub repository](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/Spielewoy/multi-codex)
[![GitHub profile](https://img.shields.io/badge/GitHub-Spielewoy-lightgrey?logo=github)](https://github.com/Spielewoy)
[![GitHub stars](https://img.shields.io/github/stars/Spielewoy/multi-codex?style=social)](https://github.com/Spielewoy/multi-codex/stargazers)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)](#install)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)

---

## Supported Tools

17 adapters ship in this repository. Status is per operating system: `experimental` means a documented candidate boundary exists but full dual-account verification has not passed, and `unsupported` means multi-cli refuses to claim account isolation. Nothing is verified yet. The authoritative source is [docs/support-matrix.md](docs/support-matrix.md).

| Tool | Kind | Windows | macOS | Linux |
|------|------|---------|-------|-------|
| [Claude Code](claude-cli/) | CLI | experimental | unsupported (stored OAuth) | experimental |
| [OpenAI Codex CLI](codex/) | CLI | experimental | experimental | experimental |
| [Gemini CLI](gemini-cli/) | CLI | experimental | experimental | experimental |
| [OpenCode](opencode/) | CLI | unsupported | unsupported | unsupported |
| [Command Code](commandcode/) | CLI | unsupported | unsupported | unsupported |
| [Cursor Desktop](cursor/) | IDE | unsupported | unsupported | unsupported |
| [Cursor CLI](cursor-cli/) | CLI | experimental | experimental | experimental |
| [Antigravity](antigravity/) | IDE | experimental | unsupported | unsupported |
| [AGY CLI](agy-cli/) | CLI | experimental | unsupported | unsupported |
| [Kiro](kiro/) | IDE | experimental | unsupported | unsupported |
| [Zed](zed/) | IDE | unsupported | unsupported | experimental |
| [Devin Desktop / Windsurf](windsurf/) | IDE | experimental | unsupported | unsupported |
| [GitHub Copilot CLI](copilot-cli/) | CLI | experimental | experimental | experimental |
| [Copilot in VS Code](copilot-vscode/) | IDE | experimental | unsupported | unsupported |
| [Kimi Code CLI](kimi-cli/) | CLI | experimental | experimental | experimental |
| [Codex Windows App](codex-gui/) | IDE | unsupported | unsupported | unsupported |
| [Grok Build CLI](grok-cli/) | CLI/TUI | experimental | experimental | experimental |

Each tool has its own folder at the repo root with an `adapter.json` describing the account boundary, the shared normal state, and the evidence required for promotion to verified.

---

## Install

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/install.sh | bash
```

**Windows** — open PowerShell:

```powershell
irm https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/install.ps1 | iex
```

> After install, **restart your terminal** for PATH changes to take effect.

### From source

```bash
git clone https://github.com/Spielewoy/multi-codex.git
cd multi-codex
./scripts/install.sh --local        # macOS/Linux
.\scripts\install.ps1 -Local        # Windows
```

> After install, **restart your terminal** for PATH changes to take effect.

> [jq](https://jqlang.github.io/jq/) is **installed automatically** by the installer on all platforms — no manual setup required.

---

## Quick Start

```bash
# Create a profile
multi-cli new claude-cli/work

# Launch it
multi-cli launch claude-cli/work

# Or use the shorthand
multi-cli claude-cli/work
```

Each profile gets an automatic shell alias:

| Platform | Location |
|----------|----------|
| macOS / Linux | `~/MultiCliProfiles/bin/` (add to `PATH`) |
| Windows | Start Menu shortcuts created automatically |

---

## Commands

### Profile Management

| Command | Description |
|---------|-------------|
| `multi-cli new <tool>/<name>` | Create a new isolated profile |
| `multi-cli new <tool>/<name> --shared` | Lightweight profile (shared settings, isolated auth) |
| `multi-cli new <tool>/<name> --from <tpl>` | Create from a saved template |
| `multi-cli <tool>/<name>` | Launch a profile (shorthand) |
| `multi-cli launch <tool>/<name>` | Launch a profile |
| `multi-cli list [<tool>]` | List all profiles |
| `multi-cli status` | Show running state, type, last used, and size |
| `multi-cli clone <tool>/<src> <tool>/<dest>` | Copy an existing profile |
| `multi-cli rename <tool>/<old> <tool>/<new>` | Rename a profile |
| `multi-cli delete <tool>/<name>` | Delete a profile and all its data |

### Account Authentication & Migration

| Command | Description |
|---------|-------------|
| `multi-cli auth set <tool>/<profile>` | Store the profile's process-secret credential in the OS credential store (prompts interactively, or reads one line from stdin) |
| `multi-cli auth status <tool>/<profile>` | Report whether a credential is stored for the profile |
| `multi-cli auth clear <tool>/<profile>` | Remove the stored credential |
| `multi-cli migrate <tool>/<name> [--dry-run] [--prefer-profile]` | Migrate a legacy schema-v1 profile to schema-v2 |

`auth` applies only to adapters that use the `processSecret` mechanism (`cursor-cli`, `copilot-cli`, `kimi-cli`, `grok-cli`). Launch stays disabled until a credential is stored. See [Legacy Profiles](#legacy-profiles) for `migrate`.

### Templates

| Command | Description |
|---------|-------------|
| `multi-cli template save <tool>/<profile> <name>` | Save a profile as a reusable template |
| `multi-cli template list` | List saved templates |
| `multi-cli template delete <name>` | Remove a template |

### Backup & Transfer

| Command | Description |
|---------|-------------|
| `multi-cli export <tool>/<name> [path]` | Archive a profile to `.tar.gz` (`.zip` on Windows) |
| `multi-cli import <archive> <tool>/<name>` | Restore a profile from an archive |

### Sessions

| Command | Description |
|---------|-------------|
| `multi-cli continue <tool> <src> <dest>` | Copy conversation state (sessions/transcripts/history) from one profile to another — never credentials |
| `multi-cli continue <tool> <src> <dest> --no-merge` | Overwrite destination files instead of keeping newer ones |
| `multi-cli continue <tool> <src> <dest> --dry-run` | Preview what would be copied, change nothing |

`base` works as a profile name on either end and means the tool's real home dir (`~/.codex`, `~/.claude`, …). Supported for `codex`, `claude-cli`, `gemini-cli`, and `commandcode`. See [Continue a Chat Across Accounts](#continue-a-chat-across-accounts).

### Utilities

| Command | Description |
|---------|-------------|
| `multi-cli tools` | List all supported tools and their install status |
| `multi-cli stats` | Show disk usage per profile |
| `multi-cli doctor` | Diagnose your environment |
| `multi-cli completion {bash\|zsh\|powershell}` | Set up shell tab-completion |
| `multi-cli help` | Show help |
| `multi-cli version` | Show version |

---

## How Isolation Works

Schema-v2 adapters declare an account mechanism separately from normal state:

| Mechanism | How it works |
|-----------|--------------|
| `fileOverlay` | Credentials stay under the profile; declared normal state links to the native shared tool home. |
| `processSecret` | A per-profile, highest-precedence credential is injected into only the child process. Launch remains disabled until secure secret storage is configured. |
| `osUserCredentialStore` | Fixed keychain identities are separated with a multi-cli-owned OS user. This remains disabled until ownership and cleanup are verified. |
| `inseparable` | The vendor combines auth and normal state; compliant launch fails closed and the limitation is shown. |

Version-1 profiles retain the earlier whole-root `env`, `userDataDir`, `redirectHome`, `appdata`, and `sandboxUser` behavior for compatibility. Each `<id>/adapter.json` states product/platform capabilities and evidence requirements.

---

<a id="continue-a-chat-across-accounts"></a>

## Continue a Chat Across Accounts

Hit a rate limit on account A mid-conversation? Switch to a profile logged into account B and pick the chat up where it stopped. `multi-cli continue` copies the portable conversation state — sessions, transcripts, history — between profiles. **Credentials are never copied.**

```bash
# You were working in codex/work (account A) and got rate-limited.
# codex/personal is logged into account B.
multi-cli continue codex work personal          # copy the conversation state
multi-cli continue codex work personal --dry-run  # preview first, if you like

codex-personal                                  # launch account B's profile
codex resume <session-id>                        # resume the same chat (codex ≥ 0.30)
```

Run `codex resume` with no argument to open an interactive picker of past sessions, so you never have to look up an id. If you do need it, the session id is the UUID in the rollout filename under `sessions/YYYY/MM/DD/`.

`base` is a valid profile name on either end and refers to the tool's real home dir (`~/.codex`, `~/.claude`, …), so you can continue to or from your default install.

By default, files are **merged** — newer files in the destination are kept. Pass `--no-merge` to overwrite the destination instead, or `--dry-run` to preview without changing anything.

After copying, resume inside the destination profile with the tool's own command:

| Tool | Resume command |
|------|----------------|
| codex | `codex resume <session-id>` (≥ 0.30) |
| claude-cli | `claude --resume <session-id>` (run from the same project directory) |
| gemini-cli | `gemini --resume` (auto-saved last session) or `/chat resume <tag>` for saved checkpoints |
| commandcode | launch from the same working directory |

**Not supported:** `opencode` (sessions and credentials live in one shared SQLite database) and `cursor` (chats are stored in SQLite keyed to the workspace path).

> New profiles are seeded from `base` by default — conversation state, plus skills/config assets for full profiles. Pass `--no-seed` to `multi-cli new` to start empty.

---

## Profile Types

| Flag | Meaning |
|------|---------|
| *(none)* | **Full** — completely isolated. Fresh auth, fresh config. |
| `--shared` | **Shared** — symlinks settings/extensions from your main install. Auth stays isolated. |
| `--cli` | **CLI** — marks the profile for terminal-only launch (skips GUI discovery). |
| `--from <tpl>` | Clone from a saved template. |

---

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `MULTICLI_HOME` | `~/MultiCliProfiles` | Where all profiles are stored |
| `MULTICLI_OVERRIDE_BINARY` | *(unset)* | Force a specific binary path for the next launch |
| `MULTICLI_REPO` | *(unset)* | Git URL for remote install |
| `MULTICLI_PLATFORM` | *(auto)* | Override platform detection (`darwin`, `linux`) |

---

## Legacy Profiles

Profiles created before schema-v2 are legacy whole-root profiles: they keep the earlier `env`, `userDataDir`, `redirectHome`, `appdata`, and `sandboxUser` behavior for compatibility. A profile directory without a `.profile.json` file is treated as legacy.

`multi-cli migrate <tool>/<name>` converts a legacy profile to schema-v2: declared credentials move into the profile, and declared normal state links to the shared tool home. Use `--dry-run` to preview the move plan without changing anything, and `--prefer-profile` to replace conflicting shared files with the profile's copy — credential targets are never overwritten. Profile storage and the shared state root must be on the same volume, because migration uses atomic same-volume moves.

---

## Diagnostics

```bash
multi-cli doctor
```

Checks that your profile storage exists, alias directory is in PATH, and each tool's binary is detected (or shows an install hint).

---

## Shell Completion

```bash
multi-cli completion bash   # or zsh, powershell
```

Follow the instructions to add it to your `.zshrc`, `.bashrc`, or PowerShell `$PROFILE`.

---

## Uninstall

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/uninstall.sh | bash
```

**Windows**

```powershell
irm https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/uninstall.ps1 | iex
```

You'll be asked whether to remove your profile data — nothing is deleted without confirmation.

---

## Links

- [Support matrix](docs/support-matrix.md) — per-product, per-OS isolation status and the verification gate
- [Security policy](SECURITY.md)
- [License](LICENSE)
- [GitHub repository](https://github.com/Spielewoy/multi-codex)

---

## Credits

- **Creator** — [Spielewoy](https://github.com/Spielewoy)

---

## License

[MIT](LICENSE)
