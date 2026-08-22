# Real-execution tests for the legacy -> schema-v2 migration engine in
# lib/MultiCli.Migration.psm1 (Windows PowerShell 5.1, Pester 3.4).
# No mocks: every test builds a real legacy profile tree under a temp scratch
# root and invokes the module directly (the `nini-agents migrate` dispatch is
# wired into nini-agents.ps1 separately).

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:ModulePath = Join-Path $script:RepoRoot 'lib\MultiCli.Migration.psm1'
$script:LauncherPath = Join-Path $script:RepoRoot 'nini-agents.ps1'
Import-Module $script:ModulePath -Force

function New-MigrationScratch {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mcli_migration_" + [guid]::NewGuid().ToString('N'))
    $userHome = Join-Path $root 'home'
    $profiles = Join-Path $root 'profiles'
    $tools = Join-Path $root 'tools'
    New-Item -ItemType Directory -Force -Path $userHome, $profiles, (Join-Path $tools 'fixture') | Out-Null
    return [pscustomobject]@{ Root = $root; UserHome = $userHome; Profiles = $profiles; Tools = $tools }
}

function Remove-MigrationScratch {
    param($Scratch)
    Remove-Item -LiteralPath $Scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
}

function Write-MigrationAdapter {
    param($Scratch)
    $json = @'
{
  "schemaVersion": 2,
  "id": "fixture",
  "displayName": "Fixture CLI",
  "kind": "cli",
  "binary": { "windows": ["fixture.exe", "fixture"], "macos": ["fixture", "fixture-alt"], "linux": ["fixture", "fixture-alt"] },
  "isolation": {
    "strategy": "accountOverlay",
    "mode": "foreground",
    "env": { "FIXTURE_HOME": "{runtimeRoot}" },
    "clearEnv": []
  },
  "account": {
    "mechanism": "fileOverlay",
    "credentialFiles": ["auth.json", "keys/token.json"],
    "credentialPrecedence": ["auth.json"],
    "logoutScope": "profile"
  },
  "normalState": {
    "root": {
      "windows": "%USERPROFILE%\\.fixture",
      "macos": "$HOME/.fixture",
      "linux": "$HOME/.fixture"
    },
    "sharedPaths": ["config.toml", "agents", "plugins"],
    "sessionPaths": ["sessions", "history.jsonl"],
    "filePaths": ["config.toml", "history.jsonl"],
    "unsafePaths": []
  },
  "concurrency": { "level": "multiWriter", "singletonScope": "none" },
  "support": {
    "windows": { "level": "supported", "reason": "Fixture only." },
    "macos": { "level": "supported", "reason": "Fixture only." },
    "linux": { "level": "supported", "reason": "Fixture only." }
  },
  "install": "https://example.test/install",
  "versionCommand": ["--version"]
}
'@
    $manifest = Join-Path $Scratch.Tools 'fixture\adapter.json'
    Set-Content -LiteralPath $manifest -Value $json -Encoding UTF8
    return Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
}

function Get-SharedRoot {
    param($Scratch)
    return Join-Path $Scratch.UserHome '.fixture'
}

function Get-ProfileDirFor {
    param($Scratch, [string]$Name)
    return Join-Path $Scratch.Profiles "fixture\$Name"
}

# A realistic legacy profile: credentials (one nested), shared/session state,
# and a .cli launcher marker.
function New-LegacyProfile {
    param($Scratch, [string]$Name)
    $pdir = Get-ProfileDirFor -Scratch $Scratch -Name $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'keys'), (Join-Path $pdir 'agents\reviewer'), (Join-Path $pdir 'sessions\2026\06') | Out-Null
    Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $pdir 'keys\token.json') -Value 'nested-token' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $pdir 'config.toml') -Value 'profile-config' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $pdir 'agents\reviewer\agent.md') -Value 'agent' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $pdir 'sessions\2026\06\rollout.jsonl') -Value 'rollout' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $pdir 'history.jsonl') -Value 'shared-history' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $pdir '.cli') -Value '' -Encoding ASCII
    return $pdir
}

function Initialize-SharedRoot {
    param($Scratch)
    $shared = Get-SharedRoot -Scratch $Scratch
    New-Item -ItemType Directory -Force -Path $shared | Out-Null
    Set-Content -LiteralPath (Join-Path $shared 'config.toml') -Value 'shared-config' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $shared 'history.jsonl') -Value 'shared-history' -Encoding ASCII
    return $shared
}

# Sorted newline-joined relative path set of a tree ('/' separators, dirs
# included, reparse points listed but never descended into).
function Get-RelativeTree {
    param([string]$Root)
    $result = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue('')
    while ($queue.Count -gt 0) {
        $rel = $queue.Dequeue()
        $dir = $Root
        if ($rel) { $dir = Join-Path $Root $rel }
        foreach ($item in (Get-ChildItem -LiteralPath $dir -Force)) {
            $childRel = $item.Name
            if ($rel) { $childRel = "$rel/$($item.Name)" }
            $result += $childRel
            $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            if ($item.PSIsContainer -and -not $isReparse) { $queue.Enqueue($childRel) }
        }
    }
    return ($result | Sort-Object) -join "`n"
}

function Get-SortedExpected {
    param([string[]]$Paths)
    return ($Paths | Sort-Object) -join "`n"
}

# Invoke the engine with the scratch home as USERPROFILE (the shared root
# resolves from it), restoring the process environment afterwards.
function Invoke-Migration {
    param($Scratch, $Adapter, [string]$ProfileDir, [switch]$DryRun, [switch]$PreferProfile)
    $oldHome = $env:USERPROFILE
    $env:USERPROFILE = $Scratch.UserHome
    try {
        if ($DryRun) { return Invoke-MultiCliMigration -Adapter $Adapter -ProfileDir $ProfileDir -DryRun }
        if ($PreferProfile) { return Invoke-MultiCliMigration -Adapter $Adapter -ProfileDir $ProfileDir -PreferProfile }
        return Invoke-MultiCliMigration -Adapter $Adapter -ProfileDir $ProfileDir
    } finally {
        $env:USERPROFILE = $oldHome
    }
}

function Get-ThrownMessage {
    param([scriptblock]$Block)
    try {
        & $Block | Out-Null
    } catch {
        return $_.Exception.Message
    }
    return $null
}

function Protect-DirectoryFromWrite {
    param([string]$Path)
    & icacls $Path '/deny' "$($env:USERNAME):(OI)(CI)(W)" | Out-Null
}

function Unprotect-Directory {
    param([string]$Path)
    & icacls $Path '/remove:d' $env:USERNAME | Out-Null
}

# Launch the real nini-agents.ps1 in a child process against the scratch tree.
function Invoke-MigrationLauncher {
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
    $stdoutTask = $child.StandardOutput.ReadToEndAsync()
    $stderrTask = $child.StandardError.ReadToEndAsync()
    $timedOut = -not $child.WaitForExit(120000)
    if ($timedOut) { try { $child.Kill() } catch { }; $child.WaitForExit() }
    return [pscustomobject]@{
        ExitCode = $(if ($timedOut) { -1 } else { $child.ExitCode })
        Output = "$($stdoutTask.Result)$($stderrTask.Result)"
    }
}

Describe 'Test-MultiCliLegacyProfile' {
    It 'detects a legacy profile and rejects schema-v2 profiles' {
        $scratch = New-MigrationScratch
        try {
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path $pdir | Out-Null
            (Test-MultiCliLegacyProfile -ProfileDir $pdir) | Should Be $true
            Set-Content -LiteralPath (Join-Path $pdir '.profile.json') -Value '{}' -Encoding ASCII
            (Test-MultiCliLegacyProfile -ProfileDir $pdir) | Should Be $false
            (Test-MultiCliLegacyProfile -ProfileDir (Join-Path $scratch.Root 'missing')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }
}

Describe 'Invoke-MultiCliMigration dry run' {
    It 'reports the exact plan and writes nothing' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = New-LegacyProfile -Scratch $scratch -Name 'work'
            $shared = Initialize-SharedRoot -Scratch $scratch

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun

            $result.Mode | Should Be 'dry-run'
            $result.Migrated | Should Be $false
            ($result.Lines -contains 'Migration plan for fixture/work (legacy-isolated -> accountOverlay):') | Should Be $true
            ($result.Lines -contains '  move credential auth.json -> auth/auth.json') | Should Be $true
            ($result.Lines -contains '  move credential keys/token.json -> auth/keys/token.json') | Should Be $true
            ($result.Lines -contains "  merge shared agents -> $(Join-Path $shared 'agents')") | Should Be $true
            ($result.Lines -contains "  merge session sessions -> $(Join-Path $shared 'sessions')") | Should Be $true
            ($result.Lines -contains '  skip config.toml (conflict: content differs; use --prefer-profile to override)') | Should Be $true
            ($result.Lines -contains '  remove duplicate history.jsonl (shared root already has identical content)') | Should Be $true
            ($result.Lines -contains '  keep launcher metadata .cli') | Should Be $true
            ($result.Lines -contains '  write .profile.json (schemaVersion 2, mode accountOverlay)') | Should Be $true
            ($result.Lines -contains 'Dry run -- no changes written.') | Should Be $true

            (Test-Path -LiteralPath (Join-Path $pdir '.profile.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir 'auth')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'config.toml')) | Should Be $true
            ((Get-Content -LiteralPath (Join-Path $shared 'config.toml') -Raw).Trim()) | Should Be 'shared-config'
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'does not create the shared state root' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'agents') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'agents\agent.md') -Value 'agent' -Encoding ASCII
            $shared = Get-SharedRoot -Scratch $scratch
            (Test-Path -LiteralPath $shared) | Should Be $false

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun

            $result.Mode | Should Be 'dry-run'
            (Test-Path -LiteralPath $shared) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }
}

Describe 'Invoke-MultiCliMigration refusal' {
    It 'refuses unknown top-level and nested entries, listing them, without writing' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'keys') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'keys\token.json') -Value 'nested-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'keys\rogue.txt') -Value 'rogue' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'mystery.txt') -Value 'mystery' -Encoding ASCII

            $message = Get-ThrownMessage { Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun }

            $message | Should Match ([regex]::Escape('Cannot migrate fixture/work: legacy profile contains entries the adapter does not declare:'))
            $message | Should Match ([regex]::Escape('  unknown: keys/rogue.txt'))
            $message | Should Match ([regex]::Escape('  unknown: mystery.txt'))
            $message | Should Match ([regex]::Escape('No changes were made.'))
            (Test-Path -LiteralPath (Join-Path $pdir 'mystery.txt')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'keys\rogue.txt')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir '.profile.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
            (Test-Path -LiteralPath (Get-SharedRoot -Scratch $scratch)) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'refuses entries overlapping credential and shared declarations' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $adapter.account.credentialFiles = @('auth.json', 'vault/token.json')
            $adapter.normalState.sharedPaths = @('config.toml', 'agents', 'plugins', 'vault/settings.json')
            $adapter.normalState.filePaths = @('config.toml', 'history.jsonl', 'vault/settings.json')
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'vault') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'vault\token.json') -Value 'token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'vault\settings.json') -Value 'settings' -Encoding ASCII

            $message = Get-ThrownMessage { Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun }

            $message | Should Match ([regex]::Escape('  overlap: vault (matches both credential and shared-state declarations)'))
            $message | Should Match ([regex]::Escape('No changes were made.'))
            (Test-Path -LiteralPath (Join-Path $pdir '.profile.json')) | Should Be $false
            (Test-Path -LiteralPath (Get-SharedRoot -Scratch $scratch)) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'refuses osUserCredentialStore adapters with a clear error' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $adapter.account.mechanism = 'osUserCredentialStore'
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path $pdir | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII

            $message = Get-ThrownMessage { Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir }

            $message | Should Match ([regex]::Escape("Cannot migrate fixture/work: adapter 'fixture' uses 'osUserCredentialStore' credentials."))
            $message | Should Match ([regex]::Escape('keep the legacy profile.'))
            (Test-Path -LiteralPath (Join-Path $pdir '.profile.json')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'refuses inseparable adapters with the adapter reason' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $adapter.account.mechanism = 'inseparable'
            $adapter.account | Add-Member -NotePropertyName reason -NotePropertyValue 'Auth and chats share one database.' -Force
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path $pdir | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII

            $message = Get-ThrownMessage { Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir }

            $message | Should Match ([regex]::Escape("Cannot migrate fixture/work: adapter 'fixture' is marked inseparable (Auth and chats share one database.)"))
            (Test-Path -LiteralPath (Join-Path $pdir '.profile.json')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'never overwrites an existing different credential target' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'auth') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'auth\auth.json') -Value 'different-token' -Encoding ASCII

            $message = Get-ThrownMessage { Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -PreferProfile }

            $message | Should Match ([regex]::Escape("credential target 'auth/auth.json' already exists with different content; refusing to overwrite credentials."))
            ((Get-Content -LiteralPath (Join-Path $pdir 'auth.json') -Raw).Trim()) | Should Be 'profile-token'
            ((Get-Content -LiteralPath (Join-Path $pdir 'auth\auth.json') -Raw).Trim()) | Should Be 'different-token'
            (Test-Path -LiteralPath (Join-Path $pdir '.profile.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }
    It 'refuses credential entries that are links' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $adapter.account.credentialFiles = @('auth.json', 'vault')
            $shared = Get-SharedRoot -Scratch $scratch
            New-Item -ItemType Directory -Force -Path (Join-Path $shared 'vault-real') | Out-Null
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path $pdir | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            New-Item -ItemType Junction -Path (Join-Path $pdir 'vault') -Target (Join-Path $shared 'vault-real') | Out-Null

            $message = Get-ThrownMessage { Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun }

            $message | Should Match ([regex]::Escape("Cannot migrate fixture/work: credential 'vault' is a link."))
            $message | Should Match ([regex]::Escape('No changes were made.'))
            (Test-Path -LiteralPath (Join-Path $pdir '.profile.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir 'auth')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }
}

Describe 'Invoke-MultiCliMigration apply' {
    It 'moves credentials preserving subpaths, merges state, prunes emptied dirs, writes metadata and journal' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = New-LegacyProfile -Scratch $scratch -Name 'work'
            $shared = Initialize-SharedRoot -Scratch $scratch

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir

            $result.Mode | Should Be 'apply'
            $result.Migrated | Should Be $true
            ($result.Lines -contains 'Migrated fixture/work to schema-v2 (accountOverlay).') | Should Be $true

            ((Get-Content -LiteralPath (Join-Path $pdir 'auth\auth.json') -Raw).Trim()) | Should Be 'profile-token'
            ((Get-Content -LiteralPath (Join-Path $pdir 'auth\keys\token.json') -Raw).Trim()) | Should Be 'nested-token'
            $metadata = Get-Content -LiteralPath (Join-Path $pdir '.profile.json') -Raw | ConvertFrom-Json
            $metadata.schemaVersion | Should Be 2
            $metadata.adapterId | Should Be 'fixture'
            $metadata.mode | Should Be 'accountOverlay'
            ([guid]::Parse($metadata.profileId) -is [guid]) | Should Be $true
            $journal = Get-Content -LiteralPath (Join-Path $pdir '.migration-journal.json') -Raw | ConvertFrom-Json
            $journal.status | Should Be 'completed'

            ((Get-Content -LiteralPath (Join-Path $shared 'agents\reviewer\agent.md') -Raw).Trim()) | Should Be 'agent'
            ((Get-Content -LiteralPath (Join-Path $shared 'sessions\2026\06\rollout.jsonl') -Raw).Trim()) | Should Be 'rollout'
            ((Get-Content -LiteralPath (Join-Path $shared 'history.jsonl') -Raw).Trim()) | Should Be 'shared-history'
            ((Get-Content -LiteralPath (Join-Path $shared 'config.toml') -Raw).Trim()) | Should Be 'shared-config'
            (Test-Path -LiteralPath (Join-Path $pdir 'history.jsonl')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir 'config.toml')) | Should Be $true

            (Test-Path -LiteralPath (Join-Path $pdir 'agents')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir 'sessions')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir 'keys')) | Should Be $false

            $expectedProfile = Get-SortedExpected @('.cli', '.migration-journal.json', '.profile.json', 'auth', 'auth/auth.json', 'auth/keys', 'auth/keys/token.json', 'config.toml')
            (Get-RelativeTree $pdir) | Should Be $expectedProfile
            $expectedShared = Get-SortedExpected @('agents', 'agents/reviewer', 'agents/reviewer/agent.md', 'config.toml', 'history.jsonl', 'sessions', 'sessions/2026', 'sessions/2026/06', 'sessions/2026/06/rollout.jsonl')
            (Get-RelativeTree $shared) | Should Be $expectedShared
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'skips conflicting shared content by default and honors -PreferProfile' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $shared = Get-SharedRoot -Scratch $scratch
            New-Item -ItemType Directory -Force -Path $shared | Out-Null
            Set-Content -LiteralPath (Join-Path $shared 'config.toml') -Value 'shared-config' -Encoding ASCII
            $pdirA = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            $pdirB = Get-ProfileDirFor -Scratch $scratch -Name 'work2'
            New-Item -ItemType Directory -Force -Path $pdirA, $pdirB | Out-Null
            Set-Content -LiteralPath (Join-Path $pdirA 'auth.json') -Value 'token-a' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdirA 'config.toml') -Value 'profile-config' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdirB 'auth.json') -Value 'token-b' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdirB 'config.toml') -Value 'profile-b-config' -Encoding ASCII

            $resultA = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdirA
            $resultA.Migrated | Should Be $true
            ($resultA.Lines -contains '  skip config.toml (conflict: content differs; use --prefer-profile to override)') | Should Be $true
            ((Get-Content -LiteralPath (Join-Path $shared 'config.toml') -Raw).Trim()) | Should Be 'shared-config'
            ((Get-Content -LiteralPath (Join-Path $pdirA 'config.toml') -Raw).Trim()) | Should Be 'profile-config'

            $resultB = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdirB -PreferProfile
            $resultB.Migrated | Should Be $true
            ($resultB.Lines -contains "  replace config.toml -> $(Join-Path $shared 'config.toml') (--prefer-profile: content differs)") | Should Be $true
            ((Get-Content -LiteralPath (Join-Path $shared 'config.toml') -Raw).Trim()) | Should Be 'profile-b-config'
            (Test-Path -LiteralPath (Join-Path $pdirB 'config.toml')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'skips type mismatches by default and replaces with -PreferProfile' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $shared = Get-SharedRoot -Scratch $scratch
            New-Item -ItemType Directory -Force -Path (Join-Path $shared 'agents') | Out-Null
            Set-Content -LiteralPath (Join-Path $shared 'agents\existing.md') -Value 'existing' -Encoding ASCII
            $pdirA = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            $pdirB = Get-ProfileDirFor -Scratch $scratch -Name 'work2'
            New-Item -ItemType Directory -Force -Path $pdirA, $pdirB | Out-Null
            Set-Content -LiteralPath (Join-Path $pdirA 'auth.json') -Value 'token-a' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdirA 'agents') -Value 'just-a-file' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdirB 'auth.json') -Value 'token-b' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdirB 'agents') -Value 'just-a-file-b' -Encoding ASCII

            $resultA = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdirA
            $resultA.Migrated | Should Be $true
            ($resultA.Lines -contains '  skip agents (conflict: shared root has a directory where the profile has a file; use --prefer-profile to override)') | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdirA 'agents') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $shared 'agents\existing.md')) | Should Be $true

            $resultB = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdirB -PreferProfile
            $resultB.Migrated | Should Be $true
            (Test-Path -LiteralPath (Join-Path $shared 'agents') -PathType Leaf) | Should Be $true
            ((Get-Content -LiteralPath (Join-Path $shared 'agents') -Raw).Trim()) | Should Be 'just-a-file-b'
            (Test-Path -LiteralPath (Join-Path $pdirB 'agents')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'leaves legacy shared links in place and skips nested links' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $shared = Get-SharedRoot -Scratch $scratch
            New-Item -ItemType Directory -Force -Path (Join-Path $shared 'plugins'), (Join-Path $shared 'agents'), (Join-Path $shared 'outside-dir') | Out-Null
            Set-Content -LiteralPath (Join-Path $shared 'plugins\plugin.md') -Value 'plugin' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $shared 'agents\existing.md') -Value 'existing' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $shared 'outside-dir\note.md') -Value 'outside' -Encoding ASCII
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'agents') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir '.shared') -Value '' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'agents\local.md') -Value 'local' -Encoding ASCII
            New-Item -ItemType Junction -Path (Join-Path $pdir 'plugins') -Target (Join-Path $shared 'plugins') | Out-Null
            New-Item -ItemType Junction -Path (Join-Path $pdir 'agents\linkdir') -Target (Join-Path $shared 'outside-dir') | Out-Null

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir

            $result.Migrated | Should Be $true
            ($result.Lines -contains '  keep shared link plugins (target: ' + (Join-Path $shared 'plugins') + ')') | Should Be $true
            ($result.Lines | Where-Object { $_ -like '  skip nested link agents/linkdir*' } | Measure-Object).Count | Should Be 1
            $pluginsItem = Get-Item -LiteralPath (Join-Path $pdir 'plugins') -Force
            (($pluginsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) | Should Be $true
            $linkdirItem = Get-Item -LiteralPath (Join-Path $pdir 'agents\linkdir') -Force
            (($linkdirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) | Should Be $true
            (Get-RelativeTree (Join-Path $shared 'plugins')) | Should Be 'plugin.md'
            ((Get-Content -LiteralPath (Join-Path $shared 'agents\local.md') -Raw).Trim()) | Should Be 'local'
            ((Get-Content -LiteralPath (Join-Path $shared 'agents\existing.md') -Raw).Trim()) | Should Be 'existing'
            (Test-Path -LiteralPath (Join-Path $shared 'agents\linkdir')) | Should Be $false
            $expectedProfile = Get-SortedExpected @('.migration-journal.json', '.profile.json', '.shared', 'agents', 'agents/linkdir', 'auth', 'auth/auth.json', 'auth/keys', 'auth/keys/token.json', 'plugins')
            (Get-RelativeTree $pdir) | Should Be $expectedProfile
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'writes a roll-forward journal on failure and a re-run rolls forward' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $shared = Get-SharedRoot -Scratch $scratch
            New-Item -ItemType Directory -Force -Path $shared | Out-Null
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'agents') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'agents\agent.md') -Value 'agent' -Encoding ASCII
            Protect-DirectoryFromWrite -Path $shared

            $message = Get-ThrownMessage { Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir }

            $message | Should Match ([regex]::Escape('Migration failed'))
            $message | Should Match ([regex]::Escape('.migration-journal.json'))
            (Test-Path -LiteralPath (Join-Path $pdir '.profile.json')) | Should Be $false
            $journal = Get-Content -LiteralPath (Join-Path $pdir '.migration-journal.json') -Raw | ConvertFrom-Json
            $journal.status | Should Be 'failed'
            (@($journal.operations | Where-Object { $_.op -eq 'move-credential' -and $_.status -eq 'done' })).Count | Should Be 1
            (@($journal.operations | Where-Object { $_.op -eq 'merge-move' -and $_.status -eq 'failed' })).Count | Should Be 1
            (@($journal.operations | Where-Object { $_.status -eq 'pending' })).Count | Should BeGreaterThan 0
            ((Get-Content -LiteralPath (Join-Path $pdir 'auth\auth.json') -Raw).Trim()) | Should Be 'profile-token'
            (Test-Path -LiteralPath (Join-Path $pdir 'agents\agent.md')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $shared 'agents')) | Should Be $false

            Unprotect-Directory -Path $shared
            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir

            $result.Migrated | Should Be $true
            ((Get-Content -LiteralPath (Join-Path $shared 'agents\agent.md') -Raw).Trim()) | Should Be 'agent'
            $metadata = Get-Content -LiteralPath (Join-Path $pdir '.profile.json') -Raw | ConvertFrom-Json
            $metadata.schemaVersion | Should Be 2
            $metadata.adapterId | Should Be 'fixture'
            $metadata.mode | Should Be 'accountOverlay'
            $completed = Get-Content -LiteralPath (Join-Path $pdir '.migration-journal.json') -Raw | ConvertFrom-Json
            $completed.status | Should Be 'completed'
            $expectedProfile = Get-SortedExpected @('.migration-journal.json', '.profile.json', 'auth', 'auth/auth.json', 'auth/keys', 'auth/keys/token.json')
            (Get-RelativeTree $pdir) | Should Be $expectedProfile
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'is an idempotent no-op success on the second apply' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = New-LegacyProfile -Scratch $scratch -Name 'work'
            $shared = Initialize-SharedRoot -Scratch $scratch
            (Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir).Migrated | Should Be $true
            $beforeProfile = Get-RelativeTree $pdir
            $beforeShared = Get-RelativeTree $shared

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir

            $result.Mode | Should Be 'noop'
            $result.Migrated | Should Be $false
            ($result.Lines -contains "Profile 'fixture/work' is already schema-v2 (accountOverlay); nothing to do.") | Should Be $true
            (Get-RelativeTree $pdir) | Should Be $beforeProfile
            (Get-RelativeTree $shared) | Should Be $beforeShared
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'migrates filesystem state for processSecret adapters and demands auth set afterwards' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $adapter.account.mechanism = 'processSecret'
            $adapter.account.credentialFiles = @()
            $adapter.account | Add-Member -NotePropertyName secret -NotePropertyValue ([pscustomobject]@{ environmentVariable = 'FIXTURE_TOKEN' }) -Force
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'sessions') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'config.toml') -Value 'profile-config' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'sessions\s.jsonl') -Value 'session' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'history.jsonl') -Value 'history' -Encoding ASCII

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir

            $result.Migrated | Should Be $true
            ($result.Lines -contains 'Migrated fixture/work to schema-v2 (accountOverlay).') | Should Be $true
            ($result.Lines -contains "Note: adapter 'fixture' uses process-secret credentials. Run: nini-agents auth set fixture/work before launching.") | Should Be $true
            $shared = Get-SharedRoot -Scratch $scratch
            ((Get-Content -LiteralPath (Join-Path $shared 'config.toml') -Raw).Trim()) | Should Be 'profile-config'
            ((Get-Content -LiteralPath (Join-Path $shared 'sessions\s.jsonl') -Raw).Trim()) | Should Be 'session'
            ((Get-Content -LiteralPath (Join-Path $shared 'history.jsonl') -Raw).Trim()) | Should Be 'history'
            $metadata = Get-Content -LiteralPath (Join-Path $pdir '.profile.json') -Raw | ConvertFrom-Json
            $metadata.schemaVersion | Should Be 2
            $metadata.mode | Should Be 'accountOverlay'
            $expectedProfile = Get-SortedExpected @('.migration-journal.json', '.profile.json')
            (Get-RelativeTree $pdir) | Should Be $expectedProfile
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'skips a profile directory that conflicts with a shared-root file and replaces with -PreferProfile' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $shared = Get-SharedRoot -Scratch $scratch
            New-Item -ItemType Directory -Force -Path $shared | Out-Null
            Set-Content -LiteralPath (Join-Path $shared 'agents') -Value 'root-file' -Encoding ASCII
            $pdirA = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            $pdirB = Get-ProfileDirFor -Scratch $scratch -Name 'work2'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdirA 'agents'), (Join-Path $pdirB 'agents') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdirA 'auth.json') -Value 'token-a' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdirA 'agents\a.md') -Value 'agent-a' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdirB 'auth.json') -Value 'token-b' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdirB 'agents\b.md') -Value 'agent-b' -Encoding ASCII

            $resultA = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdirA
            $resultA.Migrated | Should Be $true
            ($resultA.Lines -contains '  skip agents (conflict: shared root has a file where the profile has a directory; use --prefer-profile to override)') | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdirA 'agents\a.md')) | Should Be $true
            ((Get-Content -LiteralPath (Join-Path $shared 'agents') -Raw).Trim()) | Should Be 'root-file'

            $resultB = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdirB -PreferProfile
            $resultB.Migrated | Should Be $true
            (Test-Path -LiteralPath (Join-Path $shared 'agents') -PathType Container) | Should Be $true
            ((Get-Content -LiteralPath (Join-Path $shared 'agents\b.md') -Raw).Trim()) | Should Be 'agent-b'
            (Test-Path -LiteralPath (Join-Path $pdirB 'agents')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'skips credential lookalikes inside shared dirs in per-file and whole-dir merges' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $shared = Get-SharedRoot -Scratch $scratch
            New-Item -ItemType Directory -Force -Path (Join-Path $shared 'agents') | Out-Null
            Set-Content -LiteralPath (Join-Path $shared 'agents\existing.md') -Value 'existing' -Encoding ASCII
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'agents'), (Join-Path $pdir 'sessions') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'agents\local.md') -Value 'local' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'agents\token.json') -Value 'decoy' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'sessions\real.jsonl') -Value 'session' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'sessions\auth.json') -Value 'decoy' -Encoding ASCII

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir

            $result.Migrated | Should Be $true
            ($result.Lines -contains '  skip agents/token.json (name matches a declared credential; left in profile)') | Should Be $true
            ($result.Lines -contains '  skip sessions/auth.json (name matches a declared credential; left in profile)') | Should Be $true
            ((Get-Content -LiteralPath (Join-Path $shared 'agents\local.md') -Raw).Trim()) | Should Be 'local'
            ((Get-Content -LiteralPath (Join-Path $shared 'agents\existing.md') -Raw).Trim()) | Should Be 'existing'
            ((Get-Content -LiteralPath (Join-Path $shared 'sessions\real.jsonl') -Raw).Trim()) | Should Be 'session'
            (Test-Path -LiteralPath (Join-Path $shared 'agents\token.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $shared 'sessions\auth.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir 'agents\token.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'sessions\auth.json')) | Should Be $true
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'deduplicates an identical already-migrated credential instead of moving it' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'auth') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'same-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'auth\auth.json') -Value 'same-token' -Encoding ASCII

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir

            $result.Migrated | Should Be $true
            ($result.Lines -contains '  remove duplicate credential auth.json (already migrated)') | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $false
            ((Get-Content -LiteralPath (Join-Path $pdir 'auth\auth.json') -Raw).Trim()) | Should Be 'same-token'
            $metadata = Get-Content -LiteralPath (Join-Path $pdir '.profile.json') -Raw | ConvertFrom-Json
            $metadata.schemaVersion | Should Be 2
            $metadata.adapterId | Should Be 'fixture'
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'launches through the accountOverlay runtime after migration' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = New-LegacyProfile -Scratch $scratch -Name 'work'
            Initialize-SharedRoot -Scratch $scratch | Out-Null
            (Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir).Migrated | Should Be $true

            $probeScript = Join-Path $scratch.Root 'capture.ps1'
            $capture = Join-Path $scratch.Root 'capture.json'
            @'
@{
  home = $env:FIXTURE_HOME
} | ConvertTo-Json | Set-Content -LiteralPath $env:CAPTURE_OUTPUT -Encoding UTF8
'@ | Set-Content -LiteralPath $probeScript -Encoding UTF8
            $probe = Join-Path $scratch.Root 'capture.cmd'
            "@powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$probeScript`"" | Set-Content -LiteralPath $probe -Encoding ASCII

            $launch = Invoke-MigrationLauncher -Scratch $scratch -Arguments @('launch', 'fixture/work') -Probe $probe -Capture $capture

            if ($launch.ExitCode -ne 0) { Write-Host $launch.Output }
            $launch.ExitCode | Should Be 0
            $captured = Get-Content -LiteralPath $capture -Raw | ConvertFrom-Json
            $runtime = $captured.home
            ((Get-Content -LiteralPath (Join-Path $runtime 'auth.json') -Raw).Trim()) | Should Be 'profile-token'
            ((Get-Content -LiteralPath (Join-Path $runtime 'keys\token.json') -Raw).Trim()) | Should Be 'nested-token'
            ((Get-Content -LiteralPath (Join-Path $runtime 'history.jsonl') -Raw).Trim()) | Should Be 'shared-history'
            ((Get-Content -LiteralPath (Join-Path $runtime 'config.toml') -Raw).Trim()) | Should Be 'shared-config'
            (Test-Path -LiteralPath (Join-Path $runtime 'agents\reviewer\agent.md')) | Should Be $true
        } finally { Remove-MigrationScratch $scratch }
    }
}
