# kiro — Kiro IDE

**Account boundary:** `osUserCredentialStore` (candidate) — Kiro's browser/IAM sign-in has no proven per-profile credential namespace, so profiles are isolated by owned OS user until live tracing proves a narrower boundary.

Kiro is an agentic IDE. No IDE-internal credential file or keychain namespace is documented as profile-safe, so multi-cli does not claim one.

## Install

[kiro.dev/docs/getting-started/installation](https://kiro.dev/docs/getting-started/installation/) — binary: `kiro` on PATH.

## Quickstart (Windows only)

```bash
multi-cli new kiro/work
multi-cli launch kiro/work              # runs under a profile-owned OS user
multi-cli new kiro/personal
multi-cli launch kiro/personal
```

macOS and Linux launches fail closed: no per-account credential namespace or concurrent IDE process boundary is proven there.

## Account boundary

- Profile-local credentials: the IDE browser/IAM sign-in, scoped to the profile's owned OS user.
- Logout scope: OS user.
- Concurrency: single writer per OS user (`singletonScope: osUser`).

## Shared normal state

None claimed yet. The native root (`%USERPROFILE%\.kiro` on Windows, `~/.kiro` on macOS/Linux) is recorded, but no settings, agents, prompts, steering, or session paths are shared until live tracing proves them credential-free.

## Known limitations

- Credential path, IDE singleton behavior, and safe shared-state paths all require a live OS-user E2E pass per `adapter.json`.
- No narrower IDE-internal boundary is inferred from VS Code ancestry.

## Support

| Windows | macOS | Linux |
|---|---|---|
| experimental | unsupported | unsupported |

`experimental` means a documented candidate boundary; the authenticated dual-account gate has not passed. No platform is verified.
