# Machine-safe exec contract

`nini-agents exec` runs a profile-backed foreground child without adding human
launcher output to its standard streams. It exists for local consumers whose
protocol owns stdout, such as Codex app-server JSON-RPC.

```bash
nini-agents exec codex/work -- app-server --stdio
```

## Supported boundary

The v1 contract accepts only adapters with all of these properties:

- `isolation.strategy` is `accountOverlay`;
- `account.mechanism` is `fileOverlay`;
- `isolation.mode` is `foreground`.

Schema-v2 overlays and legacy whole-root file-overlay profiles are supported.
Detached adapters and other account mechanisms fail before the child starts.
This restriction prevents consumers from assuming transparent process control
for GUI, OS-user, secret-store, or background launch paths that have not been
characterized.

## Process and stream behavior

- The first outer `--` separates launcher arguments from child arguments and is
  not forwarded.
- The child receives the same adapter environment, cleared variables, runtime
  overlay, binary resolution, and enforced arguments as human `launch`.
- On a successful spawn, stdout and stderr contain only child bytes. stdin is
  inherited by the child.
- Preflight failures are written to stderr and exit with code 1 before spawn.
- Foreground child exit codes are propagated unchanged.
- On Bash, the launcher uses process replacement, so the observed launcher PID
  becomes the child PID and signals target the owned child directly.
- On Windows PowerShell, the launcher remains the foreground supervisor, gives
  the child inherited standard handles, waits for it, and propagates its exit
  code. A desktop consumer that force-cancels on Windows must terminate the
  supervised process tree.

`exec` is not part of the JSON v1 envelope. Consumers must not combine it with
the global `--json` mode or parse human `launch` output as a substitute.

## Data and credential safety

The command may create or rebuild the adapter-declared `.runtime` overlay, as a
normal launch does. It does not serialize paths, metadata, tokens, credential
contents, or runtime plans. Credential files stay behind the file-overlay
boundary and the child receives only the adapter-owned runtime view.
