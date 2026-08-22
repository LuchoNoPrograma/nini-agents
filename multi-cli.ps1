<# Temporary compatibility shim. The Nini Agents engine lives in nini-agents.ps1. #>
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot 'nini-agents.ps1'

if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Nini Agents launcher not found: $launcher"
}

& $launcher @args
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
