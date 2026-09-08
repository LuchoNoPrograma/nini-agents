# Testing

## Hermetic suites

```bash
bash tests/run-bats.sh
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-pester.ps1
```

These invoke the real Bash and PowerShell launchers against disposable filesystem trees. Schema-v2 tests assert profile metadata, auth-file separation, shared normal-state links, inherited-auth clearing, invalid-adapter failure, and legacy session-copy safety.

## Adapter validation

Run both validators on every platform:

```bash
bash scripts/validate-adapters.sh
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Validate-Adapters.ps1
```

## Real binary offline smoke

On Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tests/e2e/windows/Invoke-VendorSmoke.ps1 `
  -Tool codex `
  -EvidenceDirectory "$env:TEMP\nini-agents-evidence"
```

This only proves binary identity/version. It emits allowlisted, secret-scanned evidence and does not prove account isolation.

## Protected dual-account verification

`tests/e2e/windows/Invoke-DualAccount.ps1` is deliberately fail-closed. It requires:

- explicit `-Protected`;
- a local manifest outside the repository;
- two already authenticated disposable profiles;
- a pinned real binary;
- evidence outside the repository;
- no inherited credential environment variables.

Product drivers must prove distinct account identity, overlapping processes, independent quota attribution, shared conversation visibility, shared configuration, and logout isolation before a platform row can carry the `supported` level for that mode. Raw stdout/stderr, account IDs, emails, tokens, prompts, responses, credential databases, and absolute account paths must never enter evidence.

## Coverage

Changed instrumented production lines require 90% coverage by default. Aggregate
and per-module percentages are diagnostic: they do not require 100%, and untouched
modules do not block a change because of their aggregate percentage. Missing
coverage for a changed file in the instrumented scope still fails the gate.

Bash measures the launchers and production shell files. Pester 3.x measures
`lib/*.psm1` in its own process; child launchers, including `nini-agents.ps1`, are
outside that percentage and must be checked through their behavioral CLI suites.
Do not interpret module coverage as coverage of the entire Windows CLI.

```bash
bash tests/coverage/run-bash-coverage.sh
# Focus on the changed area; Bats arguments are forwarded:
COVERAGE_BASELINE=HEAD bash tests/coverage/run-bash-coverage.sh tests/move_safety.bats
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-pester.ps1 -CI -Coverage
# Equivalent full-suite entrypoint:
powershell -NoProfile -ExecutionPolicy Bypass -File tests/coverage/Run-PowerShellCoverage.ps1
# Focused module run:
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-pester.ps1 -CI -Coverage -Path MoveSafety.Tests.ps1
```

Both gates execute tests and collect coverage in one pass. CI runs the Windows
suite once. Linux runs the functional suite once under Bashcov and runs launch
performance separately without instrumentation. macOS runs its platform suite.

Bash coverage requires Bashcov, Ruby, and Python 3; CI uses pinned Bashcov 3.3.0
and SimpleCov 0.22.0. PowerShell coverage requires Pester 3.x (at least 3.4).
Both gates use `COVERAGE_BASELINE` or `HEAD^` and write reports under the system
temporary directory (`multi-cli-coverage`) by default. Missing tools must be
reported as an unexecuted coverage check, never as a passing result.

## Useful tests and platform skips

- A new case must identify the observable regression it detects and the extra
  protection it provides. Share fixtures or use parameterized inputs; do not join
  independent scenarios just to reduce the displayed test count.
- Preserve explicit assertions for credentials, isolation, path containment,
  ownership, integrity, and rollback. Review uncovered branches in these areas
  and use targeted mutation checks when useful; a percentage alone is insufficient.
- Prefer assertions on actual output and resulting state. Avoid checking files
  written solely by the test or fixing an internal call count without a requirement.
- Consolidate duplicated contracts within a platform. Bash and PowerShell are
  separate implementations and need their own evidence.
- For ordinary changes, stop after the affected checks pass unless failures or
  new changes justify more testing. Run the full platform suites in CI.

The two non-admin OS-user refusal tests are explicitly skipped on elevated hosts.
The file-symlink deletion test is explicitly skipped when the host lacks the
required permission. These three names and reasons are recorded by
`tests/helpers/pester-policy.ps1`; all other skips, pending and inconclusive
results fail `-CI` and coverage runs. Failed tests always fail. An empty run or a
run with no passed tests cannot pass the strict policy. Platform skips remain
visible and do not count as passed tests or provide evidence for that capability;
verify the corresponding behavior on a capable host before claiming support.

Transactional profile movement has dedicated hermetic suites. They use only
synthetic JSON and disposable roots, with injected process probes and
transports:

```bash
bash tests/run-bats.sh tests/move_safety.bats
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-pester.ps1 -Path MoveSafety.Tests.ps1
```

These suites never contact another machine or inspect a real credential store.

Stable JSON output has dedicated hermetic suites. They build profiles and
templates only beneath disposable homes and assert both the envelope and the
absence of credential values, private metadata IDs, and absolute paths:

```bash
bash tests/run-bats.sh tests/json_cli.bats
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-pester.ps1 -Path JsonCli.Tests.ps1
```
