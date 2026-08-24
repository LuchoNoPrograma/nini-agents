Set-StrictMode -Version Latest

function Get-CodexPermissionValues {
    param([string]$Mode)
    switch ($Mode) {
        'read-only' { return [pscustomobject]@{ Profile = ':read-only'; Approval = 'on-request' } }
        'workspace' { return [pscustomobject]@{ Profile = ':workspace'; Approval = 'on-request' } }
        'full-access' { return [pscustomobject]@{ Profile = ':danger-full-access'; Approval = 'never' } }
        default { throw "Unknown permission preset '$Mode'. Use: read-only, workspace, or full-access" }
    }
}

function Get-CodexPermissionMode {
    param([string]$Profile)
    switch ($Profile) {
        ':read-only' { return 'read-only' }
        ':workspace' { return 'workspace' }
        ':danger-full-access' { return 'full-access' }
        '' { return 'unset' }
        default { return "custom ($Profile)" }
    }
}

function Get-CodexRootValues {
    param([string]$ConfigPath)
    $values = @{}
    $counts = @{}
    foreach ($key in @('default_permissions', 'approval_policy', 'sandbox_mode')) { $counts[$key] = 0 }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        return [pscustomobject]@{ Values = $values; Counts = $counts }
    }
    $inRoot = $true
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -match '^\s*\[') { $inRoot = $false }
        if (-not $inRoot) { continue }
        foreach ($key in @('default_permissions', 'approval_policy', 'sandbox_mode')) {
            $pattern = '^\s*{0}\s*=\s*"([^\"]*)"' -f [regex]::Escape($key)
            if ($line -match $pattern) {
                $counts[$key]++
                $values[$key] = $matches[1]
            }
        }
    }
    return [pscustomobject]@{ Values = $values; Counts = $counts }
}

function Get-NiniCodexPermissions {
    param([string]$ConfigPath)
    $parsed = Get-CodexRootValues -ConfigPath $ConfigPath
    $profile = if ($parsed.Values.ContainsKey('default_permissions')) { [string]$parsed.Values['default_permissions'] } else { '' }
    $approval = if ($parsed.Values.ContainsKey('approval_policy')) { [string]$parsed.Values['approval_policy'] } else { 'unset' }
    Write-Output 'Codex shared permissions'
    Write-Output "  mode: $(Get-CodexPermissionMode -Profile $profile)"
    Write-Output "  approval: $approval"
    Write-Output "  config: $ConfigPath"
    Write-Output '  scope: shared Codex profiles; new sessions'
    if ($parsed.Values.ContainsKey('sandbox_mode')) {
        Write-Output "  warning: legacy sandbox_mode=$($parsed.Values['sandbox_mode']) overrides permission profiles"
    }
}

function Get-RewrittenCodexConfig {
    param([string[]]$Lines, [string]$Profile, [string]$Approval)
    $result = New-Object 'System.Collections.Generic.List[string]'
    $inRoot = $true
    $skipLegacyTable = $false
    $profileWritten = $false
    $approvalWritten = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*\[') {
            if ($inRoot) {
                if (-not $profileWritten) { $result.Add("default_permissions = `"$Profile`""); $profileWritten = $true }
                if (-not $approvalWritten) { $result.Add("approval_policy = `"$Approval`""); $approvalWritten = $true }
                $inRoot = $false
            }
            if ($line -match '^\s*\[sandbox_workspace_write([.][^]]+)?\]\s*(#.*)?$') {
                $skipLegacyTable = $true
                continue
            }
            $skipLegacyTable = $false
        }
        if ($skipLegacyTable) { continue }
        if ($inRoot -and $line -match '^\s*default_permissions\s*=') {
            $result.Add("default_permissions = `"$Profile`"")
            $profileWritten = $true
            continue
        }
        if ($inRoot -and $line -match '^\s*approval_policy\s*=') {
            $result.Add("approval_policy = `"$Approval`"")
            $approvalWritten = $true
            continue
        }
        if ($inRoot -and $line -match '^\s*sandbox_mode\s*=') { continue }
        $result.Add($line)
    }
    if ($inRoot) {
        if (-not $profileWritten) { $result.Add("default_permissions = `"$Profile`"") }
        if (-not $approvalWritten) { $result.Add("approval_policy = `"$Approval`"") }
    }
    return $result.ToArray()
}

function Set-NiniCodexPermissions {
    param([string]$ConfigPath, [string]$Mode, [string]$CodexBinary)
    $values = Get-CodexPermissionValues -Mode $Mode
    $existingItem = Get-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
    if ($existingItem -and ($existingItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Refusing to update Codex permissions: config.toml is a link.'
    }
    if ($existingItem -and $existingItem.PSIsContainer) {
        throw 'Refusing to update Codex permissions: config.toml is not a regular file.'
    }
    $configDir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Force -Path $configDir | Out-Null }
    $parsed = Get-CodexRootValues -ConfigPath $ConfigPath
    foreach ($key in @('default_permissions', 'approval_policy', 'sandbox_mode')) {
        if ($parsed.Counts[$key] -gt 1) { throw "Refusing to update Codex permissions: duplicate top-level '$key' keys." }
    }
    $lines = if ($existingItem) { [IO.File]::ReadAllLines($ConfigPath) } else { @() }
    $rewritten = Get-RewrittenCodexConfig -Lines $lines -Profile $values.Profile -Approval $values.Approval
    $temporaryPath = Join-Path $configDir ('.config.toml.nini.' + [guid]::NewGuid().ToString('N'))
    $validationDir = Join-Path ([IO.Path]::GetTempPath()) ('nini-permissions-' + [guid]::NewGuid().ToString('N'))
    try {
        $utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($temporaryPath, (($rewritten -join "`r`n") + "`r`n"), $utf8)
        if ($existingItem) {
            try { Set-Acl -LiteralPath $temporaryPath -AclObject (Get-Acl -LiteralPath $ConfigPath) } catch { }
        }
        New-Item -ItemType Directory -Path $validationDir | Out-Null
        Copy-Item -LiteralPath $temporaryPath -Destination (Join-Path $validationDir 'config.toml')
        $previousCodexHome = $env:CODEX_HOME
        try {
            $env:CODEX_HOME = $validationDir
            & $CodexBinary --strict-config --version *> $null
            if ($LASTEXITCODE -ne 0) { throw 'Codex validation failed.' }
        } finally {
            $env:CODEX_HOME = $previousCodexHome
        }
        $currentItem = Get-Item -LiteralPath $ConfigPath -Force -ErrorAction SilentlyContinue
        if ($currentItem -and ($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Refusing to replace Codex permissions: config.toml became a link.'
        }
        if ($currentItem) { [IO.File]::Replace($temporaryPath, $ConfigPath, $null) }
        else { [IO.File]::Move($temporaryPath, $ConfigPath) }
    } catch {
        if ($_.Exception.Message -eq 'Codex validation failed.') {
            throw 'Codex rejected the staged permissions config; the existing config was not changed.'
        }
        throw
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $validationDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Output "Saved Codex permission preset '$Mode' for shared Codex profiles. New sessions will use it."
}

Export-ModuleMember -Function Get-NiniCodexPermissions, Set-NiniCodexPermissions
