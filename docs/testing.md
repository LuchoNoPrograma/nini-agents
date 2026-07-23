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
  -EvidenceDirectory "$env:TEMP\multi-cli-evidence"
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

Changed production lines and every touched PowerShell runtime module require at least 95% coverage. Bash changed-line coverage is enforced at 95%; Bashcov's aggregate report remains diagnostic because Bats launches production Bash in isolated processes and several platform-specific branches cannot execute on one Linux host. Credential, validation, path-safety, overlay, migration, and process-spawn branches may not be excluded from changed-line coverage. A missing local coverage tool is a blocker to a verified completion claim, not a reason to lower the bar.

```bash
bash tests/coverage/run-bash-coverage.sh
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/coverage/Run-PowerShellCoverage.ps1
```

The Bash gate requires Bashcov, Ruby, and Python 3. CI installs the checksum-verified Bashcov 3.3.0 gem; Bashcov supports Bats and tracks nested Bash processes without kcov's Bats/xtrace incompatibilities. The PowerShell gate requires Pester 3.4.

Both gates read `COVERAGE_BASELINE` when CI supplies it and otherwise compare with `HEAD^`. They write machine-readable changed-line reports under `tests/coverage/out/` and fail when a changed production file has no coverage data.
