# Transactional profile movement protocol

Nini Agents contains a credential-bearing movement engine that is separate
from `export`, `import`, templates, and session continuation. Those existing
flows remain credential-free.

The engine is currently an internal API. It does not expose a public `move`
command, SSH transport, device registry, or stable JSON response yet. Those
boundaries are intentionally deferred until the JSON contract and remote
coordination are implemented.

## Implementations

- Bash 3.2+: `move_profile_transaction` in `lib/transfer.sh`.
- Windows PowerShell 5.1+: `Invoke-MultiCliProfileMove` in
  `lib/MultiCli.Transfer.psm1`.

Both implementations require two caller-provided capabilities:

1. A process probe that proves the source and destination tools are idle. An
   inconclusive probe fails closed.
2. A transport that populates an already reserved staging directory. The
   transport never chooses ownership or activates a profile.

The local-copy implementations exist for synthetic tests. No production SSH
transport is wired to the engine.

## Supported profile boundary

Movement currently accepts only filesystem credentials declared by a
`fileOverlay` adapter.

Legacy format:

```text
<profile>/auth.json
```

Schema v2:

```text
<profile>/.profile.json
<profile>/auth/<adapter credential paths>
<profile>/.runtime/...
```

Authentication JSON is parsed only to prove that it is a JSON object. Its
values are never printed or returned. Metadata must identify schema v2, the
selected adapter, a non-empty profile ID, and a recognized profile mode.

Schema-v2 `.runtime/` is not transported and is not a credential source. The
destination reconstructs it from the adapter after activation, then proves
that every runtime link resolves to the destination's canonical profile or
shared-state source. The expected Windows hardlink between
`auth/<credential>` and `.runtime/<credential>` is accepted only when it is
the declared runtime link; unrelated hardlinks fail closed.

## Transaction

1. Validate safe roots, identifiers, profile format, metadata, credentials,
   declared content, links, hardlinks, transaction paths, and single active
   destination.
2. Require an idle result from the process probe on both sides.
3. Reserve a unique staging directory and ask the transport to populate it.
4. Compare source and staging structure, sizes, and SHA-256 hashes. Runtime is
   excluded because it is reconstructible.
5. Acquire an atomic per-profile ownership lock.
6. Revalidate source, destination, hashes, and process state while locked.
7. Atomically move the source into its inactive backup path.
8. Atomically activate staging at the destination path.
9. Revalidate structure and bytes, rebuild schema-v2 runtime, and compare
   canonical data again.
10. Keep the original source as an inactive backup and release the lock.

If activation or destination validation fails, the engine quarantines any
partial destination under `.failed/` and restores the source. If quarantine or
restoration cannot be proven, it reports `ownership_indeterminate`, keeps all
recoverable artifacts, and never creates another active source.

No successful or rejected transition calls logout, revoke, auth clear,
reauthentication, or an OpenAI API.

## Transaction artifacts

For profile `name` and operation `operation-id`, roots contain:

```text
destination/.staging/name.operation-id   candidate, never active
source/.inactive/name.operation-id        verified inactive backup
destination/.failed/name.operation-id     quarantined partial destination
source/.move-lock.name                    atomic ownership lock
```

Existing artifacts are never overwritten or pruned automatically.

## Result inventory for the future JSON CLI

The internal implementations currently return only non-secret state and error
codes. Stage F will wrap these in a versioned JSON envelope; field names and
the public command are not frozen yet.

States:

| State | Meaning |
|---|---|
| `validated` | Dry-run preflights succeeded; nothing was copied or moved. |
| `preflight_rejected` | No staging or ownership transition was allowed. |
| `source_active` | The source remains the only active owner. |
| `staging_preserved` | Source remains active and a recoverable candidate may remain. |
| `staging_rejected` | Candidate hashes or structure differ; source remains active. |
| `source_restored` | Activation failed and rollback restored the source. |
| `destination_active` | Destination is active and source is an inactive backup. |
| `ownership_indeterminate` | The engine could not prove a safe rollback; all artifacts are preserved. |

Success codes are `ok` and `dry_run`. Rejection and failure codes are grouped
by boundary:

| Boundary | Codes |
|---|---|
| Input/root | `invalid_identifier`, `invalid_callback`, `unsafe_root`, `source_missing`, `unsupported_mechanism` |
| Profile | `invalid_metadata`, `missing_credential`, `invalid_auth_json`, `unknown_content`, `unsafe_entry`, `unsafe_link`, `unsafe_hardlink` |
| Ownership/artifacts | `destination_active`, `destination_appeared`, `staging_conflict`, `backup_conflict`, `failed_artifact_conflict`, `transaction_locked` |
| Process/transport | `process_active`, `process_appeared`, `process_probe_failed`, `staging_create_failed`, `transport_failed`, `integrity_mismatch` |
| Activation/rollback | `backup_prepare_failed`, `source_deactivation_failed`, `activation_failed_rolled_back`, `destination_invalid_rolled_back`, `destination_runtime_failed_rolled_back`, `rollback_failed`, `lock_release_failed` |

The future JSON response must not expose tokens, authentication values,
profile IDs, private machine identifiers, or absolute filesystem paths.

## Verification boundary

Automated movement tests use disposable roots and structural fixture JSON.
They inject idle/busy probes, local/tampered/failed transports, activation
failures, runtime failures, and rollback failures. They do not inspect the
operator's processes, credential stores, profiles, or network.

