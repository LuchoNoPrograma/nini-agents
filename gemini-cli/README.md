# gemini-cli — Gemini CLI

**Account boundary:** `fileOverlay` — OAuth and account files are profile-local; settings, skills, and history are shared normal state.

Gemini CLI honors `GEMINI_CLI_HOME` to relocate its `.gemini/` tree. The adapter points it at a per-profile runtime view where only the declared credential files belong to the profile.

## Install

```bash
npm i -g @google/gemini-cli
```

Binary discovery: `%APPDATA%\npm\gemini.cmd` (Windows), `/usr/local/bin/gemini` (macOS), `$HOME/.npm-global/bin/gemini` (Linux), then `gemini` on PATH.

## Quickstart

```bash
multi-cli new gemini-cli/work
multi-cli launch gemini-cli/work      # sign in on first run; OAuth files stay profile-local
multi-cli new gemini-cli/personal
multi-cli launch gemini-cli/personal
```

Conversations are shared normal state, so `multi-cli continue` is not needed between schema-v2 profiles (it remains available for legacy profiles).

## Account boundary

- Profile-local credentials: `oauth_creds.json`, `google_accounts.json`, `mcp-oauth-tokens.json`, `a2a-oauth-tokens.json`.
- Credential precedence: `oauth_creds.json`, then `google_accounts.json`.
- Launch env: `GEMINI_CLI_HOME={runtimeRoot}`.
- Logout scope: profile.

## Shared normal state

Shared root: `%USERPROFILE%\.gemini` (Windows), `~/.gemini` (macOS/Linux).

- Config: `settings.json`, `trustedFolders.json`, `installation_id`, `keybindings.json`, `policy_integrity.json`, `projects.json`, `commands/`, `skills/`, `policies/`, `agents/`, `acknowledgments/`.
- Sessions: `history/`, `tmp/`.

## Known limitations

- `GEMINI_CLI_HOME` nesting and the OAuth overlay still require real authenticated concurrency verification per `adapter.json`; treat the boundary as a candidate until that gate passes.

## Support

| Windows | macOS | Linux |
|---|---|---|
| experimental | experimental | experimental |

`experimental` means a documented candidate boundary; the authenticated dual-account gate has not passed. No platform is verified.
