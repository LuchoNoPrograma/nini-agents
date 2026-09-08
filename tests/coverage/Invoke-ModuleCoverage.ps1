<#
.SYNOPSIS
  Run Pester once and enforce coverage of changed module lines.
.DESCRIPTION
  Aggregate module coverage is diagnostic. Pester 3.x cannot instrument child
  launchers; nini-agents.ps1 is tested behaviorally, outside this percentage.
#>
param(
    [ValidateRange(0, 100)][double]$MinimumPercent = 90,
    [string]$OutputPath,
    [string]$Baseline = $env:COVERAGE_BASELINE,
    [string[]]$TestPath
)

$ErrorActionPreference = 'Stop'
$coverageRoot = $PSScriptRoot
$testsRoot = Split-Path -Parent $coverageRoot
$repoRoot = Split-Path -Parent $testsRoot
. (Join-Path $testsRoot 'helpers\pester-policy.ps1')
if (-not $OutputPath) {
    $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) 'multi-cli-coverage\powershell-coverage.json'
}
if (-not $Baseline) {
    & git -C $repoRoot rev-parse --verify --quiet 'HEAD^^{commit}' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $Baseline = 'HEAD^' }
    else { throw 'Cannot resolve a coverage baseline. Set COVERAGE_BASELINE explicitly.' }
}
Get-Module Pester | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module Pester -MinimumVersion 3.4.0 -MaximumVersion 3.99.99 -Force -ErrorAction Stop
$pesterVersion = (Get-Module Pester).Version
if (-not $pesterVersion -or $pesterVersion.Major -ne 3) { throw 'Pester 3.x is required.' }
if ($TestPath) {
    $testFiles = @($TestPath | ForEach-Object {
        if ([System.IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $testsRoot $_ }
    })
} else {
    $testFiles = @(Get-ChildItem -LiteralPath $testsRoot -Filter '*.Tests.ps1' |
        Where-Object { $_.Name -ne 'RealWorldE2E.Tests.ps1' } | ForEach-Object { $_.FullName })
}
foreach ($testFile in $testFiles) {
    if (-not (Test-Path -LiteralPath $testFile)) { throw "Missing test file: $testFile" }
}
$moduleFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'lib') -Filter '*.psm1' | ForEach-Object { $_.FullName })
if ($moduleFiles.Count -eq 0) { throw 'No lib/*.psm1 modules found.' }
$result = Invoke-Pester -Script $testFiles -CodeCoverage $moduleFiles -PassThru
$testPolicy = Get-PesterRunPolicy -Result $result -Report
$coverage = $result.CodeCoverage
if (-not $coverage -or $coverage.NumberOfCommandsAnalyzed -eq 0) { throw 'Pester returned no code-coverage data.' }

function Write-PesterCobertura {
    param($Coverage, [string]$Path, [string]$RepositoryRoot)
    $hitLines = @{}
    foreach ($command in @($Coverage.HitCommands)) {
        $hitLines["$($command.File)|$($command.Line)"] = $true
    }
    $commandsByFile = @($Coverage.HitCommands) + @($Coverage.MissedCommands) | Group-Object File
    $settings = New-Object Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = New-Object Text.UTF8Encoding($false)
    $writer = [Xml.XmlWriter]::Create($Path, $settings)
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement('coverage')
        $writer.WriteStartElement('packages')
        $writer.WriteStartElement('package')
        $writer.WriteStartElement('classes')
        foreach ($fileGroup in $commandsByFile) {
            $relativePath = $fileGroup.Name.Substring($RepositoryRoot.Length).TrimStart('\', '/') -replace '\\', '/'
            $writer.WriteStartElement('class')
            $writer.WriteAttributeString('filename', $relativePath)
            $writer.WriteStartElement('lines')
            foreach ($lineGroup in @($fileGroup.Group | Group-Object Line | Sort-Object { [int]$_.Name })) {
                $writer.WriteStartElement('line')
                $writer.WriteAttributeString('number', $lineGroup.Name)
                $hits = if ($hitLines.ContainsKey("$($fileGroup.Name)|$($lineGroup.Name)")) { '1' } else { '0' }
                $writer.WriteAttributeString('hits', $hits)
                $writer.WriteEndElement()
            }
            $writer.WriteEndElement()
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndDocument()
    } finally {
        $writer.Dispose()
    }
}

$moduleSummaries = @()
foreach ($group in (@($coverage.HitCommands) + @($coverage.MissedCommands) | Group-Object File)) {
    $executed = @($coverage.HitCommands | Where-Object { $_.File -eq $group.Name }).Count
    $moduleSummaries += [ordered]@{
        name = Split-Path -Leaf $group.Name
        analyzed = $group.Count
        executed = $executed
        percent = [math]::Round(100.0 * $executed / $group.Count, 2)
    }
}
$totalPercent = [math]::Round(100.0 * $coverage.NumberOfCommandsExecuted / $coverage.NumberOfCommandsAnalyzed, 2)
$summaryDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $summaryDirectory)) { New-Item -ItemType Directory -Force -Path $summaryDirectory | Out-Null }
$coberturaPath = Join-Path $summaryDirectory 'powershell-cobertura.xml'
Write-PesterCobertura -Coverage $coverage -Path $coberturaPath -RepositoryRoot $repoRoot
$changedReportPath = Join-Path $summaryDirectory 'powershell-changed-lines.json'
$changedArguments = @(
    (Join-Path $coverageRoot 'check_changed_coverage.py'),
    '--repo', $repoRoot, '--baseline', $Baseline, '--coverage-root', $coberturaPath,
    '--minimum', $MinimumPercent, '--output', $changedReportPath,
    '--pathspec', 'lib/*.psm1'
)
& python @changedArguments
$changedExitCode = $LASTEXITCODE
$summary = [ordered]@{
    generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    pesterVersion = $pesterVersion.ToString()
    minimumPercent = $MinimumPercent
    total = [ordered]@{
        analyzed = $coverage.NumberOfCommandsAnalyzed
        executed = $coverage.NumberOfCommandsExecuted
        missed = $coverage.NumberOfCommandsMissed
        percent = $totalPercent
    }
    modules = $moduleSummaries
    tests = $testPolicy
    changedLineExitCode = $changedExitCode
    passed = ($testPolicy.passed -and $changedExitCode -eq 0)
}
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Module coverage (informational): $totalPercent%. Report: $OutputPath"
if (-not $summary.passed) { exit 1 }
exit 0
