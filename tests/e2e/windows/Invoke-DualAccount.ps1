param(
    [Parameter(Mandatory = $true)]
    [string]$Manifest,

    [switch]$Protected
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Protected) { throw 'Protected dual-account E2E requires the explicit -Protected switch.' }
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath)))
$repoFull = [System.IO.Path]::GetFullPath($repoRoot)
$manifestFull = [System.IO.Path]::GetFullPath($Manifest)
if ($manifestFull.StartsWith($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The local account manifest must live outside the repository.'
}
if (-not (Test-Path -LiteralPath $manifestFull)) { throw "Manifest not found: $manifestFull" }
$config = Get-Content -LiteralPath $manifestFull -Raw | ConvertFrom-Json

foreach ($field in @('tool', 'profilesRoot', 'profileA', 'profileB', 'binary', 'workspace', 'evidenceDirectory')) {
    if (-not $config.PSObject.Properties[$field] -or -not $config.$field) { throw "Manifest field '$field' is required." }
}
if ($config.profileA -eq $config.profileB) { throw 'profileA and profileB must differ.' }
if ($config.profileA -eq 'base' -or $config.profileB -eq 'base') { throw 'Protected E2E cannot use the base profile.' }
if (-not (Test-Path -LiteralPath $config.binary -PathType Leaf)) { throw 'The pinned real binary does not exist.' }
$evidenceFull = [System.IO.Path]::GetFullPath($config.evidenceDirectory)
if ($evidenceFull.StartsWith($repoFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Evidence must be written outside the repository.'
}

$profileAPath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $config.profilesRoot $config.tool) $config.profileA))
$profileBPath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $config.profilesRoot $config.tool) $config.profileB))
if ($profileAPath -eq $profileBPath) { throw 'Account profile paths resolve to the same directory.' }
if (-not (Test-Path -LiteralPath $profileAPath) -or -not (Test-Path -LiteralPath $profileBPath)) {
    throw 'Both account profiles must already exist and be authenticated interactively.'
}

$credentialEnvironmentVariables = @(
    'OPENAI_API_KEY', 'CODEX_ACCESS_TOKEN', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN',
    'CLAUDE_CODE_OAUTH_TOKEN', 'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'GOOGLE_APPLICATION_CREDENTIALS',
    'GH_TOKEN', 'GITHUB_TOKEN', 'COPILOT_GITHUB_TOKEN', 'XAI_API_KEY', 'KIMI_MODEL_API_KEY'
)
foreach ($name in $credentialEnvironmentVariables) {
    if ([Environment]::GetEnvironmentVariable($name, 'Process')) {
        throw "Clear inherited credential environment variable '$name' before protected E2E."
    }
}

Write-Host 'Protected preflight passed.'
Write-Host 'The product driver must now prove two distinct vendor identities, overlapping live processes, independent quota attribution, shared conversation visibility, and logout isolation.'
Write-Host 'No authenticated driver is marked verified until those product-specific assertions are implemented and produce secret-scanned evidence.'
exit 4
