<#
  Transactional credential-bearing movement tests. All roots, credentials,
  transports and process probes are synthetic and disposable.
#>

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:ModulePath = Join-Path $script:RepoRoot 'lib\MultiCli.Transfer.psm1'

function global:Resolve-PathToken {
    param([string]$Path)
    if (-not $Path) { return $Path }
    $expanded = $Path.Replace('$HOME', $env:USERPROFILE)
    return [Environment]::ExpandEnvironmentVariables($expanded)
}

Import-Module $script:ModulePath -Force

function New-MoveScratch {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("nini_move_" + [guid]::NewGuid().ToString('N'))
    $home = Join-Path $root 'home'
    $source = Join-Path $root 'source'
    $destination = Join-Path $root 'destination'
    New-Item -ItemType Directory -Force -Path $home, $source, $destination | Out-Null
    return [pscustomobject]@{ Root = $root; Home = $home; Source = $source; Destination = $destination }
}

function New-MoveAdapter {
    return ([ordered]@{
        schemaVersion = 2
        id = 'fixture'; displayName = 'Fixture CLI'; kind = 'cli'
        binary = [ordered]@{ windows = @('fixture.exe'); macos = @('fixture'); linux = @('fixture') }
        isolation = [ordered]@{ strategy = 'accountOverlay'; mode = 'foreground'; env = [ordered]@{ FIXTURE_HOME = '{runtimeRoot}' }; clearEnv = @() }
        account = [ordered]@{ mechanism = 'fileOverlay'; credentialFiles = @('auth.json'); credentialPrecedence = @('auth.json'); logoutScope = 'profile' }
        normalState = [ordered]@{
            root = [ordered]@{ windows = '%USERPROFILE%\.fixture'; macos = '$HOME/.fixture'; linux = '$HOME/.fixture' }
            sharedPaths = @('config.toml', 'rules'); sessionPaths = @('sessions', 'history.jsonl')
            filePaths = @('config.toml', 'history.jsonl'); unsafePaths = @()
        }
        concurrency = [ordered]@{ level = 'multiWriter'; singletonScope = 'none' }
        support = [ordered]@{
            windows = [ordered]@{ level = 'supported' }; macos = [ordered]@{ level = 'supported' }; linux = [ordered]@{ level = 'supported' }
        }
        install = 'https://example.test/install'; versionCommand = @('--version')
    } | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

function New-LegacyMoveProfile {
    param($Scratch)
    $profile = Join-Path $Scratch.Source 'account-a'
    New-Item -ItemType Directory -Force -Path (Join-Path $profile 'rules'), (Join-Path $profile 'sessions') | Out-Null
    '{"fixture":true}' | Set-Content -LiteralPath (Join-Path $profile 'auth.json') -Encoding ASCII
    'model = "fixture"' | Set-Content -LiteralPath (Join-Path $profile 'config.toml') -Encoding ASCII
    '# fixture rule' | Set-Content -LiteralPath (Join-Path $profile 'rules\default.md') -Encoding ASCII
    '{"session":"fixture"}' | Set-Content -LiteralPath (Join-Path $profile 'sessions\one.jsonl') -Encoding ASCII
    '{"history":"fixture"}' | Set-Content -LiteralPath (Join-Path $profile 'history.jsonl') -Encoding ASCII
    return $profile
}

function New-V2MoveProfile {
    param($Scratch)
    $profile = Join-Path $Scratch.Source 'account-a'
    New-Item -ItemType Directory -Force -Path (Join-Path $profile 'auth') | Out-Null
    '{"fixture":true}' | Set-Content -LiteralPath (Join-Path $profile 'auth\auth.json') -Encoding ASCII
    '{"schemaVersion":2,"adapterId":"fixture","profileId":"fixture-profile","mode":"accountOverlay"}' |
        Set-Content -LiteralPath (Join-Path $profile '.profile.json') -Encoding ASCII
    return $profile
}

$script:IdleProbe = { param($Path) return $false }
$script:BusyProbe = { param($Path) return $true }
$script:LocalCopy = {
    param($Source, $Staging)
    foreach ($item in (Get-ChildItem -LiteralPath $Source -Force)) {
        if ($item.Name -eq '.runtime') { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $Staging -Recurse -Force
    }
}

function Invoke-FixtureMove {
    param(
        $Scratch, $Adapter,
        [scriptblock]$Probe = $script:IdleProbe,
        [scriptblock]$Copy = $script:LocalCopy,
        [scriptblock]$Deactivation,
        [scriptblock]$Activation,
        [scriptblock]$Quarantine,
        [scriptblock]$RuntimeBuilder,
        [switch]$DryRun
    )
    return Invoke-MultiCliProfileMove -Adapter $Adapter -SourceRoot $Scratch.Source -DestinationRoot $Scratch.Destination `
        -ProfileName 'account-a' -OperationId 'fixture-op' -ProcessProbe $Probe -TransportCopy $Copy -Deactivation $Deactivation `
        -Activation $Activation -Quarantine $Quarantine -RuntimeBuilder $RuntimeBuilder -DryRun:$DryRun
}

Describe 'transactional profile movement' {
    It 'moves a legacy profile and keeps one inactive byte-identical backup' {
        $scratch = New-MoveScratch
        $previousHome = $env:USERPROFILE
        try {
            $env:USERPROFILE = $scratch.Home
            $adapter = New-MoveAdapter
            $profile = New-LegacyMoveProfile -Scratch $scratch
            $before = [System.IO.File]::ReadAllBytes((Join-Path $profile 'auth.json'))

            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter

            $result.Succeeded | Should Be $true
            $result.Code | Should Be 'ok'
            $result.State | Should Be 'destination_active'
            $result.Format | Should Be 'legacy'
            (Test-Path -LiteralPath $profile) | Should Be $false
            $destinationAuth = Join-Path $scratch.Destination 'account-a\auth.json'
            $backupAuth = Join-Path $scratch.Source '.inactive\account-a.fixture-op\auth.json'
            ([Convert]::ToBase64String([IO.File]::ReadAllBytes($destinationAuth))) | Should Be ([Convert]::ToBase64String($before))
            ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backupAuth))) | Should Be ([Convert]::ToBase64String($before))
        } finally { $env:USERPROFILE = $previousHome; Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'moves schema v2, rebuilds runtime, and preserves canonical credential bytes' {
        $scratch = New-MoveScratch
        $previousHome = $env:USERPROFILE
        try {
            $env:USERPROFILE = $scratch.Home
            $adapter = New-MoveAdapter
            $profile = New-V2MoveProfile -Scratch $scratch
            $before = [System.IO.File]::ReadAllBytes((Join-Path $profile 'auth\auth.json'))

            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter

            $result.Succeeded | Should Be $true
            $result.Format | Should Be 'v2'
            $destination = Join-Path $scratch.Destination 'account-a'
            ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $destination 'auth\auth.json')))) | Should Be ([Convert]::ToBase64String($before))
            ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $destination '.runtime\auth.json')))) | Should Be ([Convert]::ToBase64String($before))
        } finally { $env:USERPROFILE = $previousHome; Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'dry-runs without creating any transactional artifact' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $profile = New-V2MoveProfile -Scratch $scratch
            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -DryRun
            $result.Succeeded | Should Be $true
            $result.Code | Should Be 'dry_run'
            $result.State | Should Be 'validated'
            (Test-Path -LiteralPath $profile) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $scratch.Destination '.staging')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $scratch.Source '.inactive')) | Should Be $false
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects an existing destination before inspecting or copying credentials' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            New-V2MoveProfile -Scratch $scratch | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $scratch.Destination 'account-a') | Out-Null
            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter
            $result.Succeeded | Should Be $false
            $result.Code | Should Be 'destination_active'
            $result.Format | Should Be 'unknown'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects malformed auth JSON, mismatched metadata, and unknown content' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $profile = New-V2MoveProfile -Scratch $scratch
            'not-json' | Set-Content -LiteralPath (Join-Path $profile 'auth\auth.json') -Encoding ASCII
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter).Code | Should Be 'invalid_auth_json'

            '{"fixture":true}' | Set-Content -LiteralPath (Join-Path $profile 'auth\auth.json') -Encoding ASCII
            '{"schemaVersion":2,"adapterId":"other","profileId":"fixture-profile","mode":"accountOverlay"}' |
                Set-Content -LiteralPath (Join-Path $profile '.profile.json') -Encoding ASCII
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter).Code | Should Be 'invalid_metadata'

            '{"schemaVersion":2,"adapterId":"fixture","profileId":"fixture-profile","mode":"accountOverlay"}' |
                Set-Content -LiteralPath (Join-Path $profile '.profile.json') -Encoding ASCII
            'unknown' | Set-Content -LiteralPath (Join-Path $profile 'private.bin') -Encoding ASCII
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter).Code | Should Be 'unknown_content'
            (Test-Path -LiteralPath $profile) | Should Be $true
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects junctions and hardlinks without traversing them' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $profile = New-LegacyMoveProfile -Scratch $scratch
            $outside = Join-Path $scratch.Root 'outside'
            New-Item -ItemType Directory -Path $outside | Out-Null
            'keep' | Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Encoding ASCII
            $junction = Join-Path $profile 'rules\external'
            New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter).Code | Should Be 'unsafe_link'
            [System.IO.Directory]::Delete($junction)

            $hardlink = Join-Path $profile 'rules\alias.md'
            New-Item -ItemType HardLink -Path $hardlink -Target (Join-Path $profile 'rules\default.md') | Out-Null
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter).Code | Should Be 'unsafe_hardlink'
            (Get-Content -LiteralPath (Join-Path $outside 'keep.txt') -Raw).Trim() | Should Be 'keep'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects active processes and pre-existing staging or backup artifacts' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            New-V2MoveProfile -Scratch $scratch | Out-Null
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Probe $script:BusyProbe).Code | Should Be 'process_active'

            New-Item -ItemType Directory -Force -Path (Join-Path $scratch.Destination '.staging\account-a.fixture-op') | Out-Null
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter).Code | Should Be 'staging_conflict'
            Remove-Item -LiteralPath (Join-Path $scratch.Destination '.staging') -Recurse -Force

            New-Item -ItemType Directory -Force -Path (Join-Path $scratch.Source '.inactive\account-a.fixture-op') | Out-Null
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter).Code | Should Be 'backup_conflict'

            Remove-Item -LiteralPath (Join-Path $scratch.Source '.inactive') -Recurse -Force
            New-Item -ItemType Directory -Path (Join-Path $scratch.Source '.move-lock.account-a') | Out-Null
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter).Code | Should Be 'transaction_locked'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'preserves source and staging when transport bytes do not match' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $profile = New-V2MoveProfile -Scratch $scratch
            $tamperedCopy = {
                param($Source, $Staging)
                foreach ($item in (Get-ChildItem -LiteralPath $Source -Force)) {
                    if ($item.Name -eq '.runtime') { continue }
                    Copy-Item -LiteralPath $item.FullName -Destination $Staging -Recurse -Force
                }
                '{"fixture":false}' | Set-Content -LiteralPath (Join-Path $Staging 'auth\auth.json') -Encoding ASCII
            }
            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Copy $tamperedCopy
            $result.Code | Should Be 'integrity_mismatch'
            $result.State | Should Be 'staging_rejected'
            (Test-Path -LiteralPath $profile) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $scratch.Destination '.staging\account-a.fixture-op')) | Should Be $true
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'restores source when activation fails and preserves staging' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $profile = New-V2MoveProfile -Scratch $scratch
            $activation = { param($Staging, $Destination) throw 'synthetic activation failure' }
            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Activation $activation
            $result.Code | Should Be 'activation_failed_rolled_back'
            $result.State | Should Be 'source_restored'
            (Test-Path -LiteralPath $profile) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $scratch.Destination '.staging\account-a.fixture-op')) | Should Be $true
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'quarantines an invalid activated destination and restores source' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $profile = New-V2MoveProfile -Scratch $scratch
            $activation = {
                param($Staging, $Destination)
                Move-Item -LiteralPath $Staging -Destination $Destination
                '{"fixture":false}' | Set-Content -LiteralPath (Join-Path $Destination 'auth\auth.json') -Encoding ASCII
            }
            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Activation $activation
            $result.Code | Should Be 'destination_invalid_rolled_back'
            $result.State | Should Be 'source_restored'
            (Test-Path -LiteralPath $profile) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $scratch.Destination 'account-a')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $scratch.Destination '.failed\account-a.fixture-op')) | Should Be $true
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'requires a conclusive process probe and repeats it after staging' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $profile = New-V2MoveProfile -Scratch $scratch
            $failedProbe = { param($Path) throw 'synthetic probe failure' }
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Probe $failedProbe).Code | Should Be 'process_probe_failed'

            $script:MoveProbeCalls = 0
            $appearingProbe = {
                param($Path)
                $script:MoveProbeCalls++
                return $script:MoveProbeCalls -ge 3
            }
            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Probe $appearingProbe
            $result.Code | Should Be 'process_appeared'
            $result.State | Should Be 'staging_preserved'
            (Test-Path -LiteralPath $profile) | Should Be $true
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'keeps source active on transport and deactivation failures' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $profile = New-V2MoveProfile -Scratch $scratch
            $failedCopy = { param($Source, $Staging) throw 'synthetic transport failure' }
            $transportResult = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Copy $failedCopy
            $transportResult.Code | Should Be 'transport_failed'
            $transportResult.State | Should Be 'staging_preserved'
            (Test-Path -LiteralPath $profile) | Should Be $true

            Remove-Item -LiteralPath (Join-Path $scratch.Destination '.staging') -Recurse -Force
            $failedDeactivation = { param($Source, $Backup) throw 'synthetic deactivation failure' }
            $deactivationResult = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Deactivation $failedDeactivation
            $deactivationResult.Code | Should Be 'source_deactivation_failed'
            $deactivationResult.State | Should Be 'source_active'
            (Test-Path -LiteralPath $profile) | Should Be $true
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'restores source when runtime reconstruction fails' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $profile = New-V2MoveProfile -Scratch $scratch
            $failedRuntime = { param($Adapter, $Destination) return $false }
            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -RuntimeBuilder $failedRuntime
            $result.Code | Should Be 'destination_runtime_failed_rolled_back'
            $result.State | Should Be 'source_restored'
            (Test-Path -LiteralPath $profile) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $scratch.Destination '.failed\account-a.fixture-op')) | Should Be $true
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports indeterminate ownership without reactivating source when quarantine fails' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $profile = New-V2MoveProfile -Scratch $scratch
            $partialActivation = {
                param($Staging, $Destination)
                Move-Item -LiteralPath $Staging -Destination $Destination
                throw 'synthetic activation completion failure'
            }
            $failedQuarantine = { param($Destination, $Failed) throw 'synthetic quarantine failure' }
            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Activation $partialActivation -Quarantine $failedQuarantine
            $result.Code | Should Be 'rollback_failed'
            $result.State | Should Be 'ownership_indeterminate'
            (Test-Path -LiteralPath $profile) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $scratch.Source '.inactive\account-a.fixture-op')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $scratch.Destination 'account-a')) | Should Be $true
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects linked transaction roots before the transport runs' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $profile = New-V2MoveProfile -Scratch $scratch
            $outside = Join-Path $scratch.Root 'outside-transaction'
            New-Item -ItemType Directory -Path $outside | Out-Null
            New-Item -ItemType Junction -Path (Join-Path $scratch.Destination '.staging') -Target $outside | Out-Null
            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter
            $result.Code | Should Be 'unsafe_root'
            $result.Format | Should Be 'unknown'
            (Test-Path -LiteralPath $profile) | Should Be $true
            @(Get-ChildItem -LiteralPath $outside -Force).Count | Should Be 0
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts only the expected schema-v2 runtime credential hardlink' {
        $scratch = New-MoveScratch
        $previousHome = $env:USERPROFILE
        try {
            $env:USERPROFILE = $scratch.Home
            $adapter = New-MoveAdapter
            $profile = New-V2MoveProfile -Scratch $scratch
            $runtime = Join-Path $profile '.runtime'
            New-Item -ItemType Directory -Path $runtime | Out-Null
            New-Item -ItemType HardLink -Path (Join-Path $runtime 'auth.json') -Target (Join-Path $profile 'auth\auth.json') | Out-Null
            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter
            $result.Code | Should Be 'ok'
            $result.Format | Should Be 'v2'
        } finally { $env:USERPROFILE = $previousHome; Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
