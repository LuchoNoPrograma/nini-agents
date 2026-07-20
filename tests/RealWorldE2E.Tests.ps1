<#
.SYNOPSIS
  Pester 3.4 suite driving the real-world E2E harness (tests/e2e/windows).
  Runs the harness against the ALWAYS-installed tools with real binaries,
  real profiles, and a sandboxed home, then parses the sanitized evidence
  JSON and asserts every per-tool assertion passed -- or that an explicit
  SKIP with a reason was recorded. No truthiness-only checks.
#>

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:HarnessPath = Join-Path $script:RepoRoot 'tests\e2e\windows\Invoke-RealWorldE2E.ps1'
$script:RequiredTools = @('kimi-cli', 'claude-cli', 'codex', 'gemini-cli', 'commandcode')
$script:ExpectedMechanism = @{
    'kimi-cli'    = 'processSecret'
    'claude-cli'  = 'fileOverlay'
    'codex'       = 'fileOverlay'
    'gemini-cli'  = 'fileOverlay'
    'commandcode' = 'inseparable'
}
# Assertion names the harness must record (and pass) per mechanism.
$script:ExpectedAssertions = @{
    'fileOverlay' = @(
        'binary-resolved', 'direct-version-captured', 'profiles-created',
        'launch-exit-zero-account-a', 'launch-exit-zero-account-b',
        'version-matches-direct-binary-account-a', 'version-matches-direct-binary-account-b',
        'credential-files-profile-local-empty', 'credential-hardlinks-point-to-profile-auth',
        'shared-state-seed-visible-in-both-profiles', 'runtime-links-into-shared-root',
        'shared-session-visible-across-profiles',
        'doctor-deep-clean-after-launch', 'doctor-deep-flags-rogue-file',
        'doctor-deep-clean-after-rogue-removal'
    )
    'processSecret' = @(
        'binary-resolved', 'direct-version-captured', 'profiles-created',
        'auth-set-account-a', 'auth-set-account-b',
        'auth-status-present-account-a', 'auth-status-present-account-b',
        'launch-exit-zero-account-a', 'launch-exit-zero-account-b',
        'version-matches-direct-binary-account-a', 'version-matches-direct-binary-account-b',
        'profile-token-captured-account-a', 'profile-token-captured-account-b',
        'profile-tokens-differ', 'shared-state-seed-intact',
        'auth-clear-account-a', 'auth-clear-account-b',
        'launch-fails-after-auth-clear', 'no-runtime-overlay-built'
    )
    'inseparable' = @(
        'binary-resolved', 'direct-version-captured', 'profiles-created',
        'launch-refused-by-design', 'no-runtime-overlay-built'
    )
}
$script:ExpectedSafetyAssertions = @(
    'child-env-sandboxed', 'credential-manager-clean',
    'registry-user-path-unchanged', 'real-home-unchanged', 'evidence-secret-scan'
)

function Get-ToolAssertion {
    param($ToolEntry, [string]$Name)
    return @($ToolEntry.assertions | Where-Object { $_.name -eq $Name } | Select-Object -First 1)[0]
}

Describe 'Real-world E2E harness (real binaries, sandboxed home)' {
    $script:EvidenceDir = Join-Path ([System.IO.Path]::GetTempPath()) ('mcli_e2e_evidence_' + [guid]::NewGuid().ToString('N'))
    $script:SandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('mcli_e2e_sandbox_' + [guid]::NewGuid().ToString('N'))
    $script:HarnessLog = Join-Path ([System.IO.Path]::GetTempPath()) ('mcli_e2e_harness_' + [guid]::NewGuid().ToString('N') + '.log')

    It 'runs the harness to exit code 0 and produces an evidence file' {
        # powershell.exe -File binds one token per parameter; the harness
        # normalizes the comma-joined form itself.
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:HarnessPath,
            '-Tool', ($script:RequiredTools -join ','),
            '-EvidenceDir', $script:EvidenceDir,
            '-SandboxRoot', $script:SandboxRoot
        )
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = (Get-Command powershell.exe).Source
        $startInfo.Arguments = ($arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        ($stdout + "`n" + $stderr) | Set-Content -LiteralPath $script:HarnessLog -Encoding UTF8

        $script:EvidencePath = Join-Path $script:EvidenceDir 'realworld-evidence.json'
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $script:EvidencePath)) {
            Write-Host '----- harness output (tail) -----'
            ($stdout + $stderr) -split "`r?`n" | Select-Object -Last 60 | ForEach-Object { Write-Host $_ }
        }
        $process.ExitCode | Should Be 0
        (Test-Path -LiteralPath $script:EvidencePath -PathType Leaf) | Should Be $true
        $script:EvidenceRaw = Get-Content -LiteralPath $script:EvidencePath -Raw
        $script:Evidence = $script:EvidenceRaw | ConvertFrom-Json
        $script:Evidence.schemaVersion | Should Be 1
        $script:Evidence.harness | Should Be 'Invoke-RealWorldE2E'
        $script:Evidence.overallStatus | Should Be 'pass'
    }

    foreach ($toolId in $script:RequiredTools) {
        It "[$toolId] records pass with every assertion green, or an explicit skip with reason" {
            $toolEntry = $script:Evidence.tools.$toolId
            if ($null -eq $toolEntry) { throw "Evidence has no entry for required tool '$toolId'." }
            @('pass', 'skip') -contains $toolEntry.status | Should Be $true
            if ($toolEntry.status -eq 'skip') {
                ($toolEntry.skipReason -match '\S') | Should Be $true
                Set-TestInconclusive "$toolId SKIP (recorded explicitly): $($toolEntry.skipReason)"
                return
            }
            $toolEntry.mechanism | Should Be $script:ExpectedMechanism[$toolId]
            ($toolEntry.binaryVersion -match '\d') | Should Be $true
            $expected = $script:ExpectedAssertions[$toolEntry.mechanism]
            foreach ($name in $expected) {
                $assertion = Get-ToolAssertion $toolEntry $name
                if ($null -eq $assertion) { throw "[$toolId] missing assertion '$name' in evidence." }
                if (-not $assertion.passed) { throw "[$toolId] assertion '$name' FAILED: $($assertion.detail)" }
                $assertion.passed | Should Be $true
            }
            $unexpectedFailures = @($toolEntry.assertions | Where-Object { -not $_.passed })
            $unexpectedFailures.Count | Should Be 0
        }
    }

    It 'passes every safety invariant' {
        foreach ($name in $script:ExpectedSafetyAssertions) {
            $assertion = @($script:Evidence.safety.assertions | Where-Object { $_.name -eq $name } | Select-Object -First 1)[0]
            if ($null -eq $assertion) { throw "Missing safety assertion '$name' in evidence." }
            if (-not $assertion.passed) { throw "Safety assertion '$name' FAILED: $($assertion.detail)" }
            $assertion.passed | Should Be $true
        }
    }

    It 'writes sanitized evidence (no username, no tokens, no real-home paths)' {
        ($script:EvidenceRaw -match [regex]::Escape($env:USERNAME)) | Should Be $false
        ($script:EvidenceRaw -match '(?i)dummy-token') | Should Be $false
        ($script:EvidenceRaw -match [regex]::Escape($env:USERPROFILE)) | Should Be $false
    }

    It 'removes the sandbox after the run' {
        (Test-Path -LiteralPath $script:SandboxRoot) | Should Be $false
    }

    It 'cleans up its own evidence directory and harness log' {
        Remove-Item -LiteralPath $script:EvidenceDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:HarnessLog -Force -ErrorAction SilentlyContinue
        (Test-Path -LiteralPath $script:EvidenceDir) | Should Be $false
        (Test-Path -LiteralPath $script:HarnessLog) | Should Be $false
    }
}
