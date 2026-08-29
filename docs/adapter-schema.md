# Adapter schema v2

Schema v2 separates account credentials from ordinary tool state. The machine-readable contract is [`schema/adapter.schema.json`](../schema/adapter.schema.json). Mutation and audit commands run the complete semantic checks before using a manifest. Launch parses its required fields once and repeats traversal checks at each filesystem join; run `nini-agents doctor` for the exhaustive adapter audit.

## Required fields

- `schemaVersion: 2`
- `id`, `displayName`, `kind`
- `binary.windows`, `binary.macos`, `binary.linux`, each with at least one candidate
- `isolation.strategy: accountOverlay`
- `isolation.mode: foreground` or `detached`
- `account.mechanism`
- `normalState.root.windows`, `.macos`, `.linux`
- `normalState.sharedPaths`, `.sessionPaths`, `.unsafePaths`
- `concurrency.level`, `.singletonScope`
- `support.windows`, `.macos`, `.linux`

`normalState.filePaths` is optional. It marks entries already declared exactly in `sharedPaths` or `sessionPaths` that must be treated as files rather than directories; it cannot introduce another state path. `normalState.directPaths` is also optional and must be an exact subset of those same state lists. Direct paths remain under `normalState.root` and are not created or linked inside `.runtime`; the adapter must route the tool to that root explicitly. `normalState.runtimeSubdir` is optional and scopes the runtime view to a safe relative directory below the declared root.

`normalState.migrationPreservePaths` is an optional migration-only
subclassification. Every entry must be an exact member of `sharedPaths` or
`sessionPaths`, so it cannot introduce runtime state. Schema-v2 launch behavior
is unchanged. During legacy migration, each existing object is preserved whole
by same-volume rename under
`.inactive/migrations/<adapter>/<profile>/profile-state/` instead of being
merged into the live normal-state root. The operation is journaled and
automatic rollback returns it to the legacy location. This is intended for
transactional families, volatile locks, or similar state whose members must
not be combined with an unrelated live instance.

`normalState.migrationActivatePaths` is an optional migration-only allowlist.
Every entry must be an exact member of `sharedPaths` or `sessionPaths`. When
the field is absent, the legacy behavior remains unchanged and all declared
shared/session state is eligible for merge. When the field is present, only
its entries are merged into the live normal-state root; every other declared
shared/session object is renamed whole under
`.inactive/migrations/<adapter>/<profile>/profile-state/`. This keeps omitted
state recoverable while avoiding per-file traversal and merge work for bulky
histories. An empty list intentionally activates no ordinary state. Runtime
launch behavior is unchanged, and credential handling is unaffected.

`normalState.runtimePaths` is optional. It declares exact paths for
reconstructible state that the upstream tool creates inside its runtime view.
Nini Agents does not create empty placeholders, links, exports, imports, or
copies for these paths. `doctor --deep` accepts a declared path and its
descendants without adding them to `.runtime-manifest`. Legacy migration
preserves each existing object by same-volume rename under
`.inactive/migrations/<adapter>/<profile>/runtime-state/`; automatic rollback
returns it to the legacy profile. Runtime paths must remain disjoint from every
credential, shared, session, and unsafe path.

`sharedCredentialState` is optional and available only to schema-v2
`fileOverlay` adapters. It models sensitive state that the upstream tool must
share across every profile while keeping the primary account credential
profile-local:

```json
{
  "sharedCredentialState": {
    "root": ".shared/example-cli/oauth",
    "entries": [
      { "path": ".credentials.json", "kind": "jsonObjectFile" },
      { "path": "oauth-locks", "kind": "directory" }
    ],
    "legacyMigration": "preserveInactive",
    "legacyBackupPattern": "dotSuffix"
  }
}
```

The root must be below `.shared/<adapter-id>/` in `MULTICLI_HOME`. Entry paths
are the paths exposed inside the tool runtime. They must be non-empty,
non-overlapping, and disjoint from profile credentials, shared/session state,
runtime state, and unsafe paths. `jsonObjectFile` initializes a missing backing file as `{}`;
`directory` initializes a private directory. Existing credential content is
not parsed by the runtime. Initialization is serialized across profiles and
fails closed on links or unexpected filesystem types.

These entries are one engine-owned credential group. They are never included
in templates, exports, imports, profile clones, or profile moves. A legacy
migration never imports them into the active shared store: it moves the legacy
objects themselves by same-volume rename to
`.inactive/migrations/<adapter>/<profile>/shared-credentials/`, journals the
operation, and restores it during automatic rollback. The inactive recovery
object is retained after success until the operator handles it explicitly.
When the optional `legacyBackupPattern` is `dotSuffix`, a sibling named
`<entry>.<non-empty-suffix>` is classified as credential state too. Migration
preserves that object in the same inactive credential recovery tree; transfer
rejects it as a credential. The namespace must not overlap another declaration.

## Account mechanisms

| Mechanism | Boundary |
|---|---|
| `fileOverlay` | Credential files stay inside the profile. Declared normal state links to the native shared root. `account.credentialFiles` must not be empty. |
| `processSecret` | A credential is injected into the child process. `account.secret.environmentVariable` is required, and launch fails until `nini-agents auth set` stores the secret. |
| `osUserCredentialStore` | Each profile uses a Nini Agents-owned OS user because the product has a fixed credential-store identity. |
| `inseparable` | Authentication and ordinary state cannot be divided safely. `account.reason` is required, account-overlay launch fails closed, and the user must choose `--isolated`. |

## Support levels

Each platform has one level:

- `supported`: at least one isolation mode works. Use `reason` to state mode requirements.
- `unsupported`: no isolation mode works. `reason` is required.

The retired `verified` and `experimental` levels are invalid. `evidenceId` is not part of the schema.

## Paths and placeholders

Accepted placeholders:

- `{profileDir}`
- `{profileId}`
- `{authDir}`
- `{runtimeRoot}`
- `{sharedStateRoot}`
- `{realHome}`

Credential and state entries are relative to their declared root. Absolute paths, drive-qualified paths, parent traversal, and overlaps between profile credentials, shared credentials, shared state, session state, reconstructible runtime state, and unsafe paths are invalid.

For a schema-v2 file/process account-overlay launch, adapter-declared
`isolation.args` are expanded with the same placeholders and placed after user
options, but before a literal `--` positional delimiter. This is appropriate
for tool configuration that must enforce the account boundary.
`unsafePaths` are recognized declarations, but a legacy migration that finds
one fails before writing; they are never silently treated as ordinary state.

Unknown legacy objects also fail closed by default. The operator may opt into
`migrate --preserve-unknown` after reviewing a profile: each unknown object is
then renamed whole, on the same volume, below
`.inactive/migrations/<adapter>/<profile>/unknown-state/`. It is not reclassified
as adapter state, read, merged, or exposed in the schema-v2 runtime. Journaled
rollback restores it to the legacy location. The option never overrides an
overlap or an `unsafePaths` match.

## Validate

```bash
bash scripts/validate-adapters.sh
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Validate-Adapters.ps1
```

Schema v1 remains available for migration and legacy profile tests. New adapters must use schema v2. See the [17 adapter guides](adapters/README.md) for complete examples.
