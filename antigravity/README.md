# antigravity — Google Antigravity IDE

**Account boundary:** `osUserCredentialStore` — Antigravity authenticates through fixed OS credential entries, so each profile runs under a multi-cli-owned OS user.

Antigravity IDE 2.x stores its account under a fixed keychain identity (`gemini:antigravity` on Windows, `gemini/antigravity` on macOS, `service=gemini username=antigravity` on Linux). Two profiles under the same OS user overwrite each other's login; a dedicated OS user per profile is the only declared boundary.

## Install

[antigravity.google.com](https://antigravity.google.com/)

Binary discovery: `%LOCALAPPDATA%\Programs\Antigravity\Antigravity.exe` (Windows), `/Applications/Antigravity.app` (macOS), `/usr/bin/antigravity` or `/opt/Antigravity/antigravity` (Linux).

## Quickstart (Windows only)

```bash
multi-cli new antigravity/work
multi-cli launch antigravity/work       # first launch provisions a profile-owned OS user
multi-cli new antigravity/personal
multi-cli launch antigravity/personal
```

macOS and Linux launches fail closed: fixed Keychain/Secret Service isolation is not implemented there.

## Account boundary

- Profile-local credentials: the fixed OS credential entry, scoped to the profile's owned OS user.
- Logout scope: OS user.
- Concurrency: single writer per OS user (`singletonScope: osUser`).

## Shared normal state

None claimed yet. Native roots: `%APPDATA%\Antigravity` (Windows), `~/Library/Application Support/Antigravity` (macOS), `~/.config/Antigravity` (Linux).

`User/globalStorage/storage.json` and `User/globalStorage/state.vscdb` are declared unsafe: account data and IDE state are not proven separable inside them, so they are never linked or shared.

## Known limitations

- The fixed keychain identity makes same-OS-user dual accounts impossible; OS-user provisioning is mandatory.
- No shared normal state until database tracing proves which paths are credential-free.
- Authenticated Antigravity 2.0 GUI E2E is pending.

## Support

| Windows | macOS | Linux |
|---|---|---|
| experimental | unsupported | unsupported |

`experimental` means a documented candidate boundary; the authenticated dual-account gate has not passed. No platform is verified.
