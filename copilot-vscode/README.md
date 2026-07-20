# copilot-vscode — GitHub Copilot in VS Code

**Account boundary:** `osUserCredentialStore` (candidate) — Copilot identity lives in the VS Code GitHub authentication and extension credential store, so profiles are isolated by owned OS user.

This adapter models the real host — VS Code (`code`) plus the official Copilot extension — not a standalone IDE. Other IDE hosts are not claimed by this adapter.

## Install

[docs.github.com — install the Copilot extension](https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-extension)

Binary discovery: `code.cmd` / `code` (Windows), `code` (macOS/Linux).

## Quickstart (Windows only)

```bash
multi-cli new copilot-vscode/work
multi-cli launch copilot-vscode/work    # runs under a profile-owned OS user
multi-cli new copilot-vscode/personal
multi-cli launch copilot-vscode/personal
```

macOS and Linux launches fail closed: no proven per-host Copilot credential namespace exists there.

## Account boundary

- Profile-local credentials: VS Code GitHub authentication plus the Copilot extension credential store, scoped to the profile's owned OS user.
- Logout scope: OS user.
- Concurrency: single writer per host profile (`singletonScope: hostProfile`).

## Shared normal state

None claimed. `User/globalStorage/` and `User/workspaceStorage/` under the VS Code data root (`%APPDATA%\Code` on Windows, `~/Library/Application Support/Code` on macOS, `~/.config/Code` on Linux) are declared unsafe and are never shared.

## Known limitations

- Two VS Code hosts must still prove distinct Copilot identity/quota and logout isolation under owned OS users before the boundary can be promoted.
- Editor and Copilot ordinary state are intentionally not split; nothing is shared.

## Support

| Windows | macOS | Linux |
|---|---|---|
| experimental | unsupported | unsupported |

`experimental` means a documented candidate boundary; the authenticated dual-account gate has not passed. No platform is verified.
