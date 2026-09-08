# Shared policy for the ordinary runner and the instrumented runner.
function Get-PesterRunPolicy {
    param($Result, [switch]$Report)
    $platformSkips = @{
        'fails precisely BEFORE creating anything when not elevated' = 'Requires a non-elevated Windows process.'
        'stops at the elevation gate for an owned record when not elevated' = 'Requires a non-elevated Windows process.'
        'Remove-RuntimeOverlay deletes reparse-point files without following them' = 'Requires file-symlink privileges.'
    }
    $expected = @()
    $unexpected = @()
    foreach ($test in $Result.TestResult) {
        if ($test.Result -eq 'Skipped' -and $platformSkips.ContainsKey($test.Name)) {
            $reason = $platformSkips[$test.Name]
            $expected += [ordered]@{ name = $test.Name; reason = $reason }
            if ($Report) { Write-Host "Platform skip: $($test.Name) -- $reason" }
        } elseif ($test.Result -in @('Skipped', 'Pending', 'Inconclusive')) {
            $unexpected += [ordered]@{ name = $test.Name; result = $test.Result }
            if ($Report) { Write-Host "Unexpected $($test.Result): $($test.Name)" }
        }
    }
    return [pscustomobject]@{
        total = [int]$Result.TotalCount
        passedCount = [int]$Result.PassedCount
        failed = [int]$Result.FailedCount
        platformSkipped = $expected
        unexpectedUnexecuted = $unexpected
        passed = ($Result.FailedCount -eq 0 -and $Result.PassedCount -gt 0 -and $unexpected.Count -eq 0)
    }
}

function Test-PesterFileSymlink {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('mcli_symlink_probe_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
    try {
        $target = Join-Path $root 'target.txt'
        [System.IO.File]::WriteAllText($target, 'fixture')
        try {
            New-Item -ItemType SymbolicLink -Path (Join-Path $root 'link.txt') -Target $target -ErrorAction Stop | Out-Null
            return $true
        } catch {
            # Do not turn disk, path, or unexpected runtime failures into skips.
            if ($_.Exception -is [UnauthorizedAccessException] -or
                $_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::PermissionDenied -or
                ($_.Exception.HResult -band 65535) -in @(5, 1314)) { return $false }
            throw
        }
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
