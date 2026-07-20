<#
.SYNOPSIS
  Runs the in-process Pester coverage gate for the lib/*.psm1 modules.

.DESCRIPTION
  Pester 3.4's -CodeCoverage only counts commands executed in its own
  runspace, so the suite is built around tests/ModuleFunctions.Tests.ps1,
  which imports the three modules and drives their functions in-process.
  tests/OverlayState.Tests.ps1 runs alongside as the end-to-end check that
  the launcher still wires the same modules correctly from child processes
  (its child-process execution contributes no coverage by itself).

  Prints per-module and total command coverage, writes a JSON summary to
  tests/coverage/out/powershell-coverage.json (counts only, no secrets),
  and exits 1 when any test fails or total coverage is below -MinimumPercent.

  Documented exceptions: commands listed in $script:DocumentedExceptions are
  provably uncoverable on this host (no file-symlink privilege) and are each
  covered by an inconclusive-marked test that exercises them on privileged
  hosts. They are exempt from the miss check and recorded in the JSON
  summary's documentedExceptions field. The gate fails when ANY other command
  is missed, and also when a listed exception no longer matches a missed
  command (stale exception - remove it).

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests/coverage/Invoke-ModuleCoverage.ps1 [-MinimumPercent 95]
#>

param(
    [double]$MinimumPercent = 95,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$coverageRoot = $PSScriptRoot
$testsRoot = Split-Path -Parent $coverageRoot
$repoRoot = Split-Path -Parent $testsRoot
if (-not $OutputPath) { $OutputPath = Join-Path $coverageRoot 'out\powershell-coverage.json' }

# Same Pester pinning as tests/run-pester.ps1: the suite is 3.x syntax only.
Get-Module Pester | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module Pester -MinimumVersion 3.4.0 -MaximumVersion 3.99.99 -Force -ErrorAction Stop
$pesterVersion = (Get-Module Pester).Version
if (-not $pesterVersion -or $pesterVersion.Major -ne 3) {
    throw "Pester 3.x is required but none was loaded (got '$pesterVersion')."
}
Write-Host "Using Pester $pesterVersion"

$testFiles = @(
    (Join-Path $testsRoot 'ModuleFunctions.Tests.ps1'),
    (Join-Path $testsRoot 'Migration.Tests.ps1'),
    (Join-Path $testsRoot 'TransferSafety.Tests.ps1'),
    (Join-Path $testsRoot 'OverlayState.Tests.ps1')
)

# Commands that cannot execute on this host, matched against Pester's missed
# commands by module file name and normalized command text (not line numbers,
# so module edits do not stale them by position alone). Each entry must name
# the inconclusive-marked test that covers the command on privileged hosts.
$script:DocumentedExceptions = @(
    [ordered]@{
        file = 'MultiCli.Runtime.psm1'
        command = '[System.IO.File]::Delete($reparsePoint.FullName)'
        reason = 'Exercising file-reparse-point removal in Remove-RuntimeOverlay requires a file symlink; this host grants no symlink privilege (directory junctions only). The covering test ''Remove-RuntimeOverlay deletes reparse-point files without following them'' in tests/ModuleFunctions.Tests.ps1 is marked inconclusive here and exercises the branch on privileged hosts.'
    }
)

function Get-NormalizedCommandText {
    param([string]$Text)
    return ($Text -replace '\s+', ' ').Trim()
}
foreach ($testFile in $testFiles) {
    if (-not (Test-Path -LiteralPath $testFile)) { throw "Missing test file: $testFile" }
}
$moduleFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'lib') -Filter '*.psm1' | ForEach-Object { $_.FullName })
if ($moduleFiles.Count -eq 0) { throw "No lib/*.psm1 modules found under $repoRoot." }

$result = Invoke-Pester -Script $testFiles -CodeCoverage $moduleFiles -PassThru -Quiet

Write-Host ""
Write-Host "Tests: $($result.PassedCount) passed, $($result.FailedCount) failed, $($result.TotalCount) total"
if ($result.FailedCount -gt 0) {
    foreach ($failed in @($result.TestResult | Where-Object { $_.Result -eq 'Failed' })) {
        Write-Host "  FAILED: $($failed.Name)"
        Write-Host "    $($failed.FailureMessage)"
    }
}

$coverage = $result.CodeCoverage
if (-not $coverage -or $coverage.NumberOfCommandsAnalyzed -eq 0) {
    throw 'Pester returned no code-coverage data; the modules were not analyzed.'
}

$perModule = @{}
foreach ($command in @($coverage.HitCommands) + @($coverage.MissedCommands)) {
    $name = Split-Path -Leaf $command.File
    if (-not $perModule.ContainsKey($name)) {
        $perModule[$name] = [pscustomobject]@{ Name = $name; Analyzed = 0; Executed = 0 }
    }
    $perModule[$name].Analyzed++
}
foreach ($command in @($coverage.HitCommands)) {
    $perModule[(Split-Path -Leaf $command.File)].Executed++
}

$moduleSummaries = @()
Write-Host ""
Write-Host 'Module coverage:'
foreach ($moduleFile in $moduleFiles) {
    $name = Split-Path -Leaf $moduleFile
    if (-not $perModule.ContainsKey($name)) { throw "Coverage data missing for $name." }
    $entry = $perModule[$name]
    $percent = [math]::Round(100.0 * $entry.Executed / $entry.Analyzed, 2)
    $moduleSummaries += [ordered]@{
        name = $name
        analyzed = $entry.Analyzed
        executed = $entry.Executed
        missed = ($entry.Analyzed - $entry.Executed)
        percent = $percent
    }
    Write-Host ("  {0,-36} {1,6}%  ({2}/{3})" -f $name, $percent, $entry.Executed, $entry.Analyzed)
}

$totalAnalyzed = $coverage.NumberOfCommandsAnalyzed
$totalExecuted = $coverage.NumberOfCommandsExecuted
$totalMissed = $coverage.NumberOfCommandsMissed
$totalPercent = [math]::Round(100.0 * $totalExecuted / $totalAnalyzed, 2)
Write-Host ("  {0,-36} {1,6}%  ({2}/{3})" -f 'TOTAL', $totalPercent, $totalExecuted, $totalAnalyzed)

if ($totalMissed -gt 0) {
    Write-Host ""
    Write-Host "Missed commands ($totalMissed):"
    $shown = 0
    foreach ($missed in @($coverage.MissedCommands)) {
        if ($shown -ge 30) { Write-Host "  ... and $($totalMissed - $shown) more"; break }
        Write-Host ("  {0}:{1} [{2}] {3}" -f (Split-Path -Leaf $missed.File), $missed.Line, $missed.Function, $missed.Command)
        $shown++
    }
}

# Partition missed commands into documented exceptions and unexpected misses.
$missedCommands = @($coverage.MissedCommands)
$exemptedCommands = @()
$exceptionReports = @()
foreach ($exception in $script:DocumentedExceptions) {
    $matches = @($missedCommands | Where-Object {
        (Split-Path -Leaf $_.File) -eq $exception.file -and
        (Get-NormalizedCommandText $_.Command) -eq (Get-NormalizedCommandText $exception.command)
    })
    $exceptionReports += [ordered]@{
        file = $exception.file
        command = $exception.command
        reason = $exception.reason
        active = ($matches.Count -gt 0)
    }
    if ($matches.Count -gt 0) { $exemptedCommands += $matches[0] }
}
$unexpectedMisses = @($missedCommands | Where-Object { $exemptedCommands -notcontains $_ })
$staleExceptions = @($exceptionReports | Where-Object { -not $_.active })

Write-Host ""
Write-Host "Documented exceptions: $($exceptionReports.Count) listed, $(@($exceptionReports | Where-Object { $_.active }).Count) active, $($staleExceptions.Count) stale"
foreach ($report in $exceptionReports) {
    $state = if ($report.active) { 'active (missed here, covered on privileged hosts)' } else { 'STALE (no longer missed; remove it)' }
    Write-Host "  $($report.file): $($report.command) - $state"
}
Write-Host "Unexpected missed commands: $($unexpectedMisses.Count)"
foreach ($missed in $unexpectedMisses) {
    Write-Host ("  {0}:{1} [{2}] {3}" -f (Split-Path -Leaf $missed.File), $missed.Line, $missed.Function, $missed.Command)
}

$summary = [ordered]@{
    generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    pesterVersion = $pesterVersion.ToString()
    minimumPercent = $MinimumPercent
    total = [ordered]@{
        analyzed = $totalAnalyzed
        executed = $totalExecuted
        missed = $totalMissed
        percent = $totalPercent
    }
    modules = $moduleSummaries
    documentedExceptions = @($exceptionReports)
    unexpectedMissed = $unexpectedMisses.Count
    tests = [ordered]@{
        total = [int]$result.TotalCount
        passed = [int]$result.PassedCount
        failed = [int]$result.FailedCount
    }
    passed = ($result.FailedCount -eq 0 -and $totalPercent -ge $MinimumPercent -and $unexpectedMisses.Count -eq 0 -and $staleExceptions.Count -eq 0)
}
$summaryDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $summaryDirectory)) {
    New-Item -ItemType Directory -Force -Path $summaryDirectory | Out-Null
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host ""
Write-Host "Coverage summary written to $OutputPath"

if ($result.FailedCount -gt 0) { exit 1 }
if ($unexpectedMisses.Count -gt 0) {
    Write-Host "Coverage gate FAILED: $($unexpectedMisses.Count) missed command(s) outside the documented exceptions."
    exit 1
}
if ($staleExceptions.Count -gt 0) {
    Write-Host "Coverage gate FAILED: $($staleExceptions.Count) documented exception(s) no longer match a missed command; remove them from `$script:DocumentedExceptions."
    exit 1
}
if ($totalPercent -lt $MinimumPercent) {
    Write-Host "Coverage gate FAILED: $totalPercent% is below $MinimumPercent%."
    exit 1
}
Write-Host "Coverage gate passed: $totalPercent% >= $MinimumPercent%."
exit 0
