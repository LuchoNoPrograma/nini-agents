# agy-cli — Antigravity CLI (agy)

**Account boundary:** `osUserCredentialStore` — `agy` uses the same fixed `gemini`/`antigravity` OS credential as the Antigravity IDE, so each profile runs under a multi-cli-owned OS user.

The Antigravity CLI is the terminal companion to the IDE. Its fixed credential identity means same-OS-user profiles would overwrite each other's login; the adapter isolates by OS user and links only declared safe paths.

## Install

[antigravity.google/docs/cli/install](https://antigravity.google/docs/cli/install)

Binary discovery: `%LOCALAPPDATA%\agy\bin\agy.exe` (Windows), `~/.local/bin/agy` (macOS/Linux), then `agy` on PATH.

## Quickstart (Windows only)

```bash
multi-cli new agy-cli/work
multi-cli launch agy-cli/work           # first launch provisions a profile-owned OS user
multi-cli new agy-cli/personal
multi-cli launch agy-cli/personal
```

macOS and Linux launches fail closed: OS-user isolation is not implemented there yet.

## Account boundary

- Profile-local credentials: the fixed `gemini`/`antigravity` OS credential, scoped to the profile's owned OS user.
- Logout scope: OS user.
- Concurrency: multiple writers allowed, one instance per OS user (`singletonScope: osUser`).

## Shared normal state

Shared root: `%USERPROFILE%\.gemini\antigravity-cli` (Windows), `~/.gemini/antigravity-cli` (macOS/Linux).

- Shared: `settings.json`, `plugins/`, `skills/`.
- No session paths are declared.

## Known limitations

- OS-user isolation exists for Windows only; macOS Keychain and Linux Secret Service isolation are not yet implemented.
- Authenticated `agy` dual-account concurrency E2E is pending.

## Support

| Windows | macOS | Linux |
|---|---|---|
| experimental | unsupported | unsupported |

`experimental` means a documented candidate boundary; the authenticated dual-account gate has not passed. No platform is verified.
