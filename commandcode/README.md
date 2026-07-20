# commandcode — Command Code

**Account boundary:** `inseparable` — the current product exposes only a whole-home boundary; exact disjoint auth and session paths require live verification.

Command Code resolves its home from `os.homedir()` with no override variable. The adapter declares a redirected `HOME`/`USERPROFILE`, but narrow auth-only isolation is not proven, so the account-overlay contract is not claimed.

## Install

```bash
npm i -g command-code
```

Provides the `cmd` binary (`%APPDATA%\npm\cmd.cmd` on Windows, `$HOME/.npm-global/bin/cmd` or `/usr/local/bin/cmd` elsewhere).

## Quickstart

Account-overlay profiles are unsupported on all platforms. Legacy whole-home profiles remain available:

```bash
multi-cli launch commandcode/<legacy-profile>
multi-cli doctor                        # shows the exact unsupported reason
```

## Account boundary

- Mechanism: `inseparable` — auth and sessions inside `~/.commandcode` have no proven split.
- Declared launch env: `HOME={runtimeRoot}/_home`, `USERPROFILE={runtimeRoot}/_home`.
- Logout scope: profile.

## Shared normal state

None classified. `adapter.json` declares no shared, session, or file paths under the native root (`%USERPROFILE%\.commandcode` on Windows, `~/.commandcode` on macOS/Linux).

## Known limitations

- Only whole-home isolation exists today; per-account credentials with shared normal state are not possible until the vendor's auth and session layout is verified as separable.

## Support

| Windows | macOS | Linux |
|---|---|---|
| unsupported | unsupported | unsupported |

`unsupported` means multi-cli refuses to claim the account-overlay contract. Legacy whole-home profiles remain available per `adapter.json`.
