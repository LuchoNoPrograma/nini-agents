# kiro — Kiro IDE

**Account boundary:** `osUserCredentialStore` — Kiro's browser/IAM sign-in has no per-profile credential namespace, so shared profiles use an owned OS user. `--isolated` is also available for a whole-root profile.

Kiro is an agentic IDE. No IDE-internal credential file or keychain namespace is documented as profile-safe, so multi-cli does not claim one.

## Install

[kiro.dev/docs/getting-started/installation](https://kiro.dev/docs/getting-started/installation/) — binary: `kiro` on PATH.

## Quickstart

```bash
multi-cli new kiro/work
multi-cli launch kiro/work              # runs under a profile-owned OS user
multi-cli new kiro/personal
multi-cli launch kiro/personal
```

On every platform, shared profiles use an owned OS user. `--isolated` is available when a whole-root profile is preferable.

## Account boundary

- Profile-local credentials: the IDE browser/IAM sign-in, scoped to the profile's owned OS user.
- Logout scope: OS user.
- Concurrency: single writer per OS user (`singletonScope: osUser`).

## Shared normal state

None claimed yet. The native root (`%USERPROFILE%\.kiro` on Windows, `~/.kiro` on macOS/Linux) is recorded, but no settings, agents, prompts, steering, or session paths are shared until live tracing proves them credential-free.

## Known limitations

- Safe shared-state paths are intentionally empty until vendor tracing proves they are credential-free.
- Owned OS-user profiles require administrator access on Windows and `sudo` on macOS/Linux.

## Support

| Windows | macOS | Linux |
|---|---|---|
| supported (owned OS user; elevated terminal) | supported (`--isolated`; owned-user GUI credential sessions are not claimed) | supported (`--isolated`; owned-user GUI credential sessions are not claimed) |
