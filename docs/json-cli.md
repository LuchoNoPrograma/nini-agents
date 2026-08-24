# JSON CLI contract

Nini Agents exposes a versioned JSON interface for read-only consumers and
profile creation and rename. Human output remains the default and is unchanged.
Put `--json` before the first `--` delimiter; both of these forms are equivalent:

```text
nini-agents --json list
nini-agents list --json
```

The temporary `multi-cli` shim delegates the same contract. JSON output is one
compact document on stdout. Successful commands do not write diagnostics to
stderr.

## Envelope v1

Every response follows [the JSON schema](../schema/cli-output.schema.json):

```json
{
  "schemaVersion": 1,
  "command": "version",
  "ok": true,
  "data": {
    "product": "nini-agents",
    "version": "1.0.0"
  },
  "error": null
}
```

An error sets `ok` to `false`, `data` to `null`, and provides a stable
snake-case `error.code`. Messages are for people; consumers must branch on the
code.

## Supported commands

| Command | Stable `data` fields |
|---|---|
| `version` | `product`, `version` |
| `list [tool]`, `status [tool]` | `profiles[]`, `count` |
| `tools` | `platform`, `tools[]`, `count` |
| `doctor` | `platform`, `storage`, `aliasDirectoryOnPath`, `tools[]` |
| `stats` | `profiles[]`, `count`, `totalBytes` |
| `template list` | `templates[]`, `count` |
| `new <tool>/<profile> ...` | `state`, `profile` |
| `rename <tool>/<old> <tool>/<new>` | `state`, `from`, `profile` |

Profile summaries contain `tool`, `name`, `type`, `schemaVersion`, and logical
`sizeBytes`. Tool summaries contain `id`, `kind`, `strategy`, `supportLevel`,
and the boolean `installed`. Arrays are sorted by tool and profile or template
name. Sizes count regular-file bytes without following symbolic links.

Mutation profile summaries contain only `tool`, `name`, `type`, and
`schemaVersion`; they never include logical size or private metadata. A
successful `new` or `rename` returns `state: "applied"`. A failed mutation
returns `data: null` and one of these values in `error.details.state`:

| State | Meaning |
|---|---|
| `not_applied` | The addressed profile tree was not created or moved. |
| `partially_applied` | The profile tree exists at the new address, but a later integration such as alias recreation failed. |

Consumers must reconcile `partially_applied` through a fresh `list` or
`status` query. Nini Agents does not automatically delete or move the profile
again because that could destroy recoverable state.

`doctor --deep` does not yet have a JSON representation. Mutation commands
other than `new` and `rename`, plus profile movement, reject `--json` with
`json_unsupported` before doing work. Movement remains an internal engine API
until a real process probe and a transport can satisfy the transactional
protocol.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | The command completed, and a mutation was applied when requested. |
| `2` | Invalid arguments, invalid identifiers, an address conflict, or unsupported JSON. |
| `6` | A dependency, health check, or mutation integration prevented a complete result. |

Public query error codes in v1 include `invalid_arguments`,
`json_unsupported`, `dependency_missing`, `health_check_failed`, and
`operation_failed`. Profile mutations additionally use `invalid_identifier`,
`profile_not_found`, `profile_exists`, and `cross_tool_rename`.

The internal movement serializer uses the same envelope and preserves every
engine `code`, `state`, and `format`. It never emits source/destination paths,
profile IDs, operation IDs, callback details, credential filenames, hashes, or
credential content. This serializer is not a public `move` command.

## Data boundary and compatibility

User-chosen tool, profile, and template names are public addressing fields for
these commands. Nini Agents does not read credential contents to build JSON and
does not expose `.profile.json`'s `profileId`, absolute paths, binary paths,
tokens, account identifiers, hashes, or private runtime details.

Consumers may rely on documented fields for `schemaVersion: 1`. New optional
fields may be added within v1. Removing a field, changing its type or meaning,
or changing envelope semantics requires a new schema version. Human text is a
separate compatibility surface and must not be parsed by consumers.
