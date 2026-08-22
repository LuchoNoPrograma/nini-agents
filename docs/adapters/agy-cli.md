# agy-cli: Antigravity CLI (agy)

**Account boundary:** `osUserCredentialStore`: `agy` uses the same fixed `gemini`/`antigravity` OS credential as the Antigravity IDE, so each profile runs under a nini-agents-owned OS user.

The Antigravity CLI is the terminal companion to the IDE. Its fixed credential identity means same-OS-user profiles would overwrite each other's login; the adapter isolates by OS user and links only declared safe paths.

## Install

[antigravity.google/docs/cli/install](https://antigravity.google/docs/cli/install)

Binary discovery: `%LOCALAPPDATA%\agy\bin\agy.exe` (Windows), `~/.local/bin/agy` (macOS/Linux), then `agy` on PATH.

## Quickstart

```bash
nini-agents new agy-cli/work
nini-agents launch agy-cli/work           # first launch provisions a profile-owned OS user
nini-agents new agy-cli/personal
nini-agents launch agy-cli/personal
```

The first launch requires an elevated terminal on Windows so nini-agents can provision the owned OS user. macOS and Linux remain unsupported until real owned-user Keychain/Secret Service isolation is implemented and verified.

## Account boundary

- Profile-local credentials: the fixed `gemini`/`antigravity` OS credential, scoped to the profile's owned OS user.
- Logout scope: OS user.
- Concurrency: multiple writers allowed, one instance per OS user (`singletonScope: osUser`).

## Shared normal state

Shared root: `%USERPROFILE%\.gemini\antigravity-cli` (Windows), `~/.gemini/antigravity-cli` (macOS/Linux).

- Shared: `settings.json`, `plugins/`, `skills/`.
- No session paths are declared.

## Known limitations

- OS-user profiles require administrator access on Windows. macOS and Linux are not advertised as supported.
- `--isolated` is rejected because folder redirection cannot isolate the fixed OS credential store.
- Authenticated `agy` dual-account testing requires two test accounts; the runtime and cleanup paths are covered by platform tests.

## Support

| Windows | macOS | Linux |
|---|---|---|
| supported (owned OS user; elevated terminal) | unsupported (owned-user Keychain isolation not proven) | unsupported (owned-user Secret Service session not implemented) |
