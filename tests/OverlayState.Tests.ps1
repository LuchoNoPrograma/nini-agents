$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LauncherPath = Join-Path $script:RepoRoot 'nini-agents.ps1'

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
            windows = [ordered]@{ level = 'supported'; reason = 'Fixture only.' }
            macos = [ordered]@{ level = 'supported'; reason = 'Fixture only.' }
            linux = [ordered]@{ level = 'supported'; reason = 'Fixture only.' }
        }
    }
    $adapter | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Scratch.Tools 'fixture\adapter.json') -Encoding UTF8
}

function Invoke-OverlayLauncher {
    param($Scratch, [string[]]$Arguments, [string]$Probe, [string]$Capture)
    $environment = @{
        USERPROFILE = $Scratch.UserHome
        HOME = $Scratch.UserHome
        APPDATA = (Join-Path $Scratch.UserHome 'AppData\Roaming')
        LOCALAPPDATA = (Join-Path $Scratch.UserHome 'AppData\Local')
        MULTICLI_HOME = $Scratch.Profiles
        MULTICLI_TOOLS_DIR = $Scratch.Tools
        PATH = "$($Scratch.Profiles)\bin;$env:PATH"
    }
    if ($Probe) { $environment['MULTICLI_OVERRIDE_BINARY'] = $Probe }
    if ($Capture) { $environment['CAPTURE_OUTPUT'] = $Capture }
    $original = @{}
    foreach ($entry in $environment.GetEnumerator()) {
        $original[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:LauncherPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        foreach ($name in $original.Keys) { [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process') }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output | Out-String) }
}

Describe 'schema-v2 account overlay on Windows' {
    It 'links documented Codex instructions rules and logs as shared normal state' {
        $scratch = New-OverlayScratch
        try {
            $codexTools = Join-Path $scratch.Tools 'codex'
            New-Item -ItemType Directory -Force -Path $codexTools | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'ai-tools\codex\adapter.json') -Destination (Join-Path $codexTools 'adapter.json')
            $codexHome = Join-Path $scratch.UserHome '.codex'
            $rules = Join-Path $codexHome 'rules'
            $log = Join-Path $codexHome 'log'
            New-Item -ItemType Directory -Force -Path $rules, $log | Out-Null
            Set-Content -LiteralPath (Join-Path $codexHome 'AGENTS.md') -Value 'global guidance' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $rules 'default.rules') -Value 'prefix_rule(pattern=["git", "status"], decision="allow")' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $log 'codex.log') -Value 'shared log' -Encoding ASCII
            $probe = Join-Path $scratch.Root 'noop.cmd'
            '@exit /b 0' | Set-Content -LiteralPath $probe -Encoding ASCII

            (Invoke-OverlayLauncher -Scratch $scratch -Arguments @('new', 'codex/account-a', '--no-seed')).ExitCode | Should Be 0
            $result = Invoke-OverlayLauncher -Scratch $scratch -Arguments @('launch', 'codex/account-a') -Probe $probe

            if ($result.ExitCode -ne 0) { Write-Host $result.Output }
            $result.ExitCode | Should Be 0
            $runtimeRules = Join-Path $scratch.Profiles 'codex\account-a\.runtime\rules'
            $runtimeAgents = Join-Path $scratch.Profiles 'codex\account-a\.runtime\AGENTS.md'
            $runtimeLog = Join-Path $scratch.Profiles 'codex\account-a\.runtime\log'
            (Test-Path -LiteralPath $runtimeRules -PathType Container) | Should Be $true
            (((Get-Item -LiteralPath $runtimeRules).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) | Should Be $true
            (Test-Path -LiteralPath $runtimeAgents -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath $runtimeLog -PathType Container) | Should Be $true
            (((Get-Item -LiteralPath $runtimeLog).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) | Should Be $true
            (Get-Content -LiteralPath $runtimeAgents -Raw).Trim() | Should Be 'global guidance'
            (Get-Content -LiteralPath (Join-Path $runtimeRules 'default.rules') -Raw).Trim() | Should Be 'prefix_rule(pattern=["git", "status"], decision="allow")'
            (Get-Content -LiteralPath (Join-Path $runtimeLog 'codex.log') -Raw).Trim() | Should Be 'shared log'
            (Test-Path -LiteralPath (Join-Path $scratch.Profiles 'codex\account-a\auth\rules')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $scratch.Profiles 'codex\account-a\auth\AGENTS.md')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $scratch.Profiles 'codex\account-a\auth\log')) | Should Be $false
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

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

    It 'treats legacy --shared as the schema-v2 default without creating a marker' {
        $scratch = New-OverlayScratch
        try {
            Write-OverlayAdapter -Scratch $scratch
            $result = Invoke-OverlayLauncher -Scratch $scratch -Arguments @('new', 'fixture/account-a', '--shared', '--no-seed')
            $profile = Join-Path $scratch.Profiles 'fixture\account-a'

            if ($result.ExitCode -ne 0) { Write-Host $result.Output }
            $result.ExitCode | Should Be 0
            (Test-Path -LiteralPath (Join-Path $profile '.profile.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $profile '.shared')) | Should Be $false
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rebuilds an existing runtime when the adapter shared root changes' {
        $scratch = New-OverlayScratch
        try {
            Write-OverlayAdapter -Scratch $scratch
            $oldRoot = Join-Path $scratch.UserHome '.fixture'
            New-Item -ItemType Directory -Force -Path $oldRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $oldRoot 'config.toml') -Value 'old-root' -Encoding ASCII
            $probe = Join-Path $scratch.Root 'noop.cmd'
            '@exit /b 0' | Set-Content -LiteralPath $probe -Encoding ASCII
            (Invoke-OverlayLauncher -Scratch $scratch -Arguments @('new', 'fixture/account-a', '--no-seed')).ExitCode | Should Be 0
            (Invoke-OverlayLauncher -Scratch $scratch -Arguments @('launch', 'fixture/account-a') -Probe $probe).ExitCode | Should Be 0

            $newRoot = Join-Path $scratch.UserHome '.fixture-new'
            New-Item -ItemType Directory -Force -Path $newRoot | Out-Null
            Set-Content -LiteralPath (Join-Path $newRoot 'config.toml') -Value 'new-root' -Encoding ASCII
            $adapterPath = Join-Path $scratch.Tools 'fixture\adapter.json'
            $adapter = Get-Content -LiteralPath $adapterPath -Raw | ConvertFrom-Json
            $adapter.normalState.root.windows = '%USERPROFILE%\.fixture-new'
            $adapter | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $adapterPath -Encoding UTF8

            $result = Invoke-OverlayLauncher -Scratch $scratch -Arguments @('launch', 'fixture/account-a') -Probe $probe
            if ($result.ExitCode -ne 0) { Write-Host $result.Output }
            $result.ExitCode | Should Be 0
            (Get-Content -LiteralPath (Join-Path $scratch.Profiles 'fixture\account-a\.runtime\config.toml') -Raw).Trim() | Should Be 'new-root'
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

    It 'shares one credential store across profiles while main auth remains profile-local' {
        $scratch = New-OverlayScratch
        try {
            Write-OverlayAdapter -Scratch $scratch
            $adapterPath = Join-Path $scratch.Tools 'fixture\adapter.json'
            $adapter = Get-Content -LiteralPath $adapterPath -Raw | ConvertFrom-Json
            $adapter | Add-Member -NotePropertyName sharedCredentialState -NotePropertyValue ([pscustomobject]@{
                root = '.shared/fixture/oauth'
                entries = @(
                    [pscustomobject]@{ path = '.credentials.json'; kind = 'jsonObjectFile' },
                    [pscustomobject]@{ path = 'oauth-locks'; kind = 'directory' }
                )
                legacyMigration = 'preserveInactive'
            })
            $adapter.normalState | Add-Member -NotePropertyName runtimePaths -NotePropertyValue @('cache', 'version.json')
            $adapter | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $adapterPath -Encoding UTF8
            $probe = Join-Path $scratch.Root 'noop.cmd'
            '@exit /b 0' | Set-Content -LiteralPath $probe -Encoding ASCII

            (Invoke-OverlayLauncher -Scratch $scratch -Arguments @('new', 'fixture/account-a', '--no-seed')).ExitCode | Should Be 0
            (Invoke-OverlayLauncher -Scratch $scratch -Arguments @('new', 'fixture/account-b', '--no-seed')).ExitCode | Should Be 0
            (Invoke-OverlayLauncher -Scratch $scratch -Arguments @('launch', 'fixture/account-a') -Probe $probe).ExitCode | Should Be 0
            (Invoke-OverlayLauncher -Scratch $scratch -Arguments @('launch', 'fixture/account-b') -Probe $probe).ExitCode | Should Be 0

            $store = Join-Path $scratch.Profiles '.shared\fixture\oauth'
            $runtimeA = Join-Path $scratch.Profiles 'fixture\account-a\.runtime'
            $runtimeB = Join-Path $scratch.Profiles 'fixture\account-b\.runtime'
            (Get-Content -LiteralPath (Join-Path $store '.credentials.json') -Raw).Trim() | Should Be '{}'
            (Test-Path -LiteralPath (Join-Path $store 'oauth-locks') -PathType Container) | Should Be $true
            (Get-Item -LiteralPath (Join-Path $runtimeA '.credentials.json')).LinkType | Should Be 'HardLink'
            (Get-Item -LiteralPath (Join-Path $runtimeB '.credentials.json')).LinkType | Should Be 'HardLink'
            (((Get-Item -LiteralPath (Join-Path $runtimeA 'oauth-locks')).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) | Should Be $true
            (((Get-Item -LiteralPath (Join-Path $runtimeB 'oauth-locks')).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) | Should Be $true

            Set-Content -LiteralPath (Join-Path $runtimeA '.credentials.json') -Value '{"synthetic":"shared"}' -Encoding ASCII
            ((Get-Content -LiteralPath (Join-Path $runtimeB '.credentials.json') -Raw | ConvertFrom-Json).synthetic) | Should Be 'shared'
            Set-Content -LiteralPath (Join-Path $runtimeA 'auth.json') -Value 'account-a' -Encoding ASCII
            [string]::IsNullOrEmpty((Get-Content -LiteralPath (Join-Path $runtimeB 'auth.json') -Raw)) | Should Be $true
            @(Get-Content -LiteralPath (Join-Path $runtimeA '.runtime-manifest')) | Should Contain '.credentials.json'
            @(Get-Content -LiteralPath (Join-Path $runtimeA '.runtime-manifest')) | Should Contain 'oauth-locks'
            New-Item -ItemType Directory -Force -Path (Join-Path $runtimeA 'cache\nested') | Out-Null
            Set-Content -LiteralPath (Join-Path $runtimeA 'cache\nested\item') -Value 'generated' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $runtimeA 'version.json') -Value 'generated' -Encoding ASCII
            $doctor = Invoke-OverlayLauncher -Scratch $scratch -Arguments @('doctor', '--deep') -Probe $probe
            $doctor.ExitCode | Should Be 0
            $doctor.Output | Should Not Match 'wrong target'
            $doctor.Output | Should Not Match 'unexpected runtime file'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'launches a legacy file-overlay profile whole-root without migrating its credential' {
        $scratch = New-OverlayScratch
        try {
            Write-OverlayAdapter -Scratch $scratch
            $profile = Join-Path $scratch.Profiles 'fixture\legacy'
            New-Item -ItemType Directory -Force -Path $profile | Out-Null
            $credential = Join-Path $profile 'auth.json'
            Set-Content -LiteralPath $credential -Value '{"fixtureCredential":"unchanged"}' -Encoding ASCII
            $credentialHash = (Get-FileHash -LiteralPath $credential -Algorithm SHA256).Hash

            $probeScript = Join-Path $scratch.Root 'capture-legacy.ps1'
            $capture = Join-Path $scratch.Root 'capture-legacy.json'
            @'
@{
  runtime = $env:FIXTURE_HOME
  inherited = $env:GLOBAL_FIXTURE_TOKEN
  profile = $env:MULTICLI_PROFILE_ID
} | ConvertTo-Json | Set-Content -LiteralPath $env:CAPTURE_OUTPUT -Encoding UTF8
'@ | Set-Content -LiteralPath $probeScript -Encoding UTF8
            $probe = Join-Path $scratch.Root 'capture-legacy.cmd'
            "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$probeScript`"" | Set-Content -LiteralPath $probe -Encoding ASCII

            $env:GLOBAL_FIXTURE_TOKEN = 'wrong-account-secret'
            $env:MULTICLI_PROFILE_ID = 'stale-schema-v2-id'
            $result = Invoke-OverlayLauncher -Scratch $scratch -Arguments @('launch', 'fixture/legacy') -Probe $probe -Capture $capture
            Remove-Item Env:GLOBAL_FIXTURE_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:MULTICLI_PROFILE_ID -ErrorAction SilentlyContinue

            if ($result.ExitCode -ne 0) { Write-Host $result.Output }
            $result.ExitCode | Should Be 0
            $result.Output | Should Match 'legacy whole-root'
            $captured = Get-Content -LiteralPath $capture -Raw | ConvertFrom-Json
            $captured.runtime | Should Be $profile
            [string]::IsNullOrEmpty($captured.inherited) | Should Be $true
            [string]::IsNullOrEmpty($captured.profile) | Should Be $true
            (Get-FileHash -LiteralPath $credential -Algorithm SHA256).Hash | Should Be $credentialHash
            (Test-Path -LiteralPath (Join-Path $profile '.profile.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $profile '.runtime')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $profile 'auth')) | Should Be $false
        } finally {
            Remove-Item Env:GLOBAL_FIXTURE_TOKEN -ErrorAction SilentlyContinue
            Remove-Item Env:MULTICLI_PROFILE_ID -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps legacy whole-root compatibility closed for process-secret adapters' {
        $scratch = New-OverlayScratch
        try {
            Write-OverlayAdapter -Scratch $scratch
            $adapterPath = Join-Path $scratch.Tools 'fixture\adapter.json'
            $adapter = Get-Content -LiteralPath $adapterPath -Raw | ConvertFrom-Json
            $adapter.account.mechanism = 'processSecret'
            $adapter.account.credentialFiles = @()
            $adapter.account.credentialPrecedence = @('FIXTURE_TOKEN')
            $adapter.account.logoutScope = 'process'
            $adapter.account | Add-Member -NotePropertyName secret -NotePropertyValue ([pscustomobject]@{ environmentVariable = 'FIXTURE_TOKEN' }) -Force
            $adapter | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $adapterPath -Encoding UTF8

            $profile = Join-Path $scratch.Profiles 'fixture\legacy-secret'
            New-Item -ItemType Directory -Force -Path $profile | Out-Null
            $probe = Join-Path $scratch.Root 'noop.cmd'
            '@exit /b 0' | Set-Content -LiteralPath $probe -Encoding ASCII
            $capture = Join-Path $scratch.Root 'must-not-exist.json'

            $result = Invoke-OverlayLauncher -Scratch $scratch -Arguments @('launch', 'fixture/legacy-secret') -Probe $probe -Capture $capture

            $result.ExitCode | Should Not Be 0
            $result.Output | Should Match 'missing schema-v2 metadata'
            (Test-Path -LiteralPath $capture) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $profile '.profile.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $profile '.runtime')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $profile 'auth')) | Should Be $false
        } finally {
            Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps a used traversal path closed on the lightweight launch path' {
        $scratch = New-OverlayScratch
        try {
            Write-OverlayAdapter -Scratch $scratch
            $probe = Join-Path $scratch.Root 'noop.cmd'
            '@exit /b 0' | Set-Content -LiteralPath $probe -Encoding ASCII
            (Invoke-OverlayLauncher -Scratch $scratch -Arguments @('new', 'fixture/account-a', '--no-seed')).ExitCode | Should Be 0
            (Invoke-OverlayLauncher -Scratch $scratch -Arguments @('launch', 'fixture/account-a') -Probe $probe).ExitCode | Should Be 0

            $adapterPath = Join-Path $scratch.Tools 'fixture\adapter.json'
            $adapter = Get-Content -LiteralPath $adapterPath -Raw | ConvertFrom-Json
            $adapter.normalState.sharedPaths = @('../outside')
            $adapter.normalState.filePaths = @()
            $adapter | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $adapterPath -Encoding UTF8

            $result = Invoke-OverlayLauncher -Scratch $scratch -Arguments @('launch', 'fixture/account-a') -Probe $probe

            $result.ExitCode | Should Not Be 0
            $result.Output | Should Match "unsafe shared state path '../outside'"
            (Test-Path -LiteralPath (Join-Path $scratch.UserHome 'outside')) | Should Be $false
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
