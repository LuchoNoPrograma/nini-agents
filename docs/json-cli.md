# JSON CLI contract

Nini Agents exposes a versioned JSON interface for read-only consumers. Human
output remains the default and is unchanged. Put `--json` before the first `--`
delimiter; both of these forms are equivalent:

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

## Supported queries

| Command | Stable `data` fields |
|---|---|
| `version` | `product`, `version` |
| `list [tool]`, `status [tool]` | `profiles[]`, `count` |
| `tools` | `platform`, `tools[]`, `count` |
| `doctor` | `platform`, `storage`, `aliasDirectoryOnPath`, `tools[]` |
| `stats` | `profiles[]`, `count`, `totalBytes` |
| `template list` | `templates[]`, `count` |

Profile summaries contain `tool`, `name`, `type`, `schemaVersion`, and logical
`sizeBytes`. Tool summaries contain `id`, `kind`, `strategy`, `supportLevel`,
and the boolean `installed`. Arrays are sorted by tool and profile or template
name. Sizes count regular-file bytes without following symbolic links.

`doctor --deep` does not yet have a JSON representation. Mutation commands and
profile movement reject `--json` with `json_unsupported` before doing work.
Movement remains an internal engine API until a real process probe and a
transport can satisfy the transactional protocol.

## Exit codes

| Code | Meaning |
|---:|---|
| `0` | The query completed. |
| `2` | Invalid arguments or JSON is unsupported for the command. |
| `6` | A dependency or health check prevented a valid result. |

Public query error codes in v1 are `invalid_arguments`, `json_unsupported`,
`dependency_missing`, `health_check_failed`, and `operation_failed`.

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
