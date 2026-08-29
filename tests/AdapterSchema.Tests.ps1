$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:Validator = Join-Path $script:RepoRoot 'scripts\Validate-Adapters.ps1'

function New-AdapterSchemaScratch {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mcli_schema_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    return $root
}

function Write-TestAdapter {
    param([string]$Root, [string]$Directory, [string]$Json)
    $adapterDir = Join-Path $Root $Directory
    New-Item -ItemType Directory -Force -Path $adapterDir | Out-Null
    Set-Content -LiteralPath (Join-Path $adapterDir 'adapter.json') -Value $Json -Encoding UTF8
}

function Get-ValidV2AdapterJson {
    $adapter = [ordered]@{
        schemaVersion = 2
        id = 'test-cli'
        displayName = 'Test CLI'
        kind = 'cli'
        binary = [ordered]@{
            windows = @('test-cli.exe')
            macos = @('test-cli')
            linux = @('test-cli')
        }
        isolation = [ordered]@{
            strategy = 'accountOverlay'
            mode = 'foreground'
            env = [ordered]@{ TEST_HOME = '{runtimeRoot}' }
            clearEnv = @('GLOBAL_TEST_TOKEN')
        }
        account = [ordered]@{
            mechanism = 'fileOverlay'
            credentialFiles = @('auth.json')
            credentialPrecedence = @('auth.json')
            logoutScope = 'profile'
        }
        normalState = [ordered]@{
            root = [ordered]@{
                windows = '%USERPROFILE%\.test-cli'
                macos = '$HOME/.test-cli'
                linux = '$HOME/.test-cli'
            }
            sharedPaths = @('config.toml', 'agents', 'skills')
            sessionPaths = @('sessions', 'history.jsonl')
            unsafePaths = @('cache/account.sqlite')
        }
        concurrency = [ordered]@{
            level = 'multiWriter'
            singletonScope = 'none'
        }
        support = [ordered]@{
            windows = [ordered]@{ level = 'supported'; reason = 'File overlay with profile-local auth.json.' }
            macos = [ordered]@{ level = 'supported' }
            linux = [ordered]@{ level = 'supported' }
        }
        install = 'https://example.test/install'
        versionCommand = @('--version')
    }
    return ($adapter | ConvertTo-Json -Depth 12)
}

function Invoke-AdapterValidator {
    param([string]$Root)
    $process = New-Object System.Diagnostics.ProcessStartInfo
    $process.FileName = (Get-Command powershell.exe).Source
    $process.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script:Validator`" -ToolsRoot `"$Root`""
    $process.UseShellExecute = $false
    $process.RedirectStandardOutput = $true
    $process.RedirectStandardError = $true
    $process.CreateNoWindow = $true
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

Describe 'adapter schema validation' {
    It 'isolates main Codex auth and declares shared MCP OAuth state explicitly' {
        $codex = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ai-tools\codex\adapter.json') -Raw | ConvertFrom-Json

        (@($codex.binary.macos) -contains '$HOME/.local/bin/codex') | Should Be $true
        (@($codex.binary.linux) -contains '$HOME/.local/bin/codex') | Should Be $true
        (@($codex.normalState.sharedPaths) -contains 'rules') | Should Be $true
        (@($codex.normalState.sharedPaths) -contains 'AGENTS.md') | Should Be $true
        (@($codex.normalState.sharedPaths) -contains 'AGENTS.override.md') | Should Be $true
        (@($codex.normalState.sharedPaths) -contains 'log') | Should Be $true
        (@($codex.normalState.filePaths) -contains 'AGENTS.md') | Should Be $true
        (@($codex.normalState.filePaths) -contains 'AGENTS.override.md') | Should Be $true
        (@($codex.isolation.args) -join "`n") | Should Be (@(
            '-c', 'cli_auth_credentials_store="file"',
            '-c', 'mcp_oauth_credentials_store="file"',
            '-c', 'sqlite_home="{sharedStateRoot}"'
        ) -join "`n")
        (@($codex.normalState.sessionPaths) -contains 'state_5.sqlite') | Should Be $true
        (@($codex.normalState.sessionPaths) -contains 'shell_snapshots') | Should Be $true
        (@($codex.normalState.sessionPaths) -contains 'thread-writer-locks') | Should Be $true
        (@($codex.normalState.runtimePaths) -join "`n") | Should Be (@('.sandbox_migration', 'cache', 'models_cache.json', 'version.json') -join "`n")
        (@($codex.normalState.directPaths) -contains 'state_5.sqlite') | Should Be $true
        $expectedMigrationPreservePaths = @($codex.normalState.directPaths) + @('thread-writer-locks')
        (@($codex.normalState.migrationPreservePaths | Sort-Object) -join "`n") | Should Be (@($expectedMigrationPreservePaths | Sort-Object) -join "`n")
        (@($codex.normalState.migrationActivatePaths) -join "`n") | Should Be (@('config.toml', 'hooks.json', 'AGENTS.md', 'AGENTS.override.md', 'skills', 'agents', 'prompts', 'mcp-configs', 'plugins', 'rules') -join "`n")
        (@($codex.normalState.filePaths) -contains 'state_5.sqlite') | Should Be $true
        (@($codex.normalState.sharedPaths) -contains 'installation_id') | Should Be $true
        $codex.sharedCredentialState.root | Should Be '.shared/codex/mcp'
        $codex.sharedCredentialState.legacyMigration | Should Be 'preserveInactive'
        $codex.sharedCredentialState.legacyBackupPattern | Should Be 'dotSuffix'
        (@($codex.sharedCredentialState.entries.path) -join "`n") | Should Be (@('.credentials.json', 'mcp-oauth-locks') -join "`n")
        (@($codex.sharedCredentialState.entries.kind) -join "`n") | Should Be (@('jsonObjectFile', 'directory') -join "`n")
        (@($codex.normalState.unsafePaths) -contains '.credentials.json') | Should Be $false
        (@($codex.normalState.unsafePaths) -contains 'mcp-oauth-locks') | Should Be $false
        (@($codex.account.credentialFiles) -contains 'rules') | Should Be $false
        (@($codex.normalState.sessionPaths) -contains 'rules') | Should Be $false
    }

    It 'declares the documented Command Code user state directory as the shared root' {
        $adapter = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'ai-tools\commandcode\adapter.json') -Raw | ConvertFrom-Json

        $adapter.normalState.runtimeSubdir | Should Be '.commandcode'
        $adapter.normalState.root.windows | Should Be '%USERPROFILE%\.commandcode'
        $adapter.normalState.root.macos | Should Be '$HOME/.commandcode'
        $adapter.normalState.root.linux | Should Be '$HOME/.commandcode'
    }

    It 'accepts a complete schema-v2 account overlay' {
        $root = New-AdapterSchemaScratch
        try {
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json (Get-ValidV2AdapterJson)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 0
            $result.Output | Should Match 'Validated 1 adapter\(s\)'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts schema-v1 adapters for legacy compatibility' {
        $root = New-AdapterSchemaScratch
        try {
            $json = '{"id":"legacy","displayName":"Legacy","kind":"cli","binary":{"windows":["legacy.exe"],"macos":["legacy"],"linux":["legacy"]},"isolation":{"strategy":"env","env":{"LEGACY_HOME":"{profileDir}"}},"share":{"systemHome":"$HOME/.legacy","linkable":["config"],"neverLink":["auth.json"]},"status":"stable"}'
            Write-TestAdapter -Root $root -Directory 'legacy' -Json $json
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 0
            $result.Output | Should Match 'Validated 1 adapter\(s\)'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects malformed JSON with the adapter path' {
        $root = New-AdapterSchemaScratch
        try {
            Write-TestAdapter -Root $root -Directory 'broken' -Json '{"id":"broken"'
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match 'broken[\\/]adapter.json: invalid JSON'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects credential paths overlapping shared sessions' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.account.credentialFiles = @('sessions/auth.json')
            $adapter.normalState.sessionPaths = @('sessions')
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "credential path 'sessions/auth.json' overlaps session path 'sessions'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects shared paths overlapping session paths' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.normalState.sharedPaths = @('state')
            $adapter.normalState.sessionPaths = @('state/sessions')
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "shared path 'state' overlaps session path 'state/sessions'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects file paths not declared as shared or session state' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.normalState | Add-Member -NotePropertyName filePaths -NotePropertyValue @('undeclared.json')
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "file path 'undeclared.json' must also be declared in sharedPaths or sessionPaths"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts shared credential state below the adapter-owned store' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter | Add-Member -NotePropertyName sharedCredentialState -NotePropertyValue ([pscustomobject]@{
                root = '.shared/test-cli/mcp'
                entries = @(
                    [pscustomobject]@{ path = '.credentials.json'; kind = 'jsonObjectFile' },
                    [pscustomobject]@{ path = 'mcp-oauth-locks'; kind = 'directory' }
                )
                legacyMigration = 'preserveInactive'
            })
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts reconstructible runtime paths and dot-suffix credential backups' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.normalState | Add-Member -NotePropertyName runtimePaths -NotePropertyValue @('runtime-cache', 'models_cache.json')
            $adapter | Add-Member -NotePropertyName sharedCredentialState -NotePropertyValue ([pscustomobject]@{
                root = '.shared/test-cli/mcp'
                entries = @([pscustomobject]@{ path = '.credentials.json'; kind = 'jsonObjectFile' })
                legacyMigration = 'preserveInactive'
                legacyBackupPattern = 'dotSuffix'
            })
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects runtime paths overlapping state or credential backup namespaces' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.normalState | Add-Member -NotePropertyName runtimePaths -NotePropertyValue @('sessions/cache', '.credentials.json.before-test')
            $adapter | Add-Member -NotePropertyName sharedCredentialState -NotePropertyValue ([pscustomobject]@{
                root = '.shared/test-cli/mcp'
                entries = @([pscustomobject]@{ path = '.credentials.json'; kind = 'jsonObjectFile' })
                legacyMigration = 'preserveInactive'
                legacyBackupPattern = 'dotSuffix'
            })
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "session path 'sessions' overlaps runtime path 'sessions/cache'"
            $result.Output | Should Match "shared credential path '.credentials.json' overlaps runtime path '.credentials.json.before-test'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects shared credential roots outside the adapter-owned store' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter | Add-Member -NotePropertyName sharedCredentialState -NotePropertyValue ([pscustomobject]@{
                root = 'test-cli/mcp'
                entries = @([pscustomobject]@{ path = 'oauth.json'; kind = 'jsonObjectFile' })
                legacyMigration = 'preserveInactive'
            })
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "sharedCredentialState.root must be below '.shared/test-cli/'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects invalid and overlapping shared credential entries' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter | Add-Member -NotePropertyName sharedCredentialState -NotePropertyValue ([pscustomobject]@{
                root = '.shared/test-cli/mcp'
                entries = @(
                    [pscustomobject]@{ path = 'oauth'; kind = 'secretFile' },
                    [pscustomobject]@{ path = 'oauth/locks'; kind = 'directory' }
                )
                legacyMigration = 'copy'
            })
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "shared credential kind 'secretFile' is not supported"
            $result.Output | Should Match "shared credential path 'oauth' overlaps shared credential path 'oauth/locks'"
            $result.Output | Should Match "sharedCredentialState.legacyMigration must be 'preserveInactive'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects shared credential entries overlapping profile or normal state' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter | Add-Member -NotePropertyName sharedCredentialState -NotePropertyValue ([pscustomobject]@{
                root = '.shared/test-cli/mcp'
                entries = @(
                    [pscustomobject]@{ path = 'auth.json'; kind = 'jsonObjectFile' },
                    [pscustomobject]@{ path = 'sessions/oauth.json'; kind = 'jsonObjectFile' }
                )
                legacyMigration = 'preserveInactive'
            })
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "shared credential path 'auth.json' overlaps credential path 'auth.json'"
            $result.Output | Should Match "shared credential path 'sessions/oauth.json' overlaps session path 'sessions'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects direct paths not declared as shared or session state' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.normalState | Add-Member -NotePropertyName directPaths -NotePropertyValue @('undeclared.sqlite')
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "direct path 'undeclared.sqlite' must also be declared in sharedPaths or sessionPaths"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts migration preserve paths only as declared shared or session state' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.normalState | Add-Member -NotePropertyName migrationPreservePaths -NotePropertyValue @('history.jsonl', 'sessions')
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects unsafe or undeclared migration preserve paths' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.normalState | Add-Member -NotePropertyName migrationPreservePaths -NotePropertyValue @('../outside', 'undeclared.sqlite')
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "migration preserve path '../outside' must be a safe relative path"
            $result.Output | Should Match "migration preserve path 'undeclared.sqlite' must also be declared in sharedPaths or sessionPaths"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'accepts migration activate paths only as declared shared or session state' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.normalState | Add-Member -NotePropertyName migrationActivatePaths -NotePropertyValue @('config.toml', 'agents', 'sessions')
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 0
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects unsafe or undeclared migration activate paths' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.normalState | Add-Member -NotePropertyName migrationActivatePaths -NotePropertyValue @('../outside', 'undeclared.sqlite')
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "migration activate path '../outside' must be a safe relative path"
            $result.Output | Should Match "migration activate path 'undeclared.sqlite' must also be declared in sharedPaths or sessionPaths"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects unknown placeholders' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.isolation.env.TEST_HOME = '{mysteryRoot}'
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "unknown placeholder '\{mysteryRoot\}'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'requires a reason for unsupported support' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.support.windows = [pscustomobject]@{ level = 'unsupported' }
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "support.windows.reason is required for level 'unsupported'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects the retired experimental level with a clear message' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.support.windows = [pscustomobject]@{ level = 'experimental'; reason = 'legacy' }
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "support.windows.level 'experimental' was retired; use 'supported' or 'unsupported'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects retired evidenceId metadata' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter | Add-Member -NotePropertyName evidenceId -NotePropertyValue 'EV-1'
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "unsupported top-level field 'evidenceId'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects unknown nested fields' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.support.windows | Add-Member -NotePropertyName note -NotePropertyValue 'not part of the contract'
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "unsupported field 'support.windows.note'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects legacy fields in schema-v2' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter | Add-Member -NotePropertyName status -NotePropertyValue 'stable'
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "unsupported top-level field 'status'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects unknown schema-v1 nested fields' {
        $root = New-AdapterSchemaScratch
        try {
            $json = '{"id":"legacy","displayName":"Legacy","kind":"cli","binary":{"windows":["legacy"],"macos":["legacy"],"linux":["legacy"]},"isolation":{"strategy":"env","env":{"HOME":"{profileDir}"}},"share":{"systemHome":"$HOME/.legacy","linkable":["config"],"neverLink":["auth.json"],"note":"extra"},"status":"stable"}'
            Write-TestAdapter -Root $root -Directory 'legacy' -Json $json
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "unsupported field 'share.note'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects v1 linkable and neverLink overlap' {
        $root = New-AdapterSchemaScratch
        try {
            $json = '{"id":"legacy","displayName":"Legacy","kind":"cli","binary":{"windows":["legacy"],"macos":["legacy"],"linux":["legacy"]},"isolation":{"strategy":"env","env":{"HOME":"{profileDir}"}},"share":{"systemHome":"$HOME/.legacy","linkable":["auth.json"],"neverLink":["auth.json"]},"status":"stable"}'
            Write-TestAdapter -Root $root -Directory 'legacy' -Json $json
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match "share.linkable path 'auth.json' overlaps share.neverLink path 'auth.json'"
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
