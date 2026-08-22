<#
.SYNOPSIS
  Runs the nini-agents session-continuation Pester suite (Pester 3.4 compatible).

.DESCRIPTION
  One documented command:
      powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-pester.ps1

  Discovers the hermetic Pester *.Tests.ps1 files in this directory and runs
  them. The opt-in RealWorldE2E suite is excluded because missing vendor
  binaries must not count as a passing CI gate. -CI additionally fails when
  any test is skipped, pending, or inconclusive. Requires Pester 3.x (>=3.4,
  <4).
#>

param(
    [switch]$CI,
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition

# This suite is written in Pester 3.x syntax (legacy Should Be / Should Match /
# Should Throw, helpers dot-sourced at file top). Load a 3.x deterministically:
# drop any already-imported Pester first, then import the highest 3.x available.
# Do NOT pin an exact build -- dev boxes ship a built-in 3.4.x that is not 3.4.0.
Get-Module Pester | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module Pester -MinimumVersion 3.4.0 -MaximumVersion 3.99.99 -Force -ErrorAction Stop

$pesterVersion = (Get-Module Pester).Version
if (-not $pesterVersion -or $pesterVersion.Major -ne 3) {
    throw "Pester 3.x is required but none was loaded (got '$pesterVersion'). Install with: Install-Module Pester -RequiredVersion 3.4.0 -Force -SkipPublisherCheck -Scope CurrentUser"
}
Write-Host "Using Pester $pesterVersion"

if ($Path) {
    $testFiles = @($Path | ForEach-Object {
        if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $here $_ }
    })
} else {
    $testFiles = Get-ChildItem -Path $here -Filter '*.Tests.ps1' |
        Where-Object { $_.Name -ne 'RealWorldE2E.Tests.ps1' } |
        ForEach-Object { $_.FullName }
}

$result = Invoke-Pester -Path $testFiles -PassThru
$failed = $result.FailedCount
$unexecuted = $result.SkippedCount + $result.PendingCount + $result.InconclusiveCount

if ($failed -gt 0 -or ($CI -and $unexecuted -gt 0)) { exit 1 }

# Sweep temp def files this run dot-sourced (one per child PowerShell that imported
# the launcher). Best-effort; never fail the run on cleanup.
Get-ChildItem ([System.IO.Path]::GetTempPath()) -Filter 'mcli_defs_*.ps1' -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

exit 0
