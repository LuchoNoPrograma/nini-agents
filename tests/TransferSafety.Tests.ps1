$script:RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepoRoot 'lib\MultiCli.Runtime.psm1') -Force
Import-Module (Join-Path $script:RepoRoot 'lib\MultiCli.Transfer.psm1') -Force

# Allowlist-driven template/export/import safety for schema-v2 profiles.
# Real temp trees, real NTFS junctions/hardlinks, real zip archives. No mocks.

function New-TransferScratch {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mcli_transfer_" + [guid]::NewGuid().ToString('N'))
    $userHome = Join-Path $root 'home'
    $profiles = Join-Path $root 'profiles'
    New-Item -ItemType Directory -Force -Path $userHome, $profiles | Out-Null
    # Adapter root tokens expand %USERPROFILE%; point it at the scratch home so
    # the operator's real ~\.fixture is never touched.
    $previousHome = $env:USERPROFILE
    $env:USERPROFILE = $userHome
    return [pscustomobject]@{ Root = $root; UserHome = $userHome; Profiles = $profiles; PreviousHome = $previousHome }
}

function Remove-TransferScratch {
    param($Scratch)
    $env:USERPROFILE = $Scratch.PreviousHome
    # Windows PowerShell 5.1 Remove-Item -Recurse follows junctions (and would
    # walk the loop fixture forever). Walk without following reparse points and
    # delete each link itself, deepest first.
    $links = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((Get-Item -LiteralPath $Scratch.Root))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue) {
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                $links.Add($item)
                continue
            }
            if ($item.PSIsContainer) { $stack.Push($item) }
        }
    }
    foreach ($link in ($links | Sort-Object { $_.FullName.Length } -Descending)) {
        if (Test-Path -LiteralPath $link.FullName) {
            if ($link.PSIsContainer) { [System.IO.Directory]::Delete($link.FullName) } else { [System.IO.File]::Delete($link.FullName) }
        }
    }
    Remove-Item -LiteralPath $Scratch.Root -Recurse -Force -ErrorAction SilentlyContinue
}

function New-TransferAdapter {
    param([string]$Id = 'fixture')
    $adapter = [ordered]@{
        schemaVersion = 2
        id = $Id
        displayName = 'Fixture CLI'
        kind = 'cli'
        binary = [ordered]@{ windows = @('fixture.exe'); macos = @('fixture'); linux = @('fixture') }
        isolation = [ordered]@{
            strategy = 'accountOverlay'
            mode = 'foreground'
            env = [ordered]@{ FIXTURE_HOME = '{runtimeRoot}' }
            clearEnv = @()
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
    return ($adapter | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

# Populate the native shared root with ordinary state, sessions, and decoy
# credential files that must never travel.
function Write-TransferSharedState {
    param($Scratch)
    $shared = Join-Path $Scratch.UserHome '.fixture'
    New-Item -ItemType Directory -Force -Path (Join-Path $shared 'agents\nested'), (Join-Path $shared 'sessions') | Out-Null
    Set-Content -LiteralPath (Join-Path $shared 'config.toml') -Value 'model = "gpt-5"' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $shared 'agents\reviewer.md') -Value '# reviewer agent' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $shared 'agents\auth.json') -Value '{"OPENAI_API_KEY":"sk-decoy-nested"}' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $shared 'agents\nested\.credentials.json') -Value '{"token":"sk-decoy-deep"}' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $shared 'sessions\rollout.jsonl') -Value 'session-bytes' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $shared 'history.jsonl') -Value 'history-bytes' -Encoding ASCII
    return $shared
}

# Create a schema-v2 profile with real runtime links (junction for directories,
# hardlink for files) mirroring what New-RuntimeOverlay produces.
function Initialize-TransferProfile {
    param($Scratch, $Adapter, $Name, [string]$SharedRoot)
    $profileDir = Join-Path $Scratch.Profiles "fixture\$Name"
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
    Initialize-RuntimeProfile -Adapter $Adapter -ProfileDir $profileDir
    $runtime = Join-Path $profileDir '.runtime'
    New-Item -ItemType Directory -Force -Path $runtime | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $runtime 'agents') -Target (Join-Path $SharedRoot 'agents') | Out-Null
    New-Item -ItemType HardLink -Path (Join-Path $runtime 'config.toml') -Target (Join-Path $SharedRoot 'config.toml') | Out-Null
    return $profileDir
}

function Get-ThrownMessage {
    param([scriptblock]$Block)
    try { & $Block | Out-Null } catch { return $_.Exception.Message }
    return $null
}

function New-HostileZip {
    param([string]$Path, [hashtable[]]$Entries)
    $stream = [System.IO.File]::Open($Path, 'Create')
    $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($spec in $Entries) {
            $entry = $zip.CreateEntry($spec.Name)
            if ($spec.ContainsKey('ExternalAttributes')) { $entry.ExternalAttributes = $spec.ExternalAttributes }
            $writer = New-Object System.IO.StreamWriter($entry.Open())
            try { $writer.Write($spec.Content) } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
}

function Get-StagedManifestEntry {
    param([string]$AdapterId)
    $manifest = @{ schemaVersion = 2; adapterId = $AdapterId; name = 'staged'; kind = 'export'; createdUtc = '2026-07-17T00:00:00Z' } | ConvertTo-Json -Compress
    return @{ Name = '.multicli-manifest.json'; Content = $manifest }
}

function Get-ZipEntryNames {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        return @($zip.Entries | ForEach-Object { $_.FullName -replace '\\', '/' })
    } finally { $zip.Dispose(); $stream.Dispose() }
}

Describe 'schema-v2 transfer safety' {
    It 'template save copies only shared ordinary state and excludes credentials at root and nested' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $shared = Write-TransferSharedState $scratch
            New-Item -ItemType HardLink -Path (Join-Path $shared 'agents\hardlinked.md') -Target (Join-Path $shared 'config.toml') | Out-Null
            $profile = Initialize-TransferProfile -Scratch $scratch -Adapter $adapter -Name 'account-a' -SharedRoot $shared
            Set-Content -LiteralPath (Join-Path $profile 'auth\auth.json') -Value '{"OPENAI_API_KEY":"sk-live-must-stay"}' -Encoding ASCII
            $templates = Join-Path $scratch.Profiles '.templates'

            Save-MultiCliTemplate -Adapter $adapter -ProfileDir $profile -TemplatesRoot $templates -Name 'mytpl'

            $template = Join-Path $templates 'mytpl'
            (Test-Path -LiteralPath (Join-Path $template 'config.toml')) | Should Be $true
            ((Get-Content -LiteralPath (Join-Path $template 'config.toml') -Raw).Trim()) | Should Be 'model = "gpt-5"'
            (Test-Path -LiteralPath (Join-Path $template 'agents\reviewer.md')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $template '.multicli-manifest.json')) | Should Be $true
            # credential files are never included, at any depth
            (Test-Path -LiteralPath (Join-Path $template 'auth.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $template 'agents\auth.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $template 'agents\nested\.credentials.json')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $template 'agents\nested')) | Should Be $false
            # hardlinks are never included (they cannot be proven shareable)
            (Test-Path -LiteralPath (Join-Path $template 'agents\hardlinked.md')) | Should Be $false
            # sessions, runtime, auth boundary, and profile identity never travel
            (Test-Path -LiteralPath (Join-Path $template 'sessions')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $template 'history.jsonl')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $template '.runtime')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $template 'auth')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $template '.profile.json')) | Should Be $false
            $links = @(Get-ChildItem -LiteralPath $template -Recurse -Force | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
            $links.Count | Should Be 0
            $manifest = Get-Content -LiteralPath (Join-Path $template '.multicli-manifest.json') -Raw | ConvertFrom-Json
            $manifest.adapterId | Should Be 'fixture'
            $manifest.schemaVersion | Should Be 2
            $manifest.name | Should Be 'mytpl'
            $manifest.kind | Should Be 'template'
            ($manifest.createdUtc -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') | Should Be $true
        } finally { Remove-TransferScratch $scratch }
    }

    It 'template save excludes a nested junction into the shared root without following it' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $shared = Write-TransferSharedState $scratch
            $profile = Initialize-TransferProfile -Scratch $scratch -Adapter $adapter -Name 'account-a' -SharedRoot $shared
            New-Item -ItemType Junction -Path (Join-Path $shared 'agents\loop') -Target $shared | Out-Null
            $templates = Join-Path $scratch.Profiles '.templates'

            Save-MultiCliTemplate -Adapter $adapter -ProfileDir $profile -TemplatesRoot $templates -Name 'mytpl'

            $template = Join-Path $templates 'mytpl'
            (Test-Path -LiteralPath (Join-Path $template 'agents\reviewer.md')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $template 'agents\loop')) | Should Be $false
            $links = @(Get-ChildItem -LiteralPath $template -Recurse -Force | Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint })
            $links.Count | Should Be 0
        } finally { Remove-TransferScratch $scratch }
    }

    It 'template save refuses an overlay link pointing outside the profile shared state' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $shared = Write-TransferSharedState $scratch
            $profile = Initialize-TransferProfile -Scratch $scratch -Adapter $adapter -Name 'account-a' -SharedRoot $shared
            $outside = Join-Path $scratch.Root 'outside'
            New-Item -ItemType Directory -Force -Path $outside | Out-Null
            Set-Content -LiteralPath (Join-Path $outside 'secret.txt') -Value 'secret' -Encoding ASCII
            [System.IO.Directory]::Delete((Join-Path $profile '.runtime\agents'))
            New-Item -ItemType Junction -Path (Join-Path $profile '.runtime\agents') -Target $outside | Out-Null
            $templates = Join-Path $scratch.Profiles '.templates'

            $message = Get-ThrownMessage { Save-MultiCliTemplate -Adapter $adapter -ProfileDir $profile -TemplatesRoot $templates -Name 'mytpl' }

            $message | Should Not BeNullOrEmpty
            ($message.Contains('outside')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $templates 'mytpl')) | Should Be $false
        } finally { Remove-TransferScratch $scratch }
    }

    It 'template save refuses shared content that matches secret patterns' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $shared = Write-TransferSharedState $scratch
            $profile = Initialize-TransferProfile -Scratch $scratch -Adapter $adapter -Name 'account-a' -SharedRoot $shared
            Set-Content -LiteralPath (Join-Path $shared 'agents\notes.md') -Value 'note: use sk-live-12345 to authenticate' -Encoding ASCII
            $templates = Join-Path $scratch.Profiles '.templates'

            $message = Get-ThrownMessage { Save-MultiCliTemplate -Adapter $adapter -ProfileDir $profile -TemplatesRoot $templates -Name 'mytpl' }

            $message | Should Not BeNullOrEmpty
            ($message.Contains('secret')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $templates 'mytpl')) | Should Be $false
        } finally { Remove-TransferScratch $scratch }
    }

    It 'template save dry-run reports the plan and writes nothing' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $shared = Write-TransferSharedState $scratch
            $profile = Initialize-TransferProfile -Scratch $scratch -Adapter $adapter -Name 'account-a' -SharedRoot $shared
            $templates = Join-Path $scratch.Profiles '.templates'

            $output = @(Save-MultiCliTemplate -Adapter $adapter -ProfileDir $profile -TemplatesRoot $templates -Name 'mytpl' -DryRun) -join "`n"

            ($output.Contains('config.toml')) | Should Be $true
            ($output.Contains('agents/reviewer.md')) | Should Be $true
            (Test-Path -LiteralPath $templates) | Should Be $false
        } finally { Remove-TransferScratch $scratch }
    }

    It 'template validation refuses foreign adapters and tampered payload paths' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $other = New-TransferAdapter -Id 'fixture2'
            $shared = Write-TransferSharedState $scratch
            $profile = Initialize-TransferProfile -Scratch $scratch -Adapter $adapter -Name 'account-a' -SharedRoot $shared
            $templates = Join-Path $scratch.Profiles '.templates'
            Save-MultiCliTemplate -Adapter $adapter -ProfileDir $profile -TemplatesRoot $templates -Name 'mytpl'
            $template = Join-Path $templates 'mytpl'

            $message = Get-ThrownMessage { Assert-TransferTemplateCompatible -TemplateDir $template -Adapter $other }
            $message | Should Not BeNullOrEmpty
            ($message.Contains("cannot be applied to 'fixture2'")) | Should Be $true
            { Assert-TransferTemplateCompatible -TemplateDir $template -Adapter $adapter } | Should Not Throw

            New-Item -ItemType Directory -Force -Path (Join-Path $template 'auth') | Out-Null
            Set-Content -LiteralPath (Join-Path $template 'auth\auth.json') -Value '{"token":"sk-injected"}' -Encoding ASCII
            $message = Get-ThrownMessage { Assert-TransferTemplateCompatible -TemplateDir $template -Adapter $adapter }
            ($message.Contains("forbidden path 'auth'")) | Should Be $true
            Remove-Item -LiteralPath (Join-Path $template 'auth') -Recurse -Force

            Set-Content -LiteralPath (Join-Path $template 'random.txt') -Value 'undeclared' -Encoding ASCII
            $message = Get-ThrownMessage { Assert-TransferTemplateCompatible -TemplateDir $template -Adapter $adapter }
            ($message.Contains("undeclared path 'random.txt'")) | Should Be $true
        } finally { Remove-TransferScratch $scratch }
    }

    It 'export then import round-trips ordinary state with a fresh profile id and empty credential placeholders' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $shared = Write-TransferSharedState $scratch
            $profile = Initialize-TransferProfile -Scratch $scratch -Adapter $adapter -Name 'account-a' -SharedRoot $shared
            Set-Content -LiteralPath (Join-Path $profile 'auth\auth.json') -Value '{"OPENAI_API_KEY":"sk-live-must-stay"}' -Encoding ASCII
            $originalId = (Get-Content -LiteralPath (Join-Path $profile '.profile.json') -Raw | ConvertFrom-Json).profileId
            $archive = Join-Path $scratch.Root 'export.zip'

            Export-MultiCliProfile -Adapter $adapter -ProfileDir $profile -OutPath $archive -ProfileName 'account-a'

            (Test-Path -LiteralPath $archive) | Should Be $true
            $entries = Get-ZipEntryNames -Path $archive
            ($entries -contains 'config.toml') | Should Be $true
            ($entries -contains 'agents/reviewer.md') | Should Be $true
            ($entries -contains '.profile.json') | Should Be $true
            ($entries -contains '.multicli-manifest.json') | Should Be $true
            ($entries -contains 'auth.json') | Should Be $false
            ($entries -contains 'agents/auth.json') | Should Be $false
            ($entries -contains 'agents/nested/.credentials.json') | Should Be $false
            ($entries -contains 'sessions') | Should Be $false
            ($entries -contains 'history.jsonl') | Should Be $false

            $destination = Join-Path $scratch.Profiles 'fixture\account-b'
            Import-MultiCliProfile -Adapter $adapter -ArchivePath $archive -DestinationDir $destination

            ((Get-Content -LiteralPath (Join-Path $shared 'config.toml') -Raw).Trim()) | Should Be 'model = "gpt-5"'
            (Test-Path -LiteralPath (Join-Path $shared 'agents\reviewer.md')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $destination 'config.toml')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $destination 'sessions')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $destination 'history.jsonl')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $destination '.runtime')) | Should Be $false
            (Test-Path -LiteralPath (Join-Path $destination '.multicli-manifest.json')) | Should Be $false
            # a fresh stable identity is generated; the exported one is never reused
            $metadata = Get-Content -LiteralPath (Join-Path $destination '.profile.json') -Raw | ConvertFrom-Json
            $metadata.schemaVersion | Should Be 2
            $metadata.adapterId | Should Be 'fixture'
            $metadata.mode | Should Be 'accountOverlay'
            ([guid]::Parse($metadata.profileId) -is [guid]) | Should Be $true
            ($metadata.profileId -ne $originalId) | Should Be $true
            # credential placeholders are recreated empty; exported secrets never cross
            $placeholder = Get-Item -LiteralPath (Join-Path $destination 'auth\auth.json')
            $placeholder.Length | Should Be 0
        } finally { Remove-TransferScratch $scratch }
    }

    It 'isolated export and import preserve profile-local state and isolation mode' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $profile = Join-Path $scratch.Profiles 'fixture\iso-a'
            New-Item -ItemType Directory -Force -Path (Join-Path $profile 'agents') | Out-Null
            Set-Content -LiteralPath (Join-Path $profile 'config.toml') -Value 'isolated-config' -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $profile 'agents\reviewer.md') -Value 'isolated-agent' -Encoding ASCII
            [ordered]@{ schemaVersion = 2; adapterId = 'fixture'; profileId = [guid]::NewGuid().ToString(); mode = 'isolated' } |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $profile '.profile.json') -Encoding UTF8
            New-Item -ItemType File -Path (Join-Path $profile '.isolated') | Out-Null
            $shared = Join-Path $scratch.UserHome '.fixture'
            New-Item -ItemType Directory -Force -Path $shared | Out-Null
            Set-Content -LiteralPath (Join-Path $shared 'config.toml') -Value 'native-must-not-travel' -Encoding ASCII
            $archive = Join-Path $scratch.Root 'isolated.zip'

            Export-MultiCliProfile -Adapter $adapter -ProfileDir $profile -OutPath $archive -ProfileName 'iso-a'
            $destination = Join-Path $scratch.Profiles 'fixture\iso-b'
            Import-MultiCliProfile -Adapter $adapter -ArchivePath $archive -DestinationDir $destination

            ((Get-Content -LiteralPath (Join-Path $destination 'config.toml') -Raw).Trim()) | Should Be 'isolated-config'
            ((Get-Content -LiteralPath (Join-Path $shared 'config.toml') -Raw).Trim()) | Should Be 'native-must-not-travel'
            (Test-Path -LiteralPath (Join-Path $destination '.isolated')) | Should Be $true
            $metadata = Get-Content -LiteralPath (Join-Path $destination '.profile.json') -Raw | ConvertFrom-Json
            $metadata.mode | Should Be 'isolated'
            $metadata.adapterId | Should Be 'fixture'
        } finally { Remove-TransferScratch $scratch }
    }

    It 'import rejects archive entries that escape, qualify, stream, or duplicate paths' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $cases = @(
                @{ Kind = 'traversal'; Expected = 'escapes the profile directory'; Entries = @(@{ Name = '../evil.txt'; Content = 'evil' }) },
                @{ Kind = 'absolute'; Expected = 'absolute path'; Entries = @(@{ Name = '/evil.txt'; Content = 'evil' }) },
                @{ Kind = 'drive'; Expected = 'drive-qualified'; Entries = @(@{ Name = 'C:/evil.txt'; Content = 'evil' }) },
                @{ Kind = 'ads'; Expected = 'alternate data stream'; Entries = @(@{ Name = 'evil.txt:stream'; Content = 'evil' }) },
                @{ Kind = 'duplicate'; Expected = 'duplicate'; Entries = @(@{ Name = 'Config.toml'; Content = 'a' }, @{ Name = 'config.toml'; Content = 'b' }) }
            )
            foreach ($case in $cases) {
                $archive = Join-Path $scratch.Root "hostile-$($case.Kind).zip"
                New-HostileZip -Path $archive -Entries $case.Entries
                $destination = Join-Path $scratch.Profiles "fixture\evil-$($case.Kind)"

                $message = Get-ThrownMessage { Import-MultiCliProfile -Adapter $adapter -ArchivePath $archive -DestinationDir $destination }

                $message | Should Not BeNullOrEmpty
                ($message.Contains($case.Expected)) | Should Be $true
                (Test-Path -LiteralPath $destination) | Should Be $false
            }
        } finally { Remove-TransferScratch $scratch }
    }

    It 'import rejects link entries inside archives' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            # Unix mode 0120777 (symlink) shifted into the high attribute word.
            $symlinkMode = [int](2717847552L - 4294967296L)
            $archive = Join-Path $scratch.Root 'hostile-symlink.zip'
            New-HostileZip -Path $archive -Entries @(
                @{ Name = 'agents/sneaky-link.txt'; Content = ''; ExternalAttributes = $symlinkMode },
                (Get-StagedManifestEntry -AdapterId 'fixture')
            )
            $destination = Join-Path $scratch.Profiles 'fixture\evil-symlink'

            $message = Get-ThrownMessage { Import-MultiCliProfile -Adapter $adapter -ArchivePath $archive -DestinationDir $destination }

            $message | Should Not BeNullOrEmpty
            ($message.Contains('not a regular file or directory')) | Should Be $true
            (Test-Path -LiteralPath $destination) | Should Be $false
        } finally { Remove-TransferScratch $scratch }
    }

    It 'import rejects credential entries at root and nested' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $archiveRoot = Join-Path $scratch.Root 'cred-root.zip'
            New-HostileZip -Path $archiveRoot -Entries @(
                @{ Name = 'config.toml'; Content = 'model = "gpt-5"' },
                @{ Name = 'auth.json'; Content = '{"OPENAI_API_KEY":"sk-forged"}' },
                (Get-StagedManifestEntry -AdapterId 'fixture')
            )
            $destRoot = Join-Path $scratch.Profiles 'fixture\evil-cred-root'

            $message = Get-ThrownMessage { Import-MultiCliProfile -Adapter $adapter -ArchivePath $archiveRoot -DestinationDir $destRoot }

            $message | Should Not BeNullOrEmpty
            ($message.Contains('credential')) | Should Be $true
            (Test-Path -LiteralPath $destRoot) | Should Be $false

            $archiveNested = Join-Path $scratch.Root 'cred-nested.zip'
            New-HostileZip -Path $archiveNested -Entries @(
                @{ Name = 'agents/.credentials.json'; Content = 'x' },
                (Get-StagedManifestEntry -AdapterId 'fixture')
            )
            $destNested = Join-Path $scratch.Profiles 'fixture\evil-cred-nested'

            $message = Get-ThrownMessage { Import-MultiCliProfile -Adapter $adapter -ArchivePath $archiveNested -DestinationDir $destNested }

            $message | Should Not BeNullOrEmpty
            ($message.Contains('credential')) | Should Be $true
            (Test-Path -LiteralPath $destNested) | Should Be $false
        } finally { Remove-TransferScratch $scratch }
    }

    It 'import refuses archives with a foreign or missing adapter manifest' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $archiveForeign = Join-Path $scratch.Root 'foreign.zip'
            New-HostileZip -Path $archiveForeign -Entries @(
                @{ Name = 'config.toml'; Content = 'model = "gpt-5"' },
                (Get-StagedManifestEntry -AdapterId 'other-adapter')
            )
            $destForeign = Join-Path $scratch.Profiles 'fixture\foreign'

            $message = Get-ThrownMessage { Import-MultiCliProfile -Adapter $adapter -ArchivePath $archiveForeign -DestinationDir $destForeign }

            $message | Should Not BeNullOrEmpty
            ($message.Contains("cannot be imported as 'fixture'")) | Should Be $true
            (Test-Path -LiteralPath $destForeign) | Should Be $false

            $archiveBare = Join-Path $scratch.Root 'nomanifest.zip'
            New-HostileZip -Path $archiveBare -Entries @(
                @{ Name = 'config.toml'; Content = 'model = "gpt-5"' }
            )
            $destBare = Join-Path $scratch.Profiles 'fixture\nomanifest'

            $message = Get-ThrownMessage { Import-MultiCliProfile -Adapter $adapter -ArchivePath $archiveBare -DestinationDir $destBare }

            $message | Should Not BeNullOrEmpty
            ($message.Contains('no nini-agents manifest')) | Should Be $true
            (Test-Path -LiteralPath $destBare) | Should Be $false
        } finally { Remove-TransferScratch $scratch }
    }

    It 'import refuses staged content that matches secret patterns' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $archive = Join-Path $scratch.Root 'secret.zip'
            New-HostileZip -Path $archive -Entries @(
                @{ Name = 'config.toml'; Content = 'model = "gpt-5"' },
                @{ Name = 'agents/notes.md'; Content = 'Authorization: Bearer abc123' },
                (Get-StagedManifestEntry -AdapterId 'fixture')
            )
            $destination = Join-Path $scratch.Profiles 'fixture\secret'

            $message = Get-ThrownMessage { Import-MultiCliProfile -Adapter $adapter -ArchivePath $archive -DestinationDir $destination }

            $message | Should Not BeNullOrEmpty
            ($message.Contains('secret')) | Should Be $true
            (Test-Path -LiteralPath $destination) | Should Be $false
        } finally { Remove-TransferScratch $scratch }
    }

    It 'export refuses shared content that matches secret patterns and writes no archive' {
        $scratch = New-TransferScratch
        try {
            $adapter = New-TransferAdapter
            $shared = Write-TransferSharedState $scratch
            $profile = Initialize-TransferProfile -Scratch $scratch -Adapter $adapter -Name 'account-a' -SharedRoot $shared
            Set-Content -LiteralPath (Join-Path $shared 'config.toml') -Value '{"access_token":"ya29.forged"}' -Encoding ASCII
            $archive = Join-Path $scratch.Root 'export.zip'

            $message = Get-ThrownMessage { Export-MultiCliProfile -Adapter $adapter -ProfileDir $profile -OutPath $archive -ProfileName 'account-a' }

            $message | Should Not BeNullOrEmpty
            ($message.Contains('secret')) | Should Be $true
            (Test-Path -LiteralPath $archive) | Should Be $false
        } finally { Remove-TransferScratch $scratch }
    }
}
