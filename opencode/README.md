# opencode — OpenCode

**Account boundary:** `inseparable` — stored provider authentication and runtime data have no proven disjoint profile boundary, so multi-cli refuses the account-overlay contract on every platform.

OpenCode resolves config from `OPENCODE_CONFIG_DIR` and `OPENCODE_CONFIG`. That relocates configuration, but stored logins and sessions cannot yet be split truthfully; only configuration paths are classified as shareable.

## Install

```bash
npm i -g opencode-ai
```

Binary discovery: `%APPDATA%\npm\opencode.cmd` (Windows), `/usr/local/bin/opencode` (macOS), `$HOME/.npm-global/bin/opencode` (Linux), then `opencode` on PATH.

## Quickstart

Account-overlay launch fails closed on all platforms. Existing legacy whole-home profiles remain launchable:

```bash
multi-cli launch opencode/<legacy-profile>
multi-cli doctor                      # shows the exact unsupported reason
```

## Account boundary

- Mechanism: `inseparable` — per `adapter.json`, "Stored provider authentication and runtime data do not have a proven disjoint profile boundary."
- Declared launch env: `OPENCODE_CONFIG_DIR={runtimeRoot}`, `OPENCODE_CONFIG={runtimeRoot}/opencode.json`.
- Logout scope: user — a logout affects the whole OS-user credential state.

## Shared normal state

Configuration only (a candidate classification, not an isolation claim): `opencode.json`, `tui.json`, `agents/`, `commands/`, `modes/`, `plugins/`, `skills/`, `tools/`, `themes/`.

No session paths are declared shareable, and no profile-local credentials can be carved out today.

## Known limitations

- Stored-login mode cannot run two accounts with a truthful boundary; `multi-cli continue` is unavailable because sessions and credentials are not separable.
- Direct provider environment credentials may become a `processSecret` candidate later; they are not part of this adapter today.

## Support

| Windows | macOS | Linux |
|---|---|---|
| unsupported | unsupported | unsupported |

`unsupported` means multi-cli refuses to claim the account-overlay contract. Legacy whole-home profiles keep their previous behavior.
