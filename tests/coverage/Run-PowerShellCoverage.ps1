<# Runs the full Pester suite and changed-line coverage in one pass. #>
param(
    [ValidateRange(0, 100)][double]$MinimumPercent = 90,
    [string[]]$TestPath
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Invoke-ModuleCoverage.ps1') -MinimumPercent $MinimumPercent -TestPath $TestPath
exit $LASTEXITCODE
