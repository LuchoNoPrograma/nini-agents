# windsurf — Devin Desktop (Windsurf)

**Account boundary:** `osUserCredentialStore` (candidate) — Devin account or manual API-key login has no documented per-profile namespace, so profiles are isolated by owned OS user.

Windsurf is now Devin Desktop. The adapter detects both current and legacy binaries: `devin-desktop`, `surf`, `windsurf`.

## Install

[docs.devin.ai/desktop/getting-started](https://docs.devin.ai/desktop/getting-started)

## Quickstart (Windows only)

```bash
multi-cli new windsurf/work
multi-cli launch windsurf/work          # runs under a profile-owned OS user
multi-cli new windsurf/personal
multi-cli launch windsurf/personal
```

macOS and Linux launches fail closed: no documented profile auth namespace or concurrent-instance contract exists there.

## Account boundary

- Profile-local credentials: the Devin account or manual API-key login, scoped to the profile's owned OS user.
- Logout scope: OS user.
- Concurrency: single writer; singleton behavior is undocumented (`singletonScope: unknown`).

## Shared normal state

None claimed. Native roots: `%APPDATA%\Devin` (Windows), `~/Library/Application Support/Devin` (macOS), `~/.config/Devin` (Linux).

## Known limitations

- Current and legacy data roots, fixed `~/.codeium` state that can leak across profiles, auth storage, and multi-instance behavior all require an OS-user E2E pass before anything is shared.
- Legacy Windsurf paths may still be read by current binaries; the boundary is not proven until those reads are traced.

## Support

| Windows | macOS | Linux |
|---|---|---|
| experimental | unsupported | unsupported |

`experimental` means a documented candidate boundary; the authenticated dual-account gate has not passed. No platform is verified.
