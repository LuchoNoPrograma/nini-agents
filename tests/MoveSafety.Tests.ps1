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
$script:TransferModule = Get-Module MultiCli.Transfer

function New-MoveScratch {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("nini_move_" + [guid]::NewGuid().ToString('N'))
    $userHome = Join-Path $root 'home'
    $source = Join-Path $root 'source'
    $destination = Join-Path $root 'destination'
    New-Item -ItemType Directory -Force -Path $userHome, $source, $destination | Out-Null
    return [pscustomobject]@{ Root = $root; Home = $userHome; Source = $source; Destination = $destination }
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
    & $script:TransferModule { param($sourcePath, $stagingPath) Copy-MoveCandidateLocal -Source $sourcePath -Staging $stagingPath } $Source $Staging
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

    It 'covers every declared legacy and isolated path class' {
        $adapter = New-MoveAdapter
        $adapter.normalState | Add-Member -NotePropertyName runtimeSubdir -NotePropertyValue 'state'
        $adapter.normalState.unsafePaths = @('cache')
        $cases = @(
            @('bad:path', 'v2', 'accountOverlay', $false),
            @('.runtime/cache', 'v2', 'accountOverlay', $true),
            @('rules', 'v2', 'accountOverlay', $false),
            @('.isolated', 'v2', 'isolated', $true),
            @('state', 'v2', 'isolated', $true),
            @('other', 'v2', 'isolated', $false),
            @('state/rules/default.md', 'v2', 'isolated', $true),
            @('state/sessions/one.jsonl', 'v2', 'isolated', $true),
            @('state/cache/entry', 'v2', 'isolated', $true),
            @('.cli', 'legacy', 'legacy', $true),
            @('cache/entry', 'legacy', 'legacy', $true)
        )
        foreach ($case in $cases) {
            $actual = & $script:TransferModule {
                param($a, $path, $format, $mode)
                Test-MoveRelativeAllowed -Adapter $a -RelativePath $path -Format $format -Mode $mode
            } $adapter $case[0] $case[1] $case[2]
            $actual | Should Be $case[3]
        }
    }

    It 'rejects undeclared or ambiguous runtime hardlink targets' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $adapter.normalState | Add-Member -NotePropertyName runtimeSubdir -NotePropertyValue 'state'
            $profile = New-V2MoveProfile -Scratch $scratch
            $emptyTarget = [pscustomobject]@{ Target = @() }
            $undeclared = [pscustomobject]@{ Target = @((Join-Path $profile '.runtime\state\other.json')) }
            $expected = [pscustomobject]@{ Target = @((Join-Path $profile '.runtime\state\auth.json')) }

            (& $script:TransferModule {
                param($a, $p, $item)
                Test-MoveExpectedRuntimeHardLink -Adapter $a -ProfilePath $p -RelativePath 'auth/other.json' -Item $item -Mode 'accountOverlay'
            } $adapter $profile $undeclared) | Should Be $false
            (& $script:TransferModule {
                param($a, $p, $item)
                Test-MoveExpectedRuntimeHardLink -Adapter $a -ProfilePath $p -RelativePath 'auth/auth.json' -Item $item -Mode 'accountOverlay'
            } $adapter $profile $emptyTarget) | Should Be $false
            (& $script:TransferModule {
                param($a, $p, $item)
                Test-MoveExpectedRuntimeHardLink -Adapter $a -ProfilePath $p -RelativePath 'auth/auth.json' -Item $item -Mode 'accountOverlay'
            } $adapter $profile $expected) | Should Be $true
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'classifies missing, unsupported, malformed, linked, and unsafe profile shapes' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            $missing = Join-Path $scratch.Source 'missing'
            (& $script:TransferModule { param($a, $p) Test-MoveProfile -Adapter $a -ProfilePath $p } $adapter $missing).Code | Should Be 'source_missing'

            $outside = Join-Path $scratch.Root 'outside-profile'
            New-Item -ItemType Directory -Path $outside | Out-Null
            $linkedProfile = Join-Path $scratch.Source 'linked-profile'
            New-Item -ItemType Junction -Path $linkedProfile -Target $outside | Out-Null
            (& $script:TransferModule { param($a, $p) Test-MoveProfile -Adapter $a -ProfilePath $p } $adapter $linkedProfile).Code | Should Be 'unsafe_link'

            $unsupported = New-MoveAdapter
            $unsupported.account.mechanism = 'processSecret'
            $unsupportedProfile = Join-Path $scratch.Source 'unsupported'
            New-Item -ItemType Directory -Path $unsupportedProfile | Out-Null
            (& $script:TransferModule { param($a, $p) Test-MoveProfile -Adapter $a -ProfilePath $p } $unsupported $unsupportedProfile).Code | Should Be 'unsupported_mechanism'

            $metadataDirectory = Join-Path $scratch.Source 'metadata-directory'
            New-Item -ItemType Directory -Force -Path (Join-Path $metadataDirectory '.profile.json') | Out-Null
            (& $script:TransferModule { param($a, $p) Test-MoveProfile -Adapter $a -ProfilePath $p } $adapter $metadataDirectory).Code | Should Be 'invalid_metadata'

            $malformedMetadata = Join-Path $scratch.Source 'malformed-metadata'
            New-Item -ItemType Directory -Path $malformedMetadata | Out-Null
            'not-json' | Set-Content -LiteralPath (Join-Path $malformedMetadata '.profile.json') -Encoding ASCII
            (& $script:TransferModule { param($a, $p) Test-MoveProfile -Adapter $a -ProfilePath $p } $adapter $malformedMetadata).Code | Should Be 'invalid_metadata'

            $missingV2Credential = Join-Path $scratch.Source 'missing-v2-credential'
            New-Item -ItemType Directory -Path (Join-Path $missingV2Credential 'auth') | Out-Null
            '{"schemaVersion":2,"adapterId":"fixture","profileId":"fixture-profile","mode":"accountOverlay"}' |
                Set-Content -LiteralPath (Join-Path $missingV2Credential '.profile.json') -Encoding ASCII
            (& $script:TransferModule { param($a, $p) Test-MoveProfile -Adapter $a -ProfilePath $p } $adapter $missingV2Credential).Code | Should Be 'missing_credential'

            $credentialTarget = Join-Path $scratch.Root 'credential-target.json'
            '{"fixture":true}' | Set-Content -LiteralPath $credentialTarget -Encoding ASCII
            $linkedV2Credential = Join-Path $scratch.Source 'linked-v2-credential'
            New-Item -ItemType Directory -Path (Join-Path $linkedV2Credential 'auth') | Out-Null
            '{"schemaVersion":2,"adapterId":"fixture","profileId":"fixture-profile","mode":"accountOverlay"}' |
                Set-Content -LiteralPath (Join-Path $linkedV2Credential '.profile.json') -Encoding ASCII
            New-Item -ItemType SymbolicLink -Path (Join-Path $linkedV2Credential 'auth\auth.json') -Target $credentialTarget -ErrorAction Stop | Out-Null
            (& $script:TransferModule { param($a, $p) Test-MoveProfile -Adapter $a -ProfilePath $p } $adapter $linkedV2Credential).Code | Should Be 'unsafe_link'

            $missingLegacyCredential = Join-Path $scratch.Source 'missing-legacy-credential'
            New-Item -ItemType Directory -Path $missingLegacyCredential | Out-Null
            (& $script:TransferModule { param($a, $p) Test-MoveProfile -Adapter $a -ProfilePath $p } $adapter $missingLegacyCredential).Code | Should Be 'missing_credential'

            $invalidLegacyCredential = Join-Path $scratch.Source 'invalid-legacy-credential'
            New-Item -ItemType Directory -Path $invalidLegacyCredential | Out-Null
            'not-json' | Set-Content -LiteralPath (Join-Path $invalidLegacyCredential 'auth.json') -Encoding ASCII
            (& $script:TransferModule { param($a, $p) Test-MoveProfile -Adapter $a -ProfilePath $p } $adapter $invalidLegacyCredential).Code | Should Be 'invalid_auth_json'

            $linkedLegacyCredential = Join-Path $scratch.Source 'linked-legacy-credential'
            New-Item -ItemType Directory -Path $linkedLegacyCredential | Out-Null
            New-Item -ItemType SymbolicLink -Path (Join-Path $linkedLegacyCredential 'auth.json') -Target $credentialTarget -ErrorAction Stop | Out-Null
            (& $script:TransferModule { param($a, $p) Test-MoveProfile -Adapter $a -ProfilePath $p } $adapter $linkedLegacyCredential).Code | Should Be 'unsafe_link'

            $unsafeRuntime = Join-Path $scratch.Source 'unsafe-runtime'
            New-Item -ItemType Directory -Path (Join-Path $unsafeRuntime 'auth') | Out-Null
            '{"fixture":true}' | Set-Content -LiteralPath (Join-Path $unsafeRuntime 'auth\auth.json') -Encoding ASCII
            '{"schemaVersion":2,"adapterId":"fixture","profileId":"fixture-profile","mode":"accountOverlay"}' |
                Set-Content -LiteralPath (Join-Path $unsafeRuntime '.profile.json') -Encoding ASCII
            'not-a-directory' | Set-Content -LiteralPath (Join-Path $unsafeRuntime '.runtime') -Encoding ASCII
            (& $script:TransferModule { param($a, $p) Test-MoveProfile -Adapter $a -ProfilePath $p } $adapter $unsafeRuntime).Code | Should Be 'unsafe_link'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'covers internal false results without exposing profile content' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            New-V2MoveProfile -Scratch $scratch | Out-Null
            (& $script:TransferModule { param($root) Test-MoveTreesEqual -Left $root -Right (Join-Path $root 'missing') } $scratch.Source) | Should Be $false
            (& $script:TransferModule { Invoke-MoveProbe -Probe { 'indeterminate' } -Path 'synthetic' }).Valid | Should Be $false
            (& $script:TransferModule { param($path) Remove-MoveTransactionLock -Path $path } (Join-Path $scratch.Root 'missing-lock')).ToString() | Should Be 'False'

            Remove-Module MultiCli.Runtime -Force -ErrorAction SilentlyContinue
            (& $script:TransferModule { param($a, $p) New-MoveRuntimeOverlay -Adapter $a -ProfilePath $p } $adapter (Join-Path $scratch.Source 'account-a')) | Should Be $false
            Import-Module (Join-Path $script:RepoRoot 'lib\MultiCli.Runtime.psm1') -Force
            (& $script:TransferModule { param($p) New-MoveRuntimeOverlay -Adapter $null -ProfilePath $p } (Join-Path $scratch.Source 'account-a')) | Should Be $false
        } finally {
            if (-not (Get-Module MultiCli.Runtime)) { Import-Module (Join-Path $script:RepoRoot 'lib\MultiCli.Runtime.psm1') -Force }
            Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects invalid identifiers, callbacks, roots, and failed artifacts' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            New-V2MoveProfile -Scratch $scratch | Out-Null
            (Invoke-MultiCliProfileMove -Adapter $adapter -SourceRoot $scratch.Source -DestinationRoot $scratch.Destination `
                -ProfileName '..\escape' -OperationId 'fixture-op' -ProcessProbe $script:IdleProbe -TransportCopy $script:LocalCopy).Code | Should Be 'invalid_identifier'
            (Invoke-MultiCliProfileMove -Adapter $adapter -SourceRoot $scratch.Source -DestinationRoot $scratch.Destination `
                -ProfileName 'account-a' -OperationId 'fixture-op' -ProcessProbe $null -TransportCopy $script:LocalCopy).Code | Should Be 'invalid_callback'
            (Invoke-MultiCliProfileMove -Adapter $adapter -SourceRoot (Join-Path $scratch.Root 'missing-root') -DestinationRoot $scratch.Destination `
                -ProfileName 'account-a' -OperationId 'fixture-op' -ProcessProbe $script:IdleProbe -TransportCopy $script:LocalCopy).Code | Should Be 'unsafe_root'
            (Invoke-MultiCliProfileMove -Adapter $adapter -SourceRoot $scratch.Source -DestinationRoot $scratch.Source `
                -ProfileName 'account-a' -OperationId 'fixture-op' -ProcessProbe $script:IdleProbe -TransportCopy $script:LocalCopy).Code | Should Be 'unsafe_root'

            New-Item -ItemType Directory -Force -Path (Join-Path $scratch.Destination '.failed\account-a.fixture-op') | Out-Null
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter).Code | Should Be 'failed_artifact_conflict'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'fails closed when staging, locking, or destination ownership changes race preflight' {
        $adapter = New-MoveAdapter

        $scratch = New-MoveScratch
        try {
            New-V2MoveProfile -Scratch $scratch | Out-Null
            $script:StagingRaceCalls = 0
            $script:StagingRacePath = Join-Path $scratch.Destination '.staging'
            $stagingRaceProbe = {
                param($Path)
                $script:StagingRaceCalls++
                if ($script:StagingRaceCalls -eq 2) { 'collision' | Set-Content -LiteralPath $script:StagingRacePath -Encoding ASCII }
                return $false
            }
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Probe $stagingRaceProbe).Code | Should Be 'staging_create_failed'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }

        $scratch = New-MoveScratch
        try {
            New-V2MoveProfile -Scratch $scratch | Out-Null
            $script:LockRacePath = Join-Path $scratch.Source '.move-lock.account-a'
            $lockRaceCopy = {
                param($Source, $Staging)
                & $script:LocalCopy $Source $Staging
                New-Item -ItemType Directory -Path $script:LockRacePath | Out-Null
            }
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Copy $lockRaceCopy).Code | Should Be 'transaction_locked'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }

        $scratch = New-MoveScratch
        try {
            New-V2MoveProfile -Scratch $scratch | Out-Null
            $script:AppearingDestination = Join-Path $scratch.Destination 'account-a'
            $destinationRaceCopy = {
                param($Source, $Staging)
                & $script:LocalCopy $Source $Staging
                New-Item -ItemType Directory -Path $script:AppearingDestination | Out-Null
            }
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Copy $destinationRaceCopy).Code | Should Be 'destination_appeared'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rechecks process certainty while holding ownership lock' {
        $adapter = New-MoveAdapter
        $scratch = New-MoveScratch
        try {
            New-V2MoveProfile -Scratch $scratch | Out-Null
            $script:IndeterminateProbeCalls = 0
            $indeterminateAfterStaging = {
                param($Path)
                $script:IndeterminateProbeCalls++
                if ($script:IndeterminateProbeCalls -eq 3) { return 'indeterminate' }
                return $false
            }
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Probe $indeterminateAfterStaging).Code | Should Be 'process_probe_failed'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }

    }

    It 'preserves recoverable artifacts across every late rollback failure' {
        $adapter = New-MoveAdapter

        $scratch = New-MoveScratch
        try {
            New-V2MoveProfile -Scratch $scratch | Out-Null
            $script:ExistingFailedPath = Join-Path $scratch.Destination '.failed\account-a.fixture-op'
            $activationWithFailedArtifact = {
                param($Staging, $Destination)
                Move-Item -LiteralPath $Staging -Destination $Destination
                New-Item -ItemType Directory -Force -Path $script:ExistingFailedPath | Out-Null
                throw 'synthetic activation completion failure'
            }
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Activation $activationWithFailedArtifact).Code | Should Be 'rollback_failed'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }

        $scratch = New-MoveScratch
        try {
            New-V2MoveProfile -Scratch $scratch | Out-Null
            $script:RollbackCollisionPath = Join-Path $scratch.Source 'account-a'
            $invalidActivation = {
                param($Staging, $Destination)
                Move-Item -LiteralPath $Staging -Destination $Destination
                'not-json' | Set-Content -LiteralPath (Join-Path $Destination 'auth\auth.json') -Encoding ASCII
            }
            $quarantineWithCollision = {
                param($Destination, $Failed)
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Failed) | Out-Null
                Move-Item -LiteralPath $Destination -Destination $Failed
                'collision' | Set-Content -LiteralPath $script:RollbackCollisionPath -Encoding ASCII
            }
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -Activation $invalidActivation -Quarantine $quarantineWithCollision).Code | Should Be 'rollback_failed'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }

        $scratch = New-MoveScratch
        try {
            New-V2MoveProfile -Scratch $scratch | Out-Null
            $throwingRuntime = { param($Adapter, $Destination) throw 'synthetic runtime exception' }
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -RuntimeBuilder $throwingRuntime).Code | Should Be 'destination_runtime_failed_rolled_back'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }

        $scratch = New-MoveScratch
        try {
            New-V2MoveProfile -Scratch $scratch | Out-Null
            $tamperingRuntime = {
                param($Adapter, $Destination)
                '{"fixture":false}' | Set-Content -LiteralPath (Join-Path $Destination 'auth\auth.json') -Encoding ASCII
                return $true
            }
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -RuntimeBuilder $tamperingRuntime).Code | Should Be 'destination_invalid_rolled_back'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }

        $scratch = New-MoveScratch
        try {
            New-V2MoveProfile -Scratch $scratch | Out-Null
            $script:LockReleaseFailurePath = Join-Path $scratch.Source '.move-lock.account-a\child.txt'
            $lockBlockingRuntime = {
                param($Adapter, $Destination)
                'keep-lock' | Set-Content -LiteralPath $script:LockReleaseFailurePath -Encoding ASCII
                return $true
            }
            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter -RuntimeBuilder $lockBlockingRuntime
            $result.Code | Should Be 'lock_release_failed'
            $result.State | Should Be 'destination_active'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects a source mutation detected only after acquiring the ownership lock' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            New-V2MoveProfile -Scratch $scratch | Out-Null
            $global:NiniMoveTreeComparisons = 0
            Mock Test-MoveTreesEqual -ModuleName MultiCli.Transfer {
                $global:NiniMoveTreeComparisons++
                return $global:NiniMoveTreeComparisons -ne 2
            }
            (Invoke-FixtureMove -Scratch $scratch -Adapter $adapter).Code | Should Be 'integrity_mismatch'
        } finally {
            $global:NiniMoveTreeComparisons = 100
            Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps the source active when the backup directory cannot be prepared' {
        $scratch = New-MoveScratch
        try {
            $adapter = New-MoveAdapter
            New-V2MoveProfile -Scratch $scratch | Out-Null
            $global:NiniMoveBackupFailurePath = Join-Path $scratch.Source '.inactive'
            Mock New-Item -ModuleName MultiCli.Transfer {
                param($ItemType, $Force, $Path, $ErrorAction)
                if ($Path -eq $global:NiniMoveBackupFailurePath) { throw 'synthetic backup preparation failure' }
                return [System.IO.Directory]::CreateDirectory([string]$Path)
            }
            $result = Invoke-FixtureMove -Scratch $scratch -Adapter $adapter
            $result.Code | Should Be 'backup_prepare_failed'
            $result.State | Should Be 'source_active'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
