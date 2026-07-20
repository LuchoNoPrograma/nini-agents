$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LauncherPath = Join-Path $script:RepoRoot 'multi-cli.ps1'

function New-OverlayScratch {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mcli_overlay_" + [guid]::NewGuid().ToString('N'))
    $userHome = Join-Path $root 'home'
    $profiles = Join-Path $root 'profiles'
    $tools = Join-Path $root 'tools'
    New-Item -ItemType Directory -Force -Path $userHome, $profiles, (Join-Path $tools 'fixture') | Out-Null
    return [pscustomobject]@{ Root = $root; UserHome = $userHome; Profiles = $profiles; Tools = $tools }
}

function Write-OverlayAdapter {
    param($Scratch)
    $adapter = [ordered]@{
        schemaVersion = 2
        id = 'fixture'
        displayName = 'Fixture CLI'
        kind = 'cli'
        binary = [ordered]@{ windows = @('fixture.exe'); macos = @('fixture'); linux = @('fixture') }
        isolation = [ordered]@{
            strategy = 'accountOverlay'
            mode = 'foreground'
            env = [ordered]@{ FIXTURE_HOME = '{runtimeRoot}' }
            clearEnv = @('GLOBAL_FIXTURE_TOKEN')
        }
        account = [ordered]@{
            mechanism = 'fileOverlay'
            credentialFiles = @('auth.json')
            credentialPrecedence = @('auth.json')
            logoutScope = 'profile'
        }
        normalState = [ordered]@{
            root = [ordered]@{
                windows = '%USERPROFILE%\.fixture'
                macos = '$HOME/.fixture'
                linux = '$HOME/.fixture'
            }
            sharedPaths = @('config.toml', 'agents')
            sessionPaths = @('sessions', 'history.jsonl')
            filePaths = @('config.toml', 'history.jsonl')
            unsafePaths = @()
        }
        concurrency = [ordered]@{ level = 'multiWriter'; singletonScope = 'none' }
        support = [ordered]@{
            windows = [ordered]@{ level = 'experimental'; reason = 'Fixture only.' }
            macos = [ordered]@{ level = 'experimental'; reason = 'Fixture only.' }
            linux = [ordered]@{ level = 'experimental'; reason = 'Fixture only.' }
        }
    }
    $adapter | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Scratch.Tools 'fixture\adapter.json') -Encoding UTF8
}

function Invoke-OverlayLauncher {
    param($Scratch, [string[]]$Arguments, [string]$Probe, [string]$Capture)
    $argumentLine = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '""') + '"' } else { $_ } }) -join ' '
    $process = New-Object System.Diagnostics.ProcessStartInfo
    $process.FileName = (Get-Command powershell.exe).Source
    $process.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:LauncherPath`" $argumentLine"
    $process.UseShellExecute = $false
    $process.RedirectStandardOutput = $true
    $process.RedirectStandardError = $true
    $process.CreateNoWindow = $true
    $process.EnvironmentVariables['USERPROFILE'] = $Scratch.UserHome
    $process.EnvironmentVariables['HOME'] = $Scratch.UserHome
    $process.EnvironmentVariables['APPDATA'] = Join-Path $Scratch.UserHome 'AppData\Roaming'
    $process.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $Scratch.UserHome 'AppData\Local'
    $process.EnvironmentVariables['MULTICLI_HOME'] = $Scratch.Profiles
    $process.EnvironmentVariables['MULTICLI_TOOLS_DIR'] = $Scratch.Tools
    if ($Probe) { $process.EnvironmentVariables['MULTICLI_OVERRIDE_BINARY'] = $Probe }
    if ($Capture) { $process.EnvironmentVariables['CAPTURE_OUTPUT'] = $Capture }
    $child = [System.Diagnostics.Process]::Start($process)
    $stdout = $child.StandardOutput.ReadToEnd()
    $stderr = $child.StandardError.ReadToEnd()
    $child.WaitForExit()
    return [pscustomobject]@{ ExitCode = $child.ExitCode; Output = "$stdout$stderr" }
}

Describe 'schema-v2 account overlay on Windows' {
    It 'creates stable profile metadata without copying normal state' {
        $scratch = New-OverlayScratch
        try {
            Write-OverlayAdapter -Scratch $scratch
            $result = Invoke-OverlayLauncher -Scratch $scratch -Arguments @('new', 'fixture/account-a', '--no-seed')
            $profile = Join-Path $scratch.Profiles 'fixture\account-a'

            if ($result.ExitCode -ne 0) { Write-Host $result.Output }
            $result.ExitCode | Should Be 0
            (Test-Path -LiteralPath (Join-Path $profile '.profile.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $profile 'auth') -PathType Container) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $profile 'history.jsonl')) | Should Be $false
            $metadata = Get-Content -LiteralPath (Join-Path $profile '.profile.json') -Raw | ConvertFrom-Json
            $metadata.schemaVersion | Should Be 2
            $metadata.adapterId | Should Be 'fixture'
            ([guid]::Parse($metadata.profileId) -is [guid]) | Should Be $true
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'shares normal state while credentials remain profile-local and inherited auth is cleared' {
        $scratch = New-OverlayScratch
        try {
            Write-OverlayAdapter -Scratch $scratch
            $shared = Join-Path $scratch.UserHome '.fixture'
            New-Item -ItemType Directory -Force -Path (Join-Path $shared 'sessions'), (Join-Path $shared 'agents') | Out-Null
            Set-Content -LiteralPath (Join-Path $shared 'history.jsonl') -Value 'shared-session' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $shared 'config.toml') -Value 'shared-config' -Encoding ASCII
            $probeScript = Join-Path $scratch.Root 'capture.ps1'
            $capture = Join-Path $scratch.Root 'capture.json'
            @'
@{
  runtime = $env:FIXTURE_HOME
  inherited = $env:GLOBAL_FIXTURE_TOKEN
  profile = $env:MULTICLI_PROFILE_ID
} | ConvertTo-Json | Set-Content -LiteralPath $env:CAPTURE_OUTPUT -Encoding UTF8
'@ | Set-Content -LiteralPath $probeScript -Encoding UTF8
            $probe = Join-Path $scratch.Root 'capture.cmd'
            "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$probeScript`"" | Set-Content -LiteralPath $probe -Encoding ASCII

            (Invoke-OverlayLauncher -Scratch $scratch -Arguments @('new', 'fixture/account-a', '--no-seed')).ExitCode | Should Be 0
            (Invoke-OverlayLauncher -Scratch $scratch -Arguments @('new', 'fixture/account-b', '--no-seed')).ExitCode | Should Be 0
            $env:GLOBAL_FIXTURE_TOKEN = 'wrong-account'
            $result = Invoke-OverlayLauncher -Scratch $scratch -Arguments @('launch', 'fixture/account-a') -Probe $probe -Capture $capture
            Remove-Item Env:GLOBAL_FIXTURE_TOKEN -ErrorAction SilentlyContinue

            if ($result.ExitCode -ne 0) { Write-Host $result.Output }
            $result.ExitCode | Should Be 0
            $captured = Get-Content -LiteralPath $capture -Raw | ConvertFrom-Json
            [string]::IsNullOrEmpty($captured.inherited) | Should Be $true
            (Get-Content -LiteralPath (Join-Path $captured.runtime 'history.jsonl') -Raw).Trim() | Should Be 'shared-session'
            Set-Content -LiteralPath (Join-Path $captured.runtime 'auth.json') -Value 'account-a' -Encoding ASCII
            (Get-Content -LiteralPath (Join-Path $scratch.Profiles 'fixture\account-a\auth\auth.json') -Raw).Trim() | Should Be 'account-a'
            [string]::IsNullOrEmpty((Get-Content -LiteralPath (Join-Path $scratch.Profiles 'fixture\account-b\auth\auth.json') -Raw)) | Should Be $true
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
