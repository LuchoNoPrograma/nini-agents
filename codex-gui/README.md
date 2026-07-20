# codex-gui — Codex Windows App

**Account boundary:** `inseparable` / unverified — the desktop executable, `CODEX_HOME` behavior, package state, keychain, and singleton boundary are all unverified. Launch is disabled on every platform.

The Codex desktop app exists as a Windows Store/desktop executable, but multi-cli has not proven any account boundary for it. The binary candidate is the placeholder `codex-app-unverified`, so discovery fails by design and `multi-cli launch` refuses to start a profile.

## Install

[developers.openai.com/codex/windows/windows-app](https://developers.openai.com/codex/windows/windows-app)

## Quickstart

None — this adapter is unsupported everywhere. Use the `codex` adapter (Codex CLI) instead; it has a declared file-overlay account boundary over the same `~/.codex` root.

## Account boundary

- Mechanism: `inseparable` — per `adapter.json`, "The desktop executable, CODEX_HOME behavior, package state, keychain, and singleton boundary are unverified."
- Logout scope: application.
- Concurrency: unsupported (`singletonScope: application`).

## Shared normal state

None claimed. The native root (`%USERPROFILE%\.codex` on Windows, `~/.codex` on macOS/Linux) is recorded for reference only; no shared, session, or file paths are declared.

## Known limitations

- Windows: launch remains disabled until the real Store executable and dual-account GUI behavior are proven.
- macOS: no verified Codex GUI account-overlay implementation. Linux: no supported native Codex GUI surface at all.

## Support

| Windows | macOS | Linux |
|---|---|---|
| unsupported | unsupported | unsupported |

`unsupported` means multi-cli refuses to claim the account-overlay contract.
