<#
.SYNOPSIS
  Entry point for the PowerShell coverage gate.

.DESCRIPTION
  Delegates to Invoke-ModuleCoverage.ps1, which runs the Pester 3.x suite
  in-process against lib/*.psm1, applies the documented-exception list, writes
  JSON and Cobertura reports, and exits nonzero on test, module, or changed-line
  coverage failures.

  USAGE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests/coverage/Run-PowerShellCoverage.ps1 [-MinimumPercent 95]
#>

param(
    [double]$MinimumPercent = 95
)

$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Invoke-ModuleCoverage.ps1') -MinimumPercent $MinimumPercent
exit $LASTEXITCODE
