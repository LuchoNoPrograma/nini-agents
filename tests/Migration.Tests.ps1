# Real-execution tests for the legacy -> schema-v2 migration engine in
# lib/MultiCli.Migration.psm1 (Windows PowerShell 5.1, Pester 3.4).
# Every test builds a real legacy profile tree under a temp scratch root and
# invokes the module directly. One rollback case injects only the metadata
# failure boundary after real filesystem moves; credentials remain synthetic.

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
    param($Scratch, $Adapter, [string]$ProfileDir, [switch]$DryRun, [switch]$PreferProfile, [switch]$PreserveUnknown, [scriptblock]$ProcessProbe)
    $oldHome = $env:USERPROFILE
    $env:USERPROFILE = $Scratch.UserHome
    try {
        $parameters = @{ Adapter = $Adapter; ProfileDir = $ProfileDir }
        if ($DryRun) { $parameters.DryRun = $true }
        if ($PreferProfile) { $parameters.PreferProfile = $true }
        if ($PreserveUnknown) { $parameters.PreserveUnknown = $true }
        if ($ProcessProbe) { $parameters.ProcessProbe = $ProcessProbe }
        return Invoke-MultiCliMigration @parameters
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

Describe 'Invoke-MultiCliMigration preserve unknown' {
    It 'plans inactive recovery in dry-run without writing' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'keys'), (Join-Path $pdir 'tmp') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'keys\token.json') -Value 'nested-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'keys\rogue.txt') -Value 'rogue' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'tmp\item') -Value 'temporary' -Encoding ASCII
            $auth = Get-Item -LiteralPath (Join-Path $pdir 'auth.json')
            $authLength = $auth.Length
            $authWriteTime = $auth.LastWriteTimeUtc

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun -PreserveUnknown

            $result.Mode | Should Be 'dry-run'
            $result.Lines | Should Contain '  preserve unknown state keys/rogue.txt in inactive recovery (--preserve-unknown)'
            $result.Lines | Should Contain '  preserve unknown state tmp in inactive recovery (--preserve-unknown)'
            $authAfter = Get-Item -LiteralPath (Join-Path $pdir 'auth.json')
            $authAfter.Length | Should Be $authLength
            $authAfter.LastWriteTimeUtc | Should Be $authWriteTime
            (Test-Path -LiteralPath (Join-Path $pdir 'auth\auth.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $scratch.Profiles '.inactive')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'renames unknown objects inactive and preserves the credential object' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'tmp') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'custom.txt') -Value 'artifact' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'tmp\item') -Value 'temporary' -Encoding ASCII
            $auth = Get-Item -LiteralPath (Join-Path $pdir 'auth.json')
            $unknown = Get-Item -LiteralPath (Join-Path $pdir 'custom.txt')
            $inactive = Join-Path $scratch.Profiles '.inactive\migrations\fixture\work\unknown-state'

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -PreserveUnknown -ProcessProbe { param($Path) 'idle' }

            $result.Migrated | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $false
            $authAfter = Get-Item -LiteralPath (Join-Path $pdir 'auth\auth.json')
            $authAfter.Length | Should Be $auth.Length
            $authAfter.LastWriteTimeUtc | Should Be $auth.LastWriteTimeUtc
            (Test-Path -LiteralPath (Join-Path $pdir 'custom.txt')) | Should Be $false
            $unknownAfter = Get-Item -LiteralPath (Join-Path $inactive 'custom.txt')
            $unknownAfter.Length | Should Be $unknown.Length
            $unknownAfter.LastWriteTimeUtc | Should Be $unknown.LastWriteTimeUtc
            (Test-Path -LiteralPath (Join-Path $inactive 'tmp\item')) | Should Be $true
            $journal = Get-Content -LiteralPath (Join-Path $pdir '.migration-journal.json') -Raw | ConvertFrom-Json
            $journal.preserveUnknown | Should Be $true
            $journal.action | Should Match ([regex]::Escape('--preserve-unknown'))
            @($journal.operations | Where-Object { $_.op -eq 'preserve-unknown' -and $_.status -eq 'done' }).Count | Should Be 2
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'restores unknown objects during automatic rollback' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'tmp') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'tmp\item') -Value 'temporary' -Encoding ASCII
            Mock Write-MigrationProfileMetadata { throw 'synthetic metadata failure' } -ModuleName MultiCli.Migration

            $message = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -PreserveUnknown -ProcessProbe { param($Path) 'idle' }
            }

            $message | Should Match 'Automatic rollback restored the legacy layout'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth\auth.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir 'tmp\item')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $scratch.Profiles '.inactive')) | Should Be $false
            $journal = Get-Content -LiteralPath (Join-Path $pdir '.migration-journal.json') -Raw | ConvertFrom-Json
            $journal.preserveUnknown | Should Be $true
            $journal.action | Should Match ([regex]::Escape('--preserve-unknown'))
            @($journal.operations | Where-Object { $_.op -eq 'preserve-unknown' -and $_.status -eq 'rolled-back' }).Count | Should Be 1
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'never overrides unsafe declarations' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $adapter.normalState.unsafePaths = @('forbidden')
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path $pdir | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'forbidden') -Value 'unsafe' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'mystery.txt') -Value 'unknown' -Encoding ASCII

            $message = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun -PreserveUnknown
            }

            $message | Should Match ([regex]::Escape('  unsafe: forbidden'))
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'forbidden')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'mystery.txt')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $scratch.Profiles '.inactive')) | Should Be $false
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

    It 'preserves a modern Codex SQLite family inactive in a dry-run' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ai-tools\codex\adapter.json') -Raw | ConvertFrom-Json
            $pdir = Join-Path $scratch.Profiles 'codex\modern'
            New-Item -ItemType Directory -Force -Path $pdir | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'synthetic-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'state_5.sqlite') -Value 'synthetic-state' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'state_5.sqlite-shm') -Value 'synthetic-shm' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'state_5.sqlite-wal') -Value 'synthetic-wal' -Encoding ASCII

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun

            $result.Mode | Should Be 'dry-run'
            $result.Lines | Should Contain '  preserve profile state state_5.sqlite in inactive recovery'
            $result.Lines | Should Contain '  preserve profile state state_5.sqlite-shm in inactive recovery'
            $result.Lines | Should Contain '  preserve profile state state_5.sqlite-wal in inactive recovery'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth\auth.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.profile.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'plans inactive preservation for modern Codex MCP OAuth state without writes' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ai-tools\codex\adapter.json') -Raw | ConvertFrom-Json
            $pdir = Join-Path $scratch.Profiles 'codex\modern'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'mcp-oauth-locks'), (Join-Path $pdir 'mcp-oauth-locks.before-test'), (Join-Path $pdir 'cache'), (Join-Path $pdir 'shell_snapshots'), (Join-Path $pdir 'thread-writer-locks') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'synthetic-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir '.credentials.json') -Value '{}' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir '.credentials.json.before-test') -Value '{}' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'cache\item') -Value 'generated' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'models_cache.json') -Value 'generated' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'shell_snapshots\shell') -Value 'session' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'thread-writer-locks\writer') -Value 'session' -Encoding ASCII
            $credential = Get-Item -LiteralPath (Join-Path $pdir 'auth.json')
            $credentialLength = $credential.Length
            $credentialWriteTime = $credential.LastWriteTimeUtc

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun

            $result.Mode | Should Be 'dry-run'
            $result.Lines | Should Contain '  preserve shared credential .credentials.json in inactive recovery'
            $result.Lines | Should Contain '  preserve shared credential mcp-oauth-locks in inactive recovery'
            $result.Lines | Should Contain '  preserve shared credential .credentials.json.before-test in inactive recovery'
            $result.Lines | Should Contain '  preserve shared credential mcp-oauth-locks.before-test in inactive recovery'
            $result.Lines | Should Contain '  preserve runtime state cache in inactive recovery'
            $result.Lines | Should Contain '  preserve runtime state models_cache.json in inactive recovery'
            ($result.Lines -join "`n") | Should Match 'merge session shell_snapshots'
            $result.Lines | Should Contain '  preserve profile state thread-writer-locks in inactive recovery'
            $credentialAfter = Get-Item -LiteralPath (Join-Path $pdir 'auth.json')
            $credentialAfter.Length | Should Be $credentialLength
            $credentialAfter.LastWriteTimeUtc | Should Be $credentialWriteTime
            (Test-Path -LiteralPath (Join-Path $pdir 'auth\auth.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $scratch.Profiles '.inactive')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $scratch.Profiles '.shared\codex\mcp')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.profile.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'keeps only the six unproven Codex residue paths unknown' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ai-tools\codex\adapter.json') -Raw | ConvertFrom-Json
            $pdir = Join-Path $scratch.Profiles 'codex\modern'
            New-Item -ItemType Directory -Force -Path $pdir, (Join-Path $pdir 'cache'), (Join-Path $pdir 'shell_snapshots'), (Join-Path $pdir 'thread-writer-locks'), (Join-Path $pdir 'mcp-oauth-locks.before-shared-supabase-20260721T202703Z'), (Join-Path $pdir '.tmp'), (Join-Path $pdir 'tmp') | Out-Null
            foreach ($rel in @('auth.json', '.sandbox_migration', 'models_cache.json', 'version.json', '.credentials.json.before-shared-supabase-20260721T202703Z', '.personality_migration', 'config.toml.bak-20260704', 'config.toml.bak-20260705-516-workaround', 'gpt-5.5-no-intermediary-updates.md')) {
                Set-Content -LiteralPath (Join-Path $pdir $rel) -Value 'synthetic' -Encoding ASCII
            }

            $message = Get-ThrownMessage { Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun }

            foreach ($rel in @('.personality_migration', '.tmp', 'tmp', 'config.toml.bak-20260704', 'config.toml.bak-20260705-516-workaround', 'gpt-5.5-no-intermediary-updates.md')) {
                $message | Should Match ([regex]::Escape("  unknown: $rel"))
            }
            foreach ($rel in @('.sandbox_migration', 'cache', 'models_cache.json', 'version.json', 'shell_snapshots', 'thread-writer-locks', '.credentials.json.before-shared-supabase-20260721T202703Z', 'mcp-oauth-locks.before-shared-supabase-20260721T202703Z')) {
                $message | Should Not Match ([regex]::Escape("unknown: $rel"))
            }
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $scratch.Profiles '.inactive')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'preserves legacy Codex MCP OAuth objects inactive during apply' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ai-tools\codex\adapter.json') -Raw | ConvertFrom-Json
            $pdir = Join-Path $scratch.Profiles 'codex\modern'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'mcp-oauth-locks'), (Join-Path $pdir 'mcp-oauth-locks.before-test'), (Join-Path $pdir 'cache'), (Join-Path $pdir 'thread-writer-locks') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'mcp-oauth-locks\owner') -Value 'synthetic-lock' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'synthetic-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir '.credentials.json') -Value '{"synthetic":"legacy"}' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir '.credentials.json.before-test') -Value '{}' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'cache\item') -Value 'generated' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'version.json') -Value 'generated' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'state_5.sqlite') -Value 'db' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'state_5.sqlite-shm') -Value 'shm' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'state_5.sqlite-wal') -Value 'wal' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'thread-writer-locks\writer') -Value 'lock' -Encoding ASCII
            $inactive = Join-Path $scratch.Profiles '.inactive\migrations\codex\modern\shared-credentials'
            $runtimeInactive = Join-Path $scratch.Profiles '.inactive\migrations\codex\modern\runtime-state'
            $profileStateInactive = Join-Path $scratch.Profiles '.inactive\migrations\codex\modern\profile-state'

            $result = Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -ProcessProbe { param($Path) 'idle' }

            $result.Migrated | Should Be $true
            (Test-Path -LiteralPath (Join-Path $inactive '.credentials.json') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $inactive 'mcp-oauth-locks') -PathType Container) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $inactive '.credentials.json.before-test') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $inactive 'mcp-oauth-locks.before-test') -PathType Container) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $runtimeInactive 'cache\item') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $runtimeInactive 'version.json') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $profileStateInactive 'state_5.sqlite') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $profileStateInactive 'state_5.sqlite-shm') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $profileStateInactive 'state_5.sqlite-wal') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $profileStateInactive 'thread-writer-locks\writer') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir '.credentials.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir 'mcp-oauth-locks')) | Should Be $false
            ((Get-Content -LiteralPath (Join-Path $inactive '.credentials.json') -Raw | ConvertFrom-Json).synthetic) | Should Be 'legacy'
            ((Get-Content -LiteralPath (Join-Path $inactive 'mcp-oauth-locks\owner') -Raw).Trim()) | Should Be 'synthetic-lock'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth\auth.json') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $scratch.Profiles '.shared\codex\mcp')) | Should Be $false
            $journal = Get-Content -LiteralPath (Join-Path $pdir '.migration-journal.json') -Raw | ConvertFrom-Json
            @($journal.operations | Where-Object { $_.op -eq 'preserve-shared-credential' -and $_.status -eq 'done' }).Count | Should Be 4
            @($journal.operations | Where-Object { $_.op -eq 'preserve-runtime-state' -and $_.status -eq 'done' }).Count | Should Be 2
            @($journal.operations | Where-Object { $_.op -eq 'preserve-profile-state' -and $_.status -eq 'done' }).Count | Should Be 4
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'restores legacy Codex MCP OAuth objects when metadata fails' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ai-tools\codex\adapter.json') -Raw | ConvertFrom-Json
            $pdir = Join-Path $scratch.Profiles 'codex\modern'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'mcp-oauth-locks'), (Join-Path $pdir 'cache'), (Join-Path $pdir 'thread-writer-locks') | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'synthetic-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir '.credentials.json') -Value '{}' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir '.credentials.json.before-test') -Value '{}' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'cache\item') -Value 'generated' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'state_5.sqlite') -Value 'db' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'state_5.sqlite-wal') -Value 'wal' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'thread-writer-locks\writer') -Value 'lock' -Encoding ASCII
            Mock Write-MigrationProfileMetadata { throw 'synthetic metadata failure' } -ModuleName MultiCli.Migration

            $message = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -ProcessProbe { param($Path) 'idle' }
            }

            $message | Should Match 'Automatic rollback restored the legacy layout'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth\auth.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.credentials.json') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'mcp-oauth-locks') -PathType Container) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir '.credentials.json.before-test') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'cache\item') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'state_5.sqlite') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'state_5.sqlite-wal') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'thread-writer-locks\writer') -PathType Leaf) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $scratch.Profiles '.inactive')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.profile.json')) | Should Be $false
            $journal = Get-Content -LiteralPath (Join-Path $pdir '.migration-journal.json') -Raw | ConvertFrom-Json
            $journal.status | Should Be 'rolled_back'
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
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $false
            @(Get-ChildItem -LiteralPath $pdir -Recurse -Force -Filter 'auth.json').Count | Should Be 1
            (Test-Path -LiteralPath (Join-Path $pdir '.migration.lock')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-rollback')) | Should Be $false
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
            ($result.Lines -contains '  keep shared link plugins (existing link retained)') | Should Be $true
            ($result.Lines | Where-Object { $_ -like '*target:*' } | Measure-Object).Count | Should Be 0
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

    It 'rolls a failed apply back to legacy and a re-run starts cleanly' {
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
            $journal.status | Should Be 'rolled_back'
            (@($journal.operations | Where-Object { $_.op -eq 'move-credential' -and $_.status -eq 'rolled-back' })).Count | Should Be 1
            (@($journal.operations | Where-Object { $_.op -eq 'merge-move' -and $_.status -eq 'failed' })).Count | Should Be 1
            (@($journal.operations | Where-Object { $_.status -eq 'pending' })).Count | Should BeGreaterThan 0
            ((Get-Content -LiteralPath (Join-Path $pdir 'auth.json') -Raw).Trim()) | Should Be 'profile-token'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth\auth.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir 'agents\agent.md')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $shared 'agents')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration.lock')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-rollback')) | Should Be $false

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

    It 'refuses active or indeterminate processes before writing' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = New-LegacyProfile -Scratch $scratch -Name 'work'

            $active = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -ProcessProbe { param($Path) 'busy' }
            }
            $active | Should Match 'active process'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration.lock')) | Should Be $false

            $unknown = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -ProcessProbe { param($Path) 'unknown' }
            }
            $unknown | Should Match 'could not prove that tool processes are stopped'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'restores credentials and shared state when metadata fails after a PreferProfile replacement' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $shared = Get-SharedRoot -Scratch $scratch
            New-Item -ItemType Directory -Force -Path $shared | Out-Null
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path $pdir | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'config.toml') -Value 'profile-config' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $shared 'config.toml') -Value 'shared-config' -Encoding ASCII
            Mock Write-MigrationProfileMetadata { throw 'synthetic metadata failure' } -ModuleName MultiCli.Migration

            $message = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -PreferProfile
            }

            $message | Should Match 'Automatic rollback restored the legacy layout'
            ((Get-Content -LiteralPath (Join-Path $pdir 'auth.json') -Raw).Trim()) | Should Be 'profile-token'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth\auth.json')) | Should Be $false
            ((Get-Content -LiteralPath (Join-Path $pdir 'config.toml') -Raw).Trim()) | Should Be 'profile-config'
            ((Get-Content -LiteralPath (Join-Path $shared 'config.toml') -Raw).Trim()) | Should Be 'shared-config'
            (Test-Path -LiteralPath (Join-Path $pdir '.profile.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration.lock')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-rollback')) | Should Be $false
            $journal = Get-Content -LiteralPath (Join-Path $pdir '.migration-journal.json') -Raw | ConvertFrom-Json
            $journal.status | Should Be 'rolled_back'
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'refuses a held lock and a process appearing after lock without moving credentials' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = New-LegacyProfile -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Path (Join-Path $pdir '.migration.lock') | Out-Null

            $locked = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -ProcessProbe { param($Path) 'idle' }
            }
            $locked | Should Match 'migration is already locked'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth')) | Should Be $false

            Remove-Item -LiteralPath (Join-Path $pdir '.migration.lock') -Force
            $script:MigrationProbeCalls = 0
            $appeared = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -ProcessProbe {
                    param($Path)
                    $script:MigrationProbeCalls += 1
                    if ($script:MigrationProbeCalls -eq 1) { return 'idle' }
                    return 'busy'
                }
            }
            $appeared | Should Match 'process appeared while acquiring the migration lock'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration.lock')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'refuses a hardlinked credential during planning before any write' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $adapter.normalState.sharedPaths += 'auth-alias.json'
            $adapter.normalState.filePaths += 'auth-alias.json'
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path $pdir | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            New-Item -ItemType HardLink -Path (Join-Path $pdir 'auth-alias.json') -Target (Join-Path $pdir 'auth.json') | Out-Null

            $message = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir
            }

            $message | Should Match "credential 'auth.json' is a hardlink"
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth-alias.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration.lock')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'refuses linked or cross-volume credential destinations before any write' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            $outside = Join-Path $scratch.Root 'outside-auth'
            New-Item -ItemType Directory -Force -Path $pdir, $outside | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            New-Item -ItemType Junction -Path (Join-Path $pdir 'auth') -Target $outside | Out-Null

            $linked = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun
            }

            $linked | Should Match "credential destination 'auth/auth.json' crosses a link"
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $outside 'auth.json')) | Should Be $false
            Remove-Item -LiteralPath (Join-Path $pdir 'auth') -Force
            New-Item -ItemType Directory -Path (Join-Path $pdir 'auth') | Out-Null
            Mock Get-MigrationVolumeRoot {
                param($Path)
                if ($Path -like '*\auth\auth.json') { return 'Z:\' }
                return 'C:\'
            } -ModuleName MultiCli.Migration

            $crossVolume = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun
            }

            $crossVolume | Should Match "credential 'auth.json' and its destination are on different volumes"
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth\auth.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'refuses linked shared destinations and stale control files even in dry-run' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            $shared = Get-SharedRoot -Scratch $scratch
            $outside = Join-Path $scratch.Root 'outside-shared'
            New-Item -ItemType Directory -Force -Path (Join-Path $pdir 'agents'), $shared, $outside | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'agents\agent.md') -Value 'agent' -Encoding ASCII
            New-Item -ItemType Junction -Path (Join-Path $shared 'agents') -Target $outside | Out-Null

            $linked = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun
            }

            $linked | Should Match "shared-state destination 'agents' crosses a link"
            (Test-Path -LiteralPath (Join-Path $outside 'agent.md')) | Should Be $false
            Remove-Item -LiteralPath (Join-Path $shared 'agents') -Force
            New-Item -ItemType File -Path (Join-Path $pdir '.migration-journal.json.tmp') | Out-Null

            $stale = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun
            }

            $stale | Should Match "unfinished migration control artifact '.migration-journal.json.tmp'"
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'blocks dry-run when stale recovery artifacts require inspection' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $pdir = New-LegacyProfile -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Path (Join-Path $pdir '.migration-rollback') | Out-Null

            $message = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir -DryRun
            }

            $message | Should Match 'recovery artifacts already exist'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-journal.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration.lock')) | Should Be $false
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'removes a shared root created by a handled failed migration' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $shared = Get-SharedRoot -Scratch $scratch
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path $pdir | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            (Test-Path -LiteralPath $shared) | Should Be $false
            Mock Write-MigrationProfileMetadata { throw 'synthetic metadata failure' } -ModuleName MultiCli.Migration

            $message = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir
            }

            $message | Should Match 'Automatic rollback restored the legacy layout'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth')) | Should Be $false
            (Test-Path -LiteralPath $shared) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-rollback')) | Should Be $false
            $journal = Get-Content -LiteralPath (Join-Path $pdir '.migration-journal.json') -Raw | ConvertFrom-Json
            $journal.status | Should Be 'rolled_back'
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'rolls credentials back when a state move would cross volumes' {
        $scratch = New-MigrationScratch
        try {
            $adapter = Write-MigrationAdapter -Scratch $scratch
            $shared = Get-SharedRoot -Scratch $scratch
            $pdir = Get-ProfileDirFor -Scratch $scratch -Name 'work'
            New-Item -ItemType Directory -Force -Path $pdir, $shared | Out-Null
            Set-Content -LiteralPath (Join-Path $pdir 'auth.json') -Value 'profile-token' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $pdir 'config.toml') -Value 'profile-config' -Encoding ASCII
            Mock Get-MigrationVolumeRoot {
                param($Path)
                if ($Path -like '*\profiles\fixture\work\config.toml') { return 'Z:\' }
                return 'C:\'
            } -ModuleName MultiCli.Migration

            $message = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir
            }

            $message | Should Match 'Automatic rollback restored the legacy layout'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir 'auth')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir 'config.toml')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $shared 'config.toml')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir '.migration-rollback')) | Should Be $false
            $journal = Get-Content -LiteralPath (Join-Path $pdir '.migration-journal.json') -Raw | ConvertFrom-Json
            $journal.status | Should Be 'rolled_back'
        } finally { Remove-MigrationScratch $scratch }
    }

    It 'preserves artifacts and marks rollback_failed when recovery cannot be proven' {
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
            Mock Undo-MigrationOps { return $false } -ModuleName MultiCli.Migration

            $message = Get-ThrownMessage {
                Invoke-Migration -Scratch $scratch -Adapter $adapter -ProfileDir $pdir
            }
            Unprotect-Directory -Path $shared

            $message | Should Match 'Automatic rollback could not prove'
            $message | Should Match 'Do not launch this profile'
            (Test-Path -LiteralPath (Join-Path $pdir 'auth.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $pdir 'auth\auth.json')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $pdir '.migration.lock')) | Should Be $false
            $journal = Get-Content -LiteralPath (Join-Path $pdir '.migration-journal.json') -Raw | ConvertFrom-Json
            $journal.status | Should Be 'rollback_failed'
        } finally {
            Unprotect-Directory -Path (Get-SharedRoot -Scratch $scratch)
            Remove-MigrationScratch $scratch
        }
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
