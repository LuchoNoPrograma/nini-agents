$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LauncherPath = Join-Path $script:RepoRoot 'nini-agents.ps1'

function New-ExecScratch {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("nini_exec_" + [guid]::NewGuid().ToString('N'))
    $home = Join-Path $root 'home'
    $profiles = Join-Path $root 'profiles'
    $tools = Join-Path $root 'tools'
    New-Item -ItemType Directory -Force -Path $home, $profiles, (Join-Path $tools 'fixture') | Out-Null
    return [pscustomobject]@{ Root = $root; Home = $home; Profiles = $profiles; Tools = $tools }
}

function Write-ExecAdapter {
    param($Scratch, [string]$Mode = 'foreground', [string]$Mechanism = 'fileOverlay')
    $adapter = [ordered]@{
        schemaVersion = 2
        id = 'fixture'
        displayName = 'Fixture CLI'
        kind = 'cli'
        binary = [ordered]@{ windows = @('fixture.exe'); macos = @('fixture'); linux = @('fixture') }
        isolation = [ordered]@{
            strategy = 'accountOverlay'
            mode = $Mode
            env = [ordered]@{ FIXTURE_HOME = '{runtimeRoot}' }
            clearEnv = @('GLOBAL_FIXTURE_TOKEN')
        }
        account = [ordered]@{
            mechanism = $Mechanism
            credentialFiles = @('auth.json')
            credentialPrecedence = @('auth.json')
            logoutScope = 'profile'
            reason = 'fixture'
        }
        normalState = [ordered]@{
            root = [ordered]@{ windows = '%USERPROFILE%\.fixture'; macos = '$HOME/.fixture'; linux = '$HOME/.fixture' }
            sharedPaths = @('config.toml')
            sessionPaths = @('sessions')
            filePaths = @('config.toml')
            unsafePaths = @()
        }
        concurrency = [ordered]@{ level = 'multiWriter'; singletonScope = 'none' }
        support = [ordered]@{
            windows = [ordered]@{ level = 'supported'; reason = 'Fixture only.' }
            macos = [ordered]@{ level = 'supported'; reason = 'Fixture only.' }
            linux = [ordered]@{ level = 'supported'; reason = 'Fixture only.' }
        }
    }
    $adapter | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Scratch.Tools 'fixture\adapter.json') -Encoding UTF8
}

function Invoke-ExecProcess {
    param($Scratch, [string[]]$Arguments, [string]$Probe, [string]$StdIn = '')
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command powershell.exe).Source
    $launcherArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:LauncherPath) + @($Arguments)
    $startInfo.Arguments = ($launcherArgs | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['USERPROFILE'] = $Scratch.Home
    $startInfo.EnvironmentVariables['HOME'] = $Scratch.Home
    $startInfo.EnvironmentVariables['APPDATA'] = Join-Path $Scratch.Home 'AppData\Roaming'
    $startInfo.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $Scratch.Home 'AppData\Local'
    $startInfo.EnvironmentVariables['MULTICLI_HOME'] = $Scratch.Profiles
    $startInfo.EnvironmentVariables['MULTICLI_TOOLS_DIR'] = $Scratch.Tools
    if ($Probe) { $startInfo.EnvironmentVariables['MULTICLI_OVERRIDE_BINARY'] = $Probe }
    $startInfo.EnvironmentVariables['GLOBAL_FIXTURE_TOKEN'] = 'parent-secret'
    $process = [System.Diagnostics.Process]::Start($startInfo)
    if ($StdIn) { $process.StandardInput.WriteLine($StdIn) }
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdoutTask.Result
        StdErr = $stderrTask.Result
    }
}

Describe 'machine-safe exec on Windows' {
    It 'keeps stdout clean, inherits stdio, applies the overlay, and propagates exit code' {
        $scratch = New-ExecScratch
        try {
            Write-ExecAdapter -Scratch $scratch
            $probe = Join-Path $scratch.Root 'probe.ps1'
            @'
$request = [Console]::In.ReadLine()
[Console]::Out.WriteLine($request)
[Console]::Error.WriteLine('child-stderr')
if (-not $env:FIXTURE_HOME.EndsWith('.runtime')) { exit 91 }
if ($env:GLOBAL_FIXTURE_TOKEN) { exit 92 }
exit 23
'@ | Set-Content -LiteralPath $probe -Encoding ASCII

            $newResult = Invoke-ExecProcess -Scratch $scratch -Arguments @('new', 'fixture/account-a', '--no-seed') -Probe $null
            $newResult.ExitCode | Should Be 0
            $result = Invoke-ExecProcess -Scratch $scratch `
                -Arguments @('exec', 'fixture/account-a', '--', '-NoProfile', '-File', $probe) `
                -Probe ((Get-Command powershell.exe).Source) -StdIn '{"jsonrpc":"2.0","id":1}'

            $result.ExitCode | Should Be 23
            $result.StdOut.Trim() | Should Be '{"jsonrpc":"2.0","id":1}'
            $result.StdErr.Trim() | Should Be 'child-stderr'
            $result.StdOut | Should Not Match 'Launching'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects unsupported execution modes on stderr before spawning a child' {
        $scratch = New-ExecScratch
        try {
            Write-ExecAdapter -Scratch $scratch -Mode 'detached'
            New-Item -ItemType Directory -Force -Path (Join-Path $scratch.Profiles 'fixture\account-a') | Out-Null
            $result = Invoke-ExecProcess -Scratch $scratch -Arguments @('exec', 'fixture/account-a') -Probe 'missing-probe.exe'

            $result.ExitCode | Should Be 1
            $result.StdOut | Should BeNullOrEmpty
            $result.StdErr | Should Match 'requires a foreground'

            Write-ExecAdapter -Scratch $scratch -Mechanism 'inseparable'
            $result = Invoke-ExecProcess -Scratch $scratch -Arguments @('exec', 'fixture/account-a') -Probe 'missing-probe.exe'
            $result.ExitCode | Should Be 1
            $result.StdOut | Should BeNullOrEmpty
            $result.StdErr | Should Match 'requires accountOverlay/fileOverlay'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
