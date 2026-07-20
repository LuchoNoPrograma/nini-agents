# cursor — Cursor Desktop

**Account boundary:** `inseparable` — desktop credentials, chat state, SQLite global storage, and singleton behavior have no proven narrow split.

Cursor accepts VS Code-style user-data flags, but per `adapter.json` those flags do not prove separate desktop auth with shared conversations. The account-overlay contract is therefore not claimed.

## Install

[cursor.com/download](https://cursor.com/download)

Binary discovery: `%LOCALAPPDATA%\Programs\cursor\Cursor.exe` (Windows), `/Applications/Cursor.app` (macOS), `/usr/bin/cursor` or `/opt/Cursor/cursor` (Linux).

## Quickstart

Unsupported on all platforms; legacy whole-home profiles remain launchable:

```bash
multi-cli launch cursor/<legacy-profile>
```

For a working account boundary, use the Cursor CLI adapter (`cursor-cli`), which isolates via a per-process API key.

## Account boundary

- Mechanism: `inseparable` — credentials, chat databases, and global storage are not proven separable.
- Logout scope: user.
- Concurrency: single instance per OS user (`singletonScope: user`).

## Shared normal state

None claimed. `adapter.json` declares no shared, session, or file paths under the native root (`%USERPROFILE%\.cursor` on Windows, `~/.cursor` on macOS/Linux).

## Known limitations

- Chat history lives in SQLite keyed to workspace state and cannot be portably shared or copied between profiles.
- A narrower boundary requires proof that auth, chat databases, and single-instance behavior are separable; until then nothing is shared.

## Support

| Windows | macOS | Linux |
|---|---|---|
| unsupported | unsupported | unsupported |

`unsupported` means multi-cli refuses to claim the account-overlay contract.
