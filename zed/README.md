# zed — Zed

**Account boundary:** `osUserCredentialStore` — Zed namespaces credentials through its `credentials_url` keychain entry; the declared boundary combines that namespace with a per-profile process and data root.

Zed is a singleton per release channel and OS user. On Linux, separate data roots plus credential namespaces are a candidate boundary; on Windows and macOS the same-channel singleton/IPC prevents truthful same-user concurrent accounts.

## Install

[zed.dev/docs/installation](https://zed.dev/docs/installation)

Binary discovery: `zed` or `zeditor` (Linux), `zed.exe` (Windows), `/usr/local/bin/zed` (macOS).

## Quickstart (Linux only)

```bash
multi-cli new zed/work
multi-cli launch zed/work
multi-cli new zed/personal
multi-cli launch zed/personal
```

Windows and macOS launches fail closed.

## Account boundary

- Profile-local credentials: the Zed `credentials_url` keychain namespace.
- Logout scope: credential namespace.
- Singleton scope: release channel and OS user (`releaseChannelAndOsUser`).

## Shared normal state

None claimed yet. Native roots: `%LOCALAPPDATA%\Zed` (Windows), `~/Library/Application Support/Zed` (macOS), `~/.local/share/zed` (Linux).

The `db/` directory (SQLite) is declared unsafe and is never shared until dual-process database concurrency is proven.

## Known limitations

- Linux is the only candidate platform, and custom data roots plus credential namespaces still need a live dual-process/database E2E pass.
- Windows and macOS are unsupported: same-channel singleton/IPC and the shared database make same-user concurrent accounts untruthful.

## Support

| Windows | macOS | Linux |
|---|---|---|
| unsupported | unsupported | experimental |

`experimental` means a documented candidate boundary; the authenticated dual-account gate has not passed. No platform is verified.
