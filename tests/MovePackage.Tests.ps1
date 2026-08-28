<# Portable credential-bearing move package tests. All data is synthetic. #>

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:ModulePath = Join-Path $script:RepoRoot 'lib\MultiCli.Transfer.psm1'

function global:Resolve-PathToken {
    param([string]$Path)
    if (-not $Path) { return $Path }
    return [Environment]::ExpandEnvironmentVariables($Path.Replace('$HOME', $env:USERPROFILE))
}

Import-Module $script:ModulePath -Force

function New-MovePackageScratch {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('nini_move_package_' + [guid]::NewGuid().ToString('N'))
    $sourceHome = Join-Path $root 'source-home'
    $destinationHome = Join-Path $root 'destination-home'
    $sourceRoot = Join-Path $root 'source-profiles'
    $destinationRoot = Join-Path $root 'destination-profiles'
    New-Item -ItemType Directory -Force -Path $sourceHome, $destinationHome, $sourceRoot, $destinationRoot | Out-Null
    return [pscustomobject]@{
        Root = $root; SourceHome = $sourceHome; DestinationHome = $destinationHome
        SourceRoot = $sourceRoot; DestinationRoot = $destinationRoot
    }
}

function New-MovePackageAdapter {
    return ([ordered]@{
        schemaVersion = 2; id = 'fixture'; displayName = 'Fixture CLI'; kind = 'cli'
        binary = [ordered]@{ windows = @('fixture.exe'); macos = @('fixture'); linux = @('fixture') }
        isolation = [ordered]@{ strategy = 'accountOverlay'; mode = 'foreground'; env = [ordered]@{ FIXTURE_HOME = '{runtimeRoot}' }; clearEnv = @() }
        account = [ordered]@{ mechanism = 'fileOverlay'; credentialFiles = @('auth.json'); credentialPrecedence = @('auth.json'); logoutScope = 'profile' }
        normalState = [ordered]@{
            root = [ordered]@{ windows = '%USERPROFILE%\.fixture'; macos = '$HOME/.fixture'; linux = '$HOME/.fixture' }
            sharedPaths = @('config.toml', 'skills'); sessionPaths = @('sessions', 'history.jsonl')
            filePaths = @('config.toml', 'history.jsonl'); unsafePaths = @()
        }
        concurrency = [ordered]@{ level = 'multiWriter'; singletonScope = 'none' }
        support = [ordered]@{
            windows = [ordered]@{ level = 'supported' }; macos = [ordered]@{ level = 'supported' }; linux = [ordered]@{ level = 'supported' }
        }
        install = 'https://example.test/install'; versionCommand = @('--version')
    } | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

function New-MovePackageFixture {
    param($Scratch)
    $profile = Join-Path $Scratch.SourceRoot 'account-a'
    New-Item -ItemType Directory -Force -Path (Join-Path $profile 'auth') | Out-Null
    '{"schemaVersion":2,"adapterId":"fixture","profileId":"fixture-profile","mode":"accountOverlay"}' |
        Set-Content -LiteralPath (Join-Path $profile '.profile.json') -Encoding ASCII
    '{"access_token":"synthetic-secret"}' | Set-Content -LiteralPath (Join-Path $profile 'auth\auth.json') -Encoding ASCII
    $state = Join-Path $Scratch.SourceHome '.fixture'
    New-Item -ItemType Directory -Force -Path (Join-Path $state 'skills\global'), (Join-Path $state 'sessions\chat-a') | Out-Null
    'model = "fixture"' | Set-Content -LiteralPath (Join-Path $state 'config.toml') -Encoding ASCII
    '# synthetic skill' | Set-Content -LiteralPath (Join-Path $state 'skills\global\SKILL.md') -Encoding ASCII
    '{"chat":"synthetic"}' | Set-Content -LiteralPath (Join-Path $state 'sessions\chat-a\session.jsonl') -Encoding ASCII
    [System.IO.File]::WriteAllBytes((Join-Path $state 'sessions\chat-a\large.bin'), (New-Object byte[] 245760))
    '{"history":"synthetic"}' | Set-Content -LiteralPath (Join-Path $state 'history.jsonl') -Encoding ASCII
    return $profile
}

$script:MovePackageIdleProbe = { param($Path) 'idle' }

Describe 'portable offline move packages' {
    It 'exports credentials chats and skills, deactivates source, and imports on another home' {
        $scratch = New-MovePackageScratch
        $previousHome = $env:USERPROFILE
        try {
            $env:USERPROFILE = $scratch.SourceHome
            $adapter = New-MovePackageAdapter
            $source = New-MovePackageFixture -Scratch $scratch
            $archive = Join-Path $scratch.Root 'account-a-move.zip'
            $exported = Export-MultiCliMovePackage -Adapter $adapter -ProfileDir $source -OutPath $archive -ProfileName 'account-a' -ProcessProbe $script:MovePackageIdleProbe

            (Test-Path -LiteralPath $source) | Should Be $false
            (Test-Path -LiteralPath $exported.BackupPath) | Should Be $true
            (Test-Path -LiteralPath $archive) | Should Be $true

            $env:USERPROFILE = $scratch.DestinationHome
            $destination = Join-Path $scratch.DestinationRoot 'account-a'
            Import-MultiCliMovePackage -Adapter $adapter -ArchivePath $archive -DestinationDir $destination -ProcessProbe $script:MovePackageIdleProbe | Out-Null

            ((Get-Content -LiteralPath (Join-Path $destination 'auth\auth.json') -Raw | ConvertFrom-Json).access_token) | Should Be 'synthetic-secret'
            (Test-Path -LiteralPath (Join-Path $destination '.runtime\auth.json')) | Should Be $true
            (Get-Content -LiteralPath (Join-Path $scratch.DestinationHome '.fixture\skills\global\SKILL.md') -Raw).Trim() | Should Be '# synthetic skill'
            (Get-Content -LiteralPath (Join-Path $scratch.DestinationHome '.fixture\sessions\chat-a\session.jsonl') -Raw).Trim() | Should Be '{"chat":"synthetic"}'
            (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $scratch.DestinationHome '.fixture\sessions\chat-a\large.bin')).Hash |
                Should Be (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $scratch.SourceHome '.fixture\sessions\chat-a\large.bin')).Hash
        } finally {
            $env:USERPROFILE = $previousHome
            Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects a shared-state conflict without activating the profile' {
        $scratch = New-MovePackageScratch
        $previousHome = $env:USERPROFILE
        try {
            $env:USERPROFILE = $scratch.SourceHome
            $adapter = New-MovePackageAdapter
            $source = New-MovePackageFixture -Scratch $scratch
            $archive = Join-Path $scratch.Root 'account-a-move.zip'
            Export-MultiCliMovePackage -Adapter $adapter -ProfileDir $source -OutPath $archive -ProfileName 'account-a' -ProcessProbe $script:MovePackageIdleProbe | Out-Null

            $env:USERPROFILE = $scratch.DestinationHome
            $conflict = Join-Path $scratch.DestinationHome '.fixture\skills\global\SKILL.md'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $conflict) | Out-Null
            '# conflicting skill' | Set-Content -LiteralPath $conflict -Encoding ASCII
            $destination = Join-Path $scratch.DestinationRoot 'account-a'
            $caught = $null
            try { Import-MultiCliMovePackage -Adapter $adapter -ArchivePath $archive -DestinationDir $destination -ProcessProbe $script:MovePackageIdleProbe }
            catch { $caught = $_.Exception.Message }
            $caught | Should Match 'conflicting file'
            (Test-Path -LiteralPath $destination) | Should Be $false
            (Get-Content -LiteralPath $conflict -Raw).Trim() | Should Be '# conflicting skill'
        } finally {
            $env:USERPROFILE = $previousHome
            Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses a ZIP with any entry besides the fixed NDJSON payload' {
        $scratch = New-MovePackageScratch
        $previousHome = $env:USERPROFILE
        try {
            $env:USERPROFILE = $scratch.SourceHome
            $adapter = New-MovePackageAdapter
            $source = New-MovePackageFixture -Scratch $scratch
            $archive = Join-Path $scratch.Root 'account-a-move.zip'
            Export-MultiCliMovePackage -Adapter $adapter -ProfileDir $source -OutPath $archive -ProfileName 'account-a' -ProcessProbe $script:MovePackageIdleProbe | Out-Null
            $stream = [System.IO.File]::Open($archive, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
            $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Update)
            try {
                $entry = $zip.CreateEntry('extra.txt')
                $writer = New-Object System.IO.StreamWriter($entry.Open())
                try { $writer.Write('extra') } finally { $writer.Dispose() }
            } finally { $zip.Dispose(); $stream.Dispose() }

            $env:USERPROFILE = $scratch.DestinationHome
            $destination = Join-Path $scratch.DestinationRoot 'account-a'
            $caught = $null
            try { Import-MultiCliMovePackage -Adapter $adapter -ArchivePath $archive -DestinationDir $destination -ProcessProbe $script:MovePackageIdleProbe }
            catch { $caught = $_.Exception.Message }
            $caught | Should Match 'exactly'
            (Test-Path -LiteralPath $destination) | Should Be $false
        } finally {
            $env:USERPROFILE = $previousHome
            Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
