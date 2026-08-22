$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:CanonicalLauncher = Join-Path $script:RepoRoot 'nini-agents.ps1'
$script:CompatibilityLauncher = Join-Path $script:RepoRoot 'multi-cli.ps1'

function Invoke-BrandingLauncher {
    param([string]$Path, [string[]]$Arguments)
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

Describe 'Nini Agents entrypoint compatibility' {
    It 'uses nini-agents as the canonical PowerShell identity' {
        $result = Invoke-BrandingLauncher -Path $script:CanonicalLauncher -Arguments @('version')
        $result.ExitCode | Should Be 0
        $result.Output.Trim() | Should Be 'nini-agents 1.0.0'
    }

    It 'delegates the multi-cli PowerShell shim without changing output' {
        $canonical = Invoke-BrandingLauncher -Path $script:CanonicalLauncher -Arguments @('help')
        $compatibility = Invoke-BrandingLauncher -Path $script:CompatibilityLauncher -Arguments @('help')
        $canonical.ExitCode | Should Be 0
        $compatibility.ExitCode | Should Be 0
        $compatibility.Output | Should Be $canonical.Output
    }

    It 'registers completion for canonical and compatibility commands' {
        $result = Invoke-BrandingLauncher -Path $script:CanonicalLauncher -Arguments @('completion', 'powershell')
        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'CommandName nini-agents,multi-cli'
    }
}
