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
            windows = [ordered]@{ level = 'experimental'; reason = 'Awaiting dual-account E2E.' }
            macos = [ordered]@{ level = 'experimental'; reason = 'Awaiting native E2E.' }
            linux = [ordered]@{ level = 'experimental'; reason = 'Awaiting native E2E.' }
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
    $stdout = $child.StandardOutput.ReadToEnd()
    $stderr = $child.StandardError.ReadToEnd()
    $child.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $child.ExitCode
        Output = "$stdout$stderr"
    }
}

Describe 'adapter schema validation' {
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

    It 'requires evidence for verified support' {
        $root = New-AdapterSchemaScratch
        try {
            $adapter = Get-ValidV2AdapterJson | ConvertFrom-Json
            $adapter.support.windows = [pscustomobject]@{ level = 'verified' }
            Write-TestAdapter -Root $root -Directory 'test-cli' -Json ($adapter | ConvertTo-Json -Depth 12)
            $result = Invoke-AdapterValidator -Root $root

            $result.ExitCode | Should Be 1
            $result.Output | Should Match 'support.windows.evidenceId is required for verified support'
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
