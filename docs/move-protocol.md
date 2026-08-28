# Transactional profile movement protocol

Nini Agents contains a credential-bearing movement engine that is separate
from `export`, `import`, templates, and session continuation. Those existing
flows remain credential-free.

It also exposes a portable offline package contract on Bash and PowerShell:

```text
nini-agents move-export <tool>/<profile> [package.zip]
nini-agents move-import <package.zip> <tool>/<profile>
```

The package is an explicitly unencrypted, credential-bearing ZIP. It includes
the validated profile plus adapter-declared shared and session state so chats
and global skills can follow the profile between Linux/macOS and Windows.
Normal `export`/`import` are unchanged and remain credential-free.

The local engine remains available as an internal API. The Bash launcher also
exposes a public coordinator:

```text
nini-agents move <tool>/<profile> <device> [--dry-run] [--discard-source-backup] [--devices-config <path>]
nini-agents devices list|status|doctor ...
```

It uses SSH only to invoke the same Nini Agents endpoint and rsync only to
populate reserved staging. The controller validates its adapter and requires
the remote adapter SHA-256 to match before any remote validation or mutation.
The public JSON response uses envelope v1 and contains only `code`, `state`,
and `format`.

## Implementations

- Bash 3.2+: `move_profile_transaction` in `lib/transfer.sh`; public SSH
  coordination in `lib/remote-move.sh`.
- Windows PowerShell 5.1+: `Invoke-MultiCliProfileMove` in
  `lib/MultiCli.Transfer.psm1`.

Both implementations require two caller-provided capabilities:

1. A process probe that proves the source and destination tools are idle. An
   inconclusive probe fails closed.
2. A transport that populates an already reserved staging directory. The
   transport never chooses ownership or activates a profile.

The local-copy implementations remain the unit-test boundary. The public Bash
coordinator supplies the production SSH/rsync transport and a Linux/macOS
process probe. Linux is verified in this checkout; macOS and real-host
execution require protected platform validation. PowerShell rejects the public
remote command explicitly.

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
Legacy and isolated whole-root profiles may also contain adapter-declared
runtime paths, shared credential entries, and declared dot-suffix credential
backups. Undeclared content remains a preflight rejection.

Migrated account-overlay profiles may retain a completed migration journal, an
empty legacy shared marker, and adapter-declared normal state. A normal-state
link is accepted only when either its literal target is exactly the
adapter-owned shared path or an older completed migration journal records the
exact relative path as a skipped `keep-link`/`skip-link` operation. The latter
is the narrow compatibility case for legacy migration residue; arbitrary
external links still fail closed.

Accepted links are copied only as link objects into reserved staging, validated
again, and removed from staging without resolving their targets. Integrity
inventories compare the projected profile: they omit those accepted links on
the source/backup side and require them to be absent on the staged/destination
side. The original link objects remain in the inactive source backup for
rollback. No target content is read, hashed, traversed, copied, or deleted.

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
4. Revalidate staging, remove only proven normal-state link residue, revalidate
   the projected candidate, then compare source and staging structure, sizes,
   and SHA-256 hashes. Runtime and proven link residue are excluded because
   neither belongs in the destination profile.
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
source/.inactive/name.operation-id        verified inactive backup, optionally discarded after success
destination/.failed/name.operation-id     quarantined partial destination
source/.move-lock.name                    atomic ownership lock
```

Existing artifacts are never overwritten or pruned automatically.
With `--discard-source-backup`, the coordinator removes only the backup owned
by the current operation, after destination activation, runtime reconstruction,
and the final source/destination inventory comparison succeed. Earlier backups
are never selected. A cleanup failure leaves the destination active, releases
the ownership locks, and reports `backup_cleanup_failed`.

## Offline ZIP transaction

The ZIP contains exactly one `nini-agents-move-package.ndjson` entry. Its header
binds package schema v1 to the adapter, source profile format/mode, package ID,
and the explicit `encrypted: false` contract. Directory and `file-start`
records use validated relative paths; file metadata carries byte length and
SHA-256, followed by bounded base64 `chunk` records and `file-end`. Import
streams these records and creates only regular files
inside reserved staging, rather than extracting archive-controlled paths.

Export validates the profile and idle process state, stages the profile without
derived runtime/link residue, snapshots adapter-declared shared and session
paths, writes the ZIP, re-imports it into private staging, and compares both
profile and state inventories. Under the profile lock it rechecks idle state
and both snapshots, then atomically moves the source profile to its unique
inactive backup. Global shared state remains because other profiles may own it.

Import validates and reconstructs the package in private staging. Destination
shared state accepts missing files and byte-identical files only; a differing
file or unsafe object fails before activation. New state entries are tracked
and removed in reverse order if installation or profile activation fails. After
activation, schema-v2 account overlays rebuild and validate their runtime. The
archive is retained by default.

The offline package cannot prevent replay to multiple disconnected machines.
The operator must secure or delete extra package copies after confirming the
destination. Windows uses the same format through PowerShell/.NET; this checkout
does not claim executed Windows validation.

## Public result inventory

The internal and public implementations return only non-secret state and error
codes. These are wrapped by the stable JSON v1 envelope.

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
| Activation/rollback | `backup_prepare_failed`, `source_deactivation_failed`, `activation_failed_rolled_back`, `destination_invalid_rolled_back`, `destination_runtime_failed_rolled_back`, `rollback_failed`, `backup_cleanup_failed`, `lock_release_failed` |

The public coordinator can additionally return `invalid_configuration`,
`invalid_adapter`, `ownership_unproven`, `ownership_changed`,
`destination_unavailable`, `remote_health_failed`, `adapter_mismatch`, and
`remote_to_remote_unsupported`. These describe the device-registry and SSH
coordination boundary; engine structural failures keep their original codes.

The JSON response must not expose tokens, authentication values,
profile IDs, private machine identifiers, or absolute filesystem paths.

## Verification boundary

Automated movement tests use disposable roots, a fake SSH endpoint, a fake
copy transport, and structural fixture JSON.
They inject idle/busy probes, local/tampered/failed transports, activation
failures, runtime failures, and rollback failures. They do not inspect the
operator's processes, credential stores, profiles, or network.
