# Adapter schema v2

Schema-v2 adapters describe an account boundary separately from the tool's normal state. The canonical machine-readable definition is `schema/adapter.schema.json`; both launchers also run semantic validation.

## Required contracts

- `schemaVersion: 2`
- `id`, `displayName`, `kind`
- `binary.windows|macos|linux`
- `isolation.strategy: accountOverlay`
- `isolation.mode: foreground|detached`
- `account.mechanism`
- `normalState.root`, `sharedPaths`, `sessionPaths`, `filePaths`, `unsafePaths`
- `concurrency.level`, `singletonScope`
- `support.windows|macos|linux`

## Account mechanisms

- `fileOverlay`: declared credential files live under the profile's `auth/`; declared normal state is linked to the product's native shared root.
- `processSecret`: the product supports a higher-priority per-process credential. Launch remains fail-closed until the secret has been stored through the secure credential command.
- `osUserCredentialStore`: the product uses a fixed keychain identity and requires a multi-cli-owned OS user.
- `inseparable`: auth and ordinary state cannot yet be divided safely. The schema records the limitation and compliant launches fail closed.

## Placeholders

Only these placeholders are accepted:

- `{profileDir}`
- `{profileId}`
- `{authDir}`
- `{runtimeRoot}`
- `{sharedStateRoot}`
- `{realHome}`

All state/auth paths are root-relative. Absolute paths, drive-qualified paths, parent traversal, and overlapping credential/shared/session/unsafe declarations are rejected.

## Validation

```bash
bash scripts/validate-adapters.sh
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Validate-Adapters.ps1
```

Schema-v1 manifests remain accepted for legacy profile tests and migration. New integrations must use schema v2.
