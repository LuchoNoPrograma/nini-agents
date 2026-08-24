$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:LauncherPath = Join-Path $script:RepoRoot 'nini-agents.ps1'

function New-PermissionsScratch {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("mcli_permissions_" + [guid]::NewGuid().ToString('N'))
    $userHome = Join-Path $root 'home'
    $profiles = Join-Path $root 'profiles'
    $tools = Join-Path $root 'tools'
    $codexTools = Join-Path $tools 'codex'
    New-Item -ItemType Directory -Force -Path $userHome, $profiles, $codexTools | Out-Null
    $adapter = [ordered]@{
        schemaVersion = 2
        id = 'codex'
        displayName = 'OpenAI Codex CLI'
        kind = 'cli'
        binary = [ordered]@{ windows = @('codex.cmd'); macos = @('codex'); linux = @('codex') }
        isolation = [ordered]@{ strategy = 'accountOverlay'; mode = 'foreground'; env = [ordered]@{ CODEX_HOME = '{runtimeRoot}' }; clearEnv = @() }
        account = [ordered]@{ mechanism = 'fileOverlay'; credentialFiles = @('auth.json'); credentialPrecedence = @('auth.json'); logoutScope = 'profile' }
        normalState = [ordered]@{
            root = [ordered]@{ windows = '%USERPROFILE%\.codex'; macos = '$HOME/.codex'; linux = '$HOME/.codex' }
            sharedPaths = @('config.toml')
            sessionPaths = @()
            filePaths = @('config.toml')
            unsafePaths = @()
        }
        concurrency = [ordered]@{ level = 'multiWriter'; singletonScope = 'none' }
        support = [ordered]@{
            windows = [ordered]@{ level = 'supported' }
            macos = [ordered]@{ level = 'supported' }
            linux = [ordered]@{ level = 'supported' }
        }
    }
    $adapter | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $codexTools 'adapter.json') -Encoding UTF8
    $probe = Join-Path $root 'codex.cmd'
    '@exit /b 0' | Set-Content -LiteralPath $probe -Encoding ASCII
    return [pscustomobject]@{ Root = $root; UserHome = $userHome; Profiles = $profiles; Tools = $tools; Probe = $probe }
}

function Invoke-PermissionsLauncher {
    param($Scratch, [string[]]$Arguments)
    $environment = @{
        USERPROFILE = $Scratch.UserHome
        HOME = $Scratch.UserHome
        APPDATA = (Join-Path $Scratch.UserHome 'AppData\Roaming')
        LOCALAPPDATA = (Join-Path $Scratch.UserHome 'AppData\Local')
        MULTICLI_HOME = $Scratch.Profiles
        MULTICLI_TOOLS_DIR = $Scratch.Tools
        MULTICLI_OVERRIDE_BINARY = $Scratch.Probe
    }
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

Describe 'shared Codex permissions on Windows' {
    It 'persists full access while preserving unrelated config' {
        $scratch = New-PermissionsScratch
        try {
            $codexHome = Join-Path $scratch.UserHome '.codex'
            New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
            @'
# keep this comment
model = "gpt-5"
sandbox_mode = "workspace-write"
approval_policy = "on-request"

[sandbox_workspace_write]
network_access = true

[features]
network_proxy = true
'@ | Set-Content -LiteralPath (Join-Path $codexHome 'config.toml') -Encoding UTF8

            $result = Invoke-PermissionsLauncher -Scratch $scratch -Arguments @('permissions', 'set', 'full-access')

            if ($result.ExitCode -ne 0) { Write-Host $result.Output }
            $result.ExitCode | Should Be 0
            $config = Get-Content -LiteralPath (Join-Path $codexHome 'config.toml') -Raw
            $config | Should Match '(?m)^default_permissions = ":danger-full-access"$'
            $config | Should Match '(?m)^approval_policy = "never"$'
            $config | Should Match '(?m)^# keep this comment$'
            $config | Should Match '(?m)^\[features\]$'
            $config | Should Not Match '(?m)^sandbox_mode\s*='
            $config | Should Not Match '(?m)^\[sandbox_workspace_write\]$'
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'shows the shared workspace preset without changing config' {
        $scratch = New-PermissionsScratch
        try {
            (Invoke-PermissionsLauncher -Scratch $scratch -Arguments @('permissions', 'set', 'workspace')).ExitCode | Should Be 0
            $configPath = Join-Path $scratch.UserHome '.codex\config.toml'
            $before = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash

            $result = Invoke-PermissionsLauncher -Scratch $scratch -Arguments @('permissions', 'show')

            $result.ExitCode | Should Be 0
            $result.Output | Should Match 'mode: workspace'
            $result.Output | Should Match 'approval: on-request'
            (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash | Should Be $before
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses duplicate top-level keys without changing config' {
        $scratch = New-PermissionsScratch
        try {
            $codexHome = Join-Path $scratch.UserHome '.codex'
            New-Item -ItemType Directory -Force -Path $codexHome | Out-Null
            $configPath = Join-Path $codexHome 'config.toml'
            @('approval_policy = "never"', 'approval_policy = "on-request"') | Set-Content -LiteralPath $configPath -Encoding UTF8
            $before = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash

            $result = Invoke-PermissionsLauncher -Scratch $scratch -Arguments @('permissions', 'set', 'workspace')

            $result.ExitCode | Should Not Be 0
            $result.Output | Should Match "duplicate top-level 'approval_policy'"
            (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash | Should Be $before
        } finally { Remove-Item -LiteralPath $scratch.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
