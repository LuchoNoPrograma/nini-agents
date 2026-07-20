# Support matrix

`verified` means a real, current vendor binary passed authenticated simultaneous dual-account testing on that operating system. `experimental` means the adapter has a documented candidate boundary but the full gate has not passed. `unsupported` means multi-cli refuses to claim the account-overlay contract.

No product is marked verified yet. Offline version detection is evidence of installation only, not account separation.

| Adapter | Surface | Auth boundary | Shared normal state | Windows | macOS | Linux |
|---|---|---|---|---|---|---|
| `claude-cli` | Claude Code CLI | profile-local `.credentials.json` | `.claude` configuration and conversations | experimental | unsupported stored OAuth | experimental |
| `codex` | Codex CLI | profile-local `auth.json`, file credential mode required | `.codex` configuration and conversations | experimental | experimental | experimental |
| `gemini-cli` | Gemini CLI | profile-local OAuth/account files | `.gemini` configuration and conversations | experimental | experimental | experimental |
| `opencode` | OpenCode stored login | inseparable/unproven | configuration paths only | unsupported | unsupported | unsupported |
| `commandcode` | Command Code | whole-home only | not safely classified | unsupported | unsupported | unsupported |
| `cursor` | Cursor Desktop | inseparable/unproven | none claimed | unsupported | unsupported | unsupported |
| `cursor-cli` | Cursor CLI | per-process `CURSOR_API_KEY` | `cli-config.json` | experimental | experimental | experimental |
| `antigravity` | Antigravity IDE 2.x | fixed OS credential, separate OS user required | none claimed until DB tracing | experimental | unsupported | unsupported |
| `agy-cli` | Antigravity CLI | fixed OS credential, separate OS user required | settings/plugins/skills | experimental | unsupported | unsupported |
| `kiro` | Kiro IDE | separate OS user candidate | none claimed until live tracing | experimental | unsupported | unsupported |
| `zed` | Zed | credential URL namespace plus process boundary | none claimed until DB concurrency proof | unsupported | unsupported | experimental |
| `windsurf` | Devin Desktop / Windsurf | separate OS user candidate | none claimed | experimental | unsupported | unsupported |
| `copilot-cli` | GitHub Copilot CLI | per-process `COPILOT_GITHUB_TOKEN` | Copilot configuration and session state | experimental | experimental | experimental |
| `copilot-vscode` | Copilot in VS Code | separate OS user candidate | none claimed | experimental | unsupported | unsupported |
| `kimi-cli` | Kimi Code CLI direct provider | per-process `KIMI_MODEL_API_KEY` | documented config files | experimental | experimental | experimental |
| `codex-gui` | Codex Windows app | unverified/inseparable | none claimed | unsupported | unsupported | unsupported |
| `grok-cli` | Grok Build CLI/TUI | per-process `XAI_API_KEY` with precedence preconditions | documented config/sandbox state | experimental | experimental | experimental |

There is no separately supported first-party Grok Build desktop GUI in the sources reviewed. `grok-cli` covers the official CLI, fullscreen TUI/dashboard, headless mode, and ACP surface.

## Promotion gate

A platform row becomes verified only after all of these are recorded without secrets:

1. exact real binary and version;
2. two distinct vendor account identities represented only by per-run HMACs;
3. overlapping live processes;
4. independent account/quota attribution;
5. shared conversation visibility or resume where the adapter claims it;
6. shared normal configuration marker visibility;
7. logout/revocation of account A leaves B usable;
8. no credentials in the shared root, templates, exports, logs, screenshots, or evidence;
9. restart/reload behavior remains bound to the intended account context.
