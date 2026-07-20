$script:ProfileRepoRoot = Split-Path -Parent $PSScriptRoot
$script:ProfileLauncher = Join-Path $script:ProfileRepoRoot 'multi-cli.ps1'
Import-Module (Join-Path $script:ProfileRepoRoot 'lib\MultiCli.CredentialStore.psm1') -Force

function Invoke-ProfileLauncher {
    param([string]$Root, [string[]]$Arguments, [string]$StdinText)
    $userHome = Join-Path $Root 'home'
    $profiles = Join-Path $Root 'profiles'
    New-Item -ItemType Directory -Force -Path $userHome, $profiles | Out-Null
    $argumentLine = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '""') + '"' } else { $_ } }) -join ' '
    $process = New-Object System.Diagnostics.ProcessStartInfo
    $process.FileName = (Get-Command powershell.exe).Source
    $process.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:ProfileLauncher`" $argumentLine"
    $process.UseShellExecute = $false
    $process.RedirectStandardOutput = $true
    $process.RedirectStandardError = $true
    if ($null -ne $StdinText) { $process.RedirectStandardInput = $true }
    $process.CreateNoWindow = $true
    $process.EnvironmentVariables['USERPROFILE'] = $userHome
    $process.EnvironmentVariables['HOME'] = $userHome
    $process.EnvironmentVariables['APPDATA'] = Join-Path $userHome 'AppData\Roaming'
    $process.EnvironmentVariables['LOCALAPPDATA'] = Join-Path $userHome 'AppData\Local'
    $process.EnvironmentVariables['MULTICLI_HOME'] = $profiles
    $process.EnvironmentVariables['MULTICLI_OVERRIDE_BINARY'] = (Get-Command powershell.exe).Source
    $child = [System.Diagnostics.Process]::Start($process)
    if ($null -ne $StdinText) {
        $child.StandardInput.WriteLine($StdinText)
        $child.StandardInput.Close()
    }
    $stdout = $child.StandardOutput.ReadToEnd()
    $stderr = $child.StandardError.ReadToEnd()
    $child.WaitForExit()
    return [pscustomobject]@{ ExitCode = $child.ExitCode; Output = "$stdout$stderr"; Profiles = $profiles }
}

Describe 'schema-v2 profile safety boundaries' {
    It 'refuses process-secret launches until a profile credential is stored' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mcli_profile_" + [guid]::NewGuid().ToString('N'))
        try {
            $new = Invoke-ProfileLauncher -Root $root -Arguments @('new', 'copilot-cli/account-a', '--no-seed')
            $new.ExitCode | Should Be 0
            $launch = Invoke-ProfileLauncher -Root $root -Arguments @('launch', 'copilot-cli/account-a')
            $launch.ExitCode | Should Be 1
            $launch.Output | Should Match 'multi-cli auth set'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses OS-user adapters until an owned credential context is available' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mcli_profile_" + [guid]::NewGuid().ToString('N'))
        try {
            $new = Invoke-ProfileLauncher -Root $root -Arguments @('new', 'antigravity/account-a', '--no-seed')
            $new.ExitCode | Should Be 0
            $launch = Invoke-ProfileLauncher -Root $root -Arguments @('launch', 'antigravity/account-a')
            $launch.ExitCode | Should Be 1
            $launch.Output | Should Match 'requires an owned OS-user credential context'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses inseparable adapters instead of claiming shared-state account isolation' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mcli_profile_" + [guid]::NewGuid().ToString('N'))
        try {
            $new = Invoke-ProfileLauncher -Root $root -Arguments @('new', 'opencode/account-a', '--no-seed')
            $new.ExitCode | Should Be 0
            $launch = Invoke-ProfileLauncher -Root $root -Arguments @('launch', 'opencode/account-a')
            $launch.ExitCode | Should Be 1
            $launch.Output | Should Match 'Use a legacy-isolated profile'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'delete clears the profile credential from the OS credential store' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mcli_profile_" + [guid]::NewGuid().ToString('N'))
        $target = $null
        try {
            $new = Invoke-ProfileLauncher -Root $root -Arguments @('new', 'copilot-cli/account-a', '--no-seed')
            $new.ExitCode | Should Be 0
            $metadata = Get-Content -LiteralPath (Join-Path $root 'profiles\copilot-cli\account-a\.profile.json') -Raw | ConvertFrom-Json
            $target = "multi-cli/copilot-cli/$($metadata.profileId)/COPILOT_GITHUB_TOKEN"
            Set-MultiCliCredential -Target $target -Secret 'dummy-token-delete-me'
            (Test-MultiCliCredential -Target $target) | Should Be $true

            $delete = Invoke-ProfileLauncher -Root $root -Arguments @('delete', 'copilot-cli/account-a') -StdinText 'y'

            if ($delete.ExitCode -ne 0) { Write-Host $delete.Output }
            $delete.ExitCode | Should Be 0
            (Test-Path -LiteralPath (Join-Path $root 'profiles\copilot-cli\account-a')) | Should Be $false
            (Test-MultiCliCredential -Target $target) | Should Be $false
            $target = $null
        } finally {
            if ($target) { [void](Remove-MultiCliCredential -Target $target) }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'clone refuses schema-v2 profiles instead of duplicating the profile identity' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mcli_profile_" + [guid]::NewGuid().ToString('N'))
        try {
            $new = Invoke-ProfileLauncher -Root $root -Arguments @('new', 'copilot-cli/account-a', '--no-seed')
            $new.ExitCode | Should Be 0

            $clone = Invoke-ProfileLauncher -Root $root -Arguments @('clone', 'copilot-cli/account-a', 'copilot-cli/account-b')

            $clone.ExitCode | Should Be 1
            $clone.Output | Should Match 'Cloning schema-v2 profiles'
            (Test-Path -LiteralPath (Join-Path $root 'profiles\copilot-cli\account-b')) | Should Be $false
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Minimal schema-v2 fixture tools dir (same shape as tests/OverlayState.Tests.ps1)
# so launcher behaviors can be exercised without touching the real adapters.
function New-ProfileFixtureScratch {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mcli_profile_fixture_" + [guid]::NewGuid().ToString('N'))
    $userHome = Join-Path $root 'home'
    $profiles = Join-Path $root 'profiles'
    $tools = Join-Path $root 'tools'
    New-Item -ItemType Directory -Force -Path $userHome, $profiles, (Join-Path $tools 'fixture') | Out-Null
    return [pscustomobject]@{ Root = $root; UserHome = $userHome; Profiles = $profiles; Tools = $tools }
}

function Write-ProfileFixtureAdapter {
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

function Invoke-ProfileFixtureLauncher {
    param($Scratch, [string[]]$Arguments, [string]$Probe)
    $argumentLine = ($Arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '""') + '"' } else { $_ } }) -join ' '
    $process = New-Object System.Diagnostics.ProcessStartInfo
    $process.FileName = (Get-Command powershell.exe).Source
    $process.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:ProfileLauncher`" $argumentLine"
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
    $child = [System.Diagnostics.Process]::Start($process)
    $stdout = $child.StandardOutput.ReadToEnd()
    $stderr = $child.StandardError.ReadToEnd()
    $child.WaitForExit()
    return [pscustomobject]@{ ExitCode = $child.ExitCode; Output = "$stdout$stderr" }
}

Describe 'restored launcher behaviors' {
    It 'propagates a foreground child exit code as the launcher exit code' {
        $scratch = New-ProfileFixtureScratch
        try {
            Write-ProfileFixtureAdapter -Scratch $scratch
            $new = Invoke-ProfileFixtureLauncher -Scratch $scratch -Arguments @('new', 'fixture/account-a', '--no-seed')
            if ($new.ExitCode -ne 0) { Write-Host $new.Output }
            $new.ExitCode | Should Be 0
            $exit7Script = Join-Path $scratch.Root 'exit7.ps1'
            'exit 7' | Set-Content -LiteralPath $exit7Script -Encoding ASCII
            $exit7Cmd = Join-Path $scratch.Root 'exit7.cmd'
            "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$exit7Script`"" | Set-Content -LiteralPath $exit7Cmd -Encoding ASCII

            $launch = Invoke-ProfileFixtureLauncher -Scratch $scratch -Arguments @('launch', 'fixture/account-a') -Probe $exit7Cmd

            if ($launch.ExitCode -ne 7) { Write-Host $launch.Output }
            $launch.ExitCode | Should Be 7
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'doctor --deep flags an unexpected runtime file and is clean otherwise' {
        $scratch = New-ProfileFixtureScratch
        try {
            Write-ProfileFixtureAdapter -Scratch $scratch
            $new = Invoke-ProfileFixtureLauncher -Scratch $scratch -Arguments @('new', 'fixture/account-a', '--no-seed')
            if ($new.ExitCode -ne 0) { Write-Host $new.Output }
            $new.ExitCode | Should Be 0
            $profileDir = Join-Path $scratch.Profiles 'fixture\account-a'

            $clean = Invoke-ProfileFixtureLauncher -Scratch $scratch -Arguments @('doctor', '--deep')
            if ($clean.ExitCode -ne 0) { Write-Host $clean.Output }
            $clean.ExitCode | Should Be 0
            $clean.Output | Should Not Match 'unexpected runtime file'

            $runtimeDir = Join-Path $profileDir '.runtime'
            New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
            Set-Content -LiteralPath (Join-Path $runtimeDir '.runtime-manifest') -Value 'config.toml' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $runtimeDir 'config.toml') -Value 'shared-config' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $runtimeDir 'rogue.txt') -Value 'rogue' -Encoding ASCII

            $flagged = Invoke-ProfileFixtureLauncher -Scratch $scratch -Arguments @('doctor', '--deep')
            $flagged.ExitCode | Should Be 0
            $flagged.Output | Should Match 'unexpected runtime file rogue\.txt'
            $flagged.Output | Should Match 'adapter classification defect'

            Remove-Item -LiteralPath (Join-Path $runtimeDir 'rogue.txt') -Force
            Remove-Item -LiteralPath (Join-Path $runtimeDir '.runtime-manifest') -Force
            $noManifest = Invoke-ProfileFixtureLauncher -Scratch $scratch -Arguments @('doctor', '--deep')
            $noManifest.ExitCode | Should Be 0
            $noManifest.Output | Should Match 'missing \.runtime-manifest'
            $noManifest.Output | Should Not Match 'unexpected runtime file'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'migrate --dry-run prints the plan and writes nothing' {
        $scratch = New-ProfileFixtureScratch
        try {
            Write-ProfileFixtureAdapter -Scratch $scratch
            $profileDir = Join-Path $scratch.Profiles 'fixture\work'
            New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
            Set-Content -LiteralPath (Join-Path $profileDir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $profileDir 'config.toml') -Value 'profile-config' -Encoding ASCII

            $result = Invoke-ProfileFixtureLauncher -Scratch $scratch -Arguments @('migrate', 'fixture/work', '--dry-run')

            if ($result.ExitCode -ne 0) { Write-Host $result.Output }
            $result.ExitCode | Should Be 0
            $result.Output | Should Match 'Migration plan for fixture/work'
            $result.Output | Should Match 'move credential auth\.json -> auth/auth\.json'
            $result.Output | Should Match 'Dry run -- no changes written\.'
            (Test-Path -LiteralPath (Join-Path $profileDir '.profile.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $profileDir '.migration-journal.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $profileDir 'auth')) | Should Be $false
            ((Get-Content -LiteralPath (Join-Path $profileDir 'auth.json') -Raw).Trim()) | Should Be 'profile-token'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'continue on a schema-v2 adapter reports shared conversations and exits 0' {
        $scratch = New-ProfileFixtureScratch
        try {
            Write-ProfileFixtureAdapter -Scratch $scratch
            $result = Invoke-ProfileFixtureLauncher -Scratch $scratch -Arguments @('continue', 'fixture', 'a', 'b')

            if ($result.ExitCode -ne 0) { Write-Host $result.Output }
            $result.ExitCode | Should Be 0
            $result.Output | Should Match 'already share conversations through the shared normal state; nothing to continue'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'new --from with an incompatible template refuses before creating the profile' {
        $scratch = New-ProfileFixtureScratch
        try {
            Write-ProfileFixtureAdapter -Scratch $scratch
            # A second adapter with a different id, for the cross-adapter refusal.
            $fixture2Dir = Join-Path $scratch.Tools 'fixture2'
            New-Item -ItemType Directory -Force -Path $fixture2Dir | Out-Null
            $other = Get-Content -LiteralPath (Join-Path $scratch.Tools 'fixture\adapter.json') -Raw | ConvertFrom-Json
            $other.id = 'fixture2'
            $other | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $fixture2Dir 'adapter.json') -Encoding UTF8

            $new = Invoke-ProfileFixtureLauncher -Scratch $scratch -Arguments @('new', 'fixture/account-a', '--no-seed')
            if ($new.ExitCode -ne 0) { Write-Host $new.Output }
            $new.ExitCode | Should Be 0
            $save = Invoke-ProfileFixtureLauncher -Scratch $scratch -Arguments @('template', 'save', 'fixture/account-a', 'tpl')
            if ($save.ExitCode -ne 0) { Write-Host $save.Output }
            $save.ExitCode | Should Be 0

            $apply = Invoke-ProfileFixtureLauncher -Scratch $scratch -Arguments @('new', 'fixture2/wrong', '--from', 'tpl')

            $apply.ExitCode | Should Be 1
            $apply.Output | Should Match "cannot be applied to 'fixture2'"
            (Test-Path -LiteralPath (Join-Path $scratch.Profiles 'fixture2\wrong')) | Should Be $false
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
