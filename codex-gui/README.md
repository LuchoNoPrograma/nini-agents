# codex-gui — Codex desktop app

**Account boundary:** an owned OS user separates the app's `.codex` authentication, configuration, and session state.

OpenAI ships the Codex app for Windows and macOS. The app and native Codex CLI share the user's `.codex` tree; running the app as a profile-owned user gives each profile a separate credential and data namespace.

## Install

Windows:

```powershell
winget install --id 9PLM9XGG6VKS -s msstore
```

macOS: download the Codex app from [OpenAI's Codex app page](https://openai.com/index/introducing-the-codex-app/).

## Quickstart

```powershell
multi-cli new codex-gui/work
multi-cli launch codex-gui/work
```

The first launch requires an elevated terminal on Windows so multi-cli can provision the owned user. The macOS app is available, but multi-cli does not claim account isolation there until an owned-user GUI/Keychain session is proven. If the app is absent, `multi-cli` reports the install source instead of starting a placeholder executable.

## Account boundary

- Mechanism: `osUserCredentialStore`.
- Profile-local state: the owned user's `.codex` tree and credential namespace.
- Logout scope: owned OS user.
- Concurrency: one app instance per owned OS user.

## Shared normal state

Nothing is shared because the app's authentication, configuration, and sessions use the same `.codex` tree. Use `multi-cli continue codex ...` for portable CLI sessions when needed.

## Known limitations

- Linux has no native Codex desktop app.
- Store package discovery is tested separately from the account-isolation runtime because Windows Server does not ship Microsoft Store.

## Support

| Windows | macOS | Linux |
|---|---|---|
| supported (Store app + owned OS user; elevated terminal) | unsupported (owned-user GUI/Keychain session not proven) | unsupported (no Codex desktop app) |
