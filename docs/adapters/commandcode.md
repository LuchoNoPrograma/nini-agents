# commandcode: Command Code

**Account boundary:** `fileOverlay`: `.commandcode/auth.json` is profile-local; declared configuration and session paths are shared normal state.

Command Code resolves its home from `os.homedir()` with no override variable. The adapter redirects `HOME`/`USERPROFILE` at a per-profile runtime view where only `.commandcode/auth.json` belongs to the profile.

## Install

```bash
npm i -g command-code
```

Binary discovery: `%APPDATA%\npm\commandcode.cmd` (Windows), `$HOME/.npm-global/bin/commandcode` or `/usr/local/bin/commandcode` (macOS/Linux), then `commandcode` on PATH.

## Quickstart

Account-overlay profiles are supported on all platforms:

```bash
nini-agents new commandcode/work
nini-agents launch commandcode/work       # sign in on first run; auth.json stays profile-local
```

## Account boundary

- Mechanism: `fileOverlay`: `.commandcode/auth.json` is profile-local; `COMMAND_CODE_API_KEY` takes precedence when set.
- Declared launch env: `HOME={runtimeRoot}`, `USERPROFILE={runtimeRoot}`.
- Logout scope: profile.

## Shared normal state

Shared root: the Command Code state directory (`%USERPROFILE%\.commandcode` on Windows, `$HOME/.commandcode` on macOS/Linux).

- Config: `config.json`, `settings.json`, `skills/`, `plans/`, `taste/`.
- Sessions: `projects/`, `history.jsonl`, `file-history/`.

## Known limitations

- Use the `commandcode` binary name; bare `cmd` collides with Windows cmd.exe.

## Support

| Windows | macOS | Linux |
|---|---|---|
| supported (file overlay; use `commandcode`, bare `cmd` collides with cmd.exe) | supported | supported |
