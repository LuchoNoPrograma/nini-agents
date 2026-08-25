Set-StrictMode -Version Latest

# Schema-v2 accountOverlay runtime for nini-agents (Windows).
# PowerShell mirror of lib/multicli-runtime.sh: declared credential files
# stay profile-local under <profile>\auth, declared shared/session state is
# junctioned/hardlinked from the adapter's native root, and the launch
# environment is expanded from adapter placeholders.
#
# Exported surface: Initialize-RuntimeProfile (profile creation) and
# Get-AccountOverlayLaunchPlan (launch planning). Everything else is
# module-internal; tests drive internals via Invoke-ModuleInternal.

function Get-RuntimeProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Assert-RuntimeRelativePath {
    param([string]$RelativePath, [string]$Label, [string]$AdapterId = 'unknown')
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { throw "Adapter '$AdapterId' has an empty $Label path." }
    $normalized = $RelativePath -replace '\\', '/'
    if ($normalized -match '^/' -or $normalized -match '^[a-zA-Z]:' -or $normalized -match ':' -or
        $normalized -eq '.' -or $normalized -eq '..' -or "/$normalized/" -match '/\.\./') {
        throw "Adapter '$AdapterId' has unsafe $Label path '$RelativePath'."
    }
}

# Absolute native shared-state root for Windows, tokens expanded.
function Get-RuntimePlatformRoot {
    param($Adapter)
    $normalState = Get-RuntimeProperty -Object $Adapter -Name 'normalState'
    $roots = Get-RuntimeProperty -Object $normalState -Name 'root'
    $root = Get-RuntimeProperty -Object $roots -Name 'windows'
    return [System.IO.Path]::GetFullPath((Resolve-PathToken $root))
}

# Write .profile.json atomically (temp + move) with a fresh profileId.
function Write-RuntimeProfileMetadata {
    param($Adapter, [string]$ProfileDir)
    $metadata = [ordered]@{
        schemaVersion = 2
        adapterId = $Adapter.id
        profileId = [guid]::NewGuid().ToString()
        mode = 'accountOverlay'
    }
    $temporaryPath = Join-Path $ProfileDir '.profile.json.tmp'
    $metadata | ConvertTo-Json | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination (Join-Path $ProfileDir '.profile.json') -Force
}

# Create the schema-v2 skeleton: empty profile-local placeholder files for
# every declared credential, plus fresh metadata. Existing content is kept.
function Initialize-RuntimeProfile {
    param($Adapter, [string]$ProfileDir)
    $authDir = Join-Path $ProfileDir 'auth'
    New-Item -ItemType Directory -Force -Path $authDir | Out-Null
    foreach ($relativePath in @($Adapter.account.credentialFiles)) {
        if (-not $relativePath) { continue }
        Assert-RuntimeRelativePath -RelativePath $relativePath -Label 'credential' -AdapterId $Adapter.id
        $credentialPath = Join-Path $authDir ($relativePath -replace '/', '\')
        $parent = Split-Path -Parent $credentialPath
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        if (-not (Test-Path -LiteralPath $credentialPath)) {
            New-Item -ItemType File -Force -Path $credentialPath | Out-Null
        }
    }
    Write-RuntimeProfileMetadata -Adapter $Adapter -ProfileDir $ProfileDir
}

# True when the adapter declares $RelativePath as a file (not a directory) in
# normalState.filePaths.
function Test-RuntimeFilePath {
    param($Adapter, [string]$RelativePath)
    $normalState = Get-RuntimeProperty -Object $Adapter -Name 'normalState'
    return @($normalState.filePaths) -contains $RelativePath
}

function Test-RuntimeDirectPath {
    param($Adapter, [string]$RelativePath)
    $normalState = Get-RuntimeProperty -Object $Adapter -Name 'normalState'
    return @(Get-RuntimeProperty -Object $normalState -Name 'directPaths') -contains $RelativePath
}

function Get-RuntimeSharedCredentialRoot {
    param($Adapter, [string]$ProfileDir)
    $sharedCredentialState = Get-RuntimeProperty -Object $Adapter -Name 'sharedCredentialState'
    $relativeRoot = Get-RuntimeProperty -Object $sharedCredentialState -Name 'root'
    if (-not $relativeRoot) { return $null }
    Assert-RuntimeRelativePath -RelativePath $relativeRoot -Label 'shared credential root' -AdapterId $Adapter.id
    $normalizedRoot = ($relativeRoot -replace '\\', '/').ToLowerInvariant()
    $expectedPrefix = ".shared/$(([string]$Adapter.id).ToLowerInvariant())/"
    if (-not $normalizedRoot.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) {
        throw "Adapter '$($Adapter.id)' shared credential root must stay below '.shared/$($Adapter.id)/'."
    }
    $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
    return [System.IO.Path]::GetFullPath((Join-Path $profileStore ($relativeRoot -replace '/', '\')))
}

# Create a directory tree below Base without traversing reparse points. The
# profile-store root itself may be redirected, but every adapter-owned
# component beneath it must be a real directory.
function New-RuntimeOwnedDirectory {
    param([string]$Base, [string]$RelativePath, [string]$Label)
    Assert-RuntimeRelativePath -RelativePath $RelativePath -Label $Label
    $current = $Base
    foreach ($component in @($RelativePath -split '[\\/]')) {
        if (-not $component -or $component -eq '.') { continue }
        $current = Join-Path $current $component
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing to initialize ${Label}: shared credential store component '$current' is a link."
            }
            if (-not $item.PSIsContainer) {
                throw "Refusing to initialize ${Label}: shared credential store component '$current' is not a directory."
            }
            continue
        }
        try {
            New-Item -ItemType Directory -Path $current -ErrorAction Stop | Out-Null
        } catch { }
        # Re-read even after a successful create so a concurrent reparse-point
        # substitution cannot be accepted through New-Item's result.
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if (-not $item -or -not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Cannot create shared credential store directory '$current'."
        }
    }
    return $current
}

function Get-RuntimeSharedCredentialMutexName {
    param([string]$SharedCredentialRoot)
    $bytes = [Text.Encoding]::UTF8.GetBytes([System.IO.Path]::GetFullPath($SharedCredentialRoot).ToLowerInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
    return "Local\MultiCliSharedCredential_$hash"
}

function New-RuntimeSharedCredentialSourcesLocked {
    param($Adapter, [string]$ProfileDir, [string]$SharedCredentialRoot)
    $sharedCredentialState = Get-RuntimeProperty -Object $Adapter -Name 'sharedCredentialState'
    $relativeRoot = Get-RuntimeProperty -Object $sharedCredentialState -Name 'root'
    $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
    New-RuntimeOwnedDirectory -Base $profileStore -RelativePath $relativeRoot -Label 'shared credential store' | Out-Null

    foreach ($entry in @(Get-RuntimeProperty -Object $sharedCredentialState -Name 'entries')) {
        $relativePath = [string](Get-RuntimeProperty -Object $entry -Name 'path')
        $kind = [string](Get-RuntimeProperty -Object $entry -Name 'kind')
        if (-not $relativePath) { continue }
        Assert-RuntimeRelativePath -RelativePath $relativePath -Label 'shared credential' -AdapterId $Adapter.id
        $source = Join-Path $SharedCredentialRoot ($relativePath -replace '/', '\')
        $relativeParent = Split-Path -Parent ($relativePath -replace '/', '\')
        if ($relativeParent) {
            New-RuntimeOwnedDirectory -Base $SharedCredentialRoot -RelativePath $relativeParent -Label 'shared credential entry' | Out-Null
        }
        switch ($kind) {
            'directory' {
                New-RuntimeOwnedDirectory -Base $SharedCredentialRoot -RelativePath $relativePath -Label 'shared credential entry' | Out-Null
            }
            'jsonObjectFile' {
                $item = Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
                if ($item) {
                    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.PSIsContainer) {
                        throw "Refusing to initialize shared credential file '$source': expected a regular non-link file."
                    }
                    continue
                }
                $stream = $null
                try {
                    $stream = [System.IO.File]::Open($source, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    $bytes = [Text.Encoding]::UTF8.GetBytes("{}`r`n")
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush($true)
                } catch {
                    throw "Cannot initialize shared credential file '$source': $($_.Exception.Message)"
                } finally {
                    if ($stream) { $stream.Dispose() }
                }
            }
            default { throw "Unsupported shared credential entry kind '$kind'." }
        }
    }
}

function New-RuntimeSharedCredentialSources {
    param($Adapter, [string]$ProfileDir, [string]$SharedCredentialRoot)
    $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
    New-RuntimeOwnedDirectory -Base $profileStore -RelativePath '.shared' -Label 'shared credential store' | Out-Null
    $mutex = New-Object Threading.Mutex($false, (Get-RuntimeSharedCredentialMutexName -SharedCredentialRoot $SharedCredentialRoot))
    $hasLock = $false
    try {
        try { $hasLock = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) }
        catch [Threading.AbandonedMutexException] { $hasLock = $true }
        if (-not $hasLock) { throw "Timed out waiting for shared credential initialization lock for '$SharedCredentialRoot'." }
        New-RuntimeSharedCredentialSourcesLocked -Adapter $Adapter -ProfileDir $ProfileDir -SharedCredentialRoot $SharedCredentialRoot
    } finally {
        if ($hasLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Create the shared-root source for a declared path when missing: a file for
# declared file paths, a directory otherwise. Returns the source path.
function New-RuntimeStateSource {
    param($Adapter, [string]$SharedRoot, [string]$RelativePath)
    Assert-RuntimeRelativePath -RelativePath $RelativePath -Label 'shared state' -AdapterId $Adapter.id
    $source = Join-Path $SharedRoot ($RelativePath -replace '/', '\')
    $parent = Split-Path -Parent $source
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (Test-Path -LiteralPath $source) { return $source }
    if (Test-RuntimeFilePath -Adapter $Adapter -RelativePath $RelativePath) {
        New-Item -ItemType File -Force -Path $source | Out-Null
    } else {
        New-Item -ItemType Directory -Force -Path $source | Out-Null
    }
    return $source
}

# Link one path into the overlay: junction for directories, hardlink for
# files. No copy fallback: a copied credential or state file would silently
# diverge from the shared root, so failure throws.
function New-RuntimeLink {
    param([string]$Source, [string]$Destination, [string]$Label)
    $parent = Split-Path -Parent $Destination
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $itemType = if (Test-Path -LiteralPath $Source -PathType Container) { 'Junction' } else { 'HardLink' }
    try {
        New-Item -ItemType $itemType -Path $Destination -Target $Source -ErrorAction Stop | Out-Null
    } catch {
        throw "Cannot link $Label '$Destination' to '$Source': $($_.Exception.Message)"
    }
}

function Remove-RuntimeOverlay {
    param($Adapter, [string]$RuntimeRoot)
    if (-not (Test-Path -LiteralPath $RuntimeRoot)) { return }
    # Remove every reparse point without traversing it, deepest first. A
    # recursive delete that crosses a junction would erase shared state.
    $reparsePoints = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((Get-Item -LiteralPath $RuntimeRoot))
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue) {
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                $reparsePoints.Add($item)
                continue
            }
            if ($item.PSIsContainer) { $stack.Push($item) }
        }
    }
    foreach ($reparsePoint in $reparsePoints) {
        # Directory::Delete removes the junction itself without touching the
        # target; Remove-Item -Recurse on PS 5.1 prompts/throws for non-empty
        # junction targets and can traverse reparse points.
        if ($reparsePoint.PSIsContainer) {
            [System.IO.Directory]::Delete($reparsePoint.FullName)
        } else {
            [System.IO.File]::Delete($reparsePoint.FullName)
        }
    }
    Remove-Item -LiteralPath $RuntimeRoot -Recurse -Force
}

function Get-RuntimeManifestLines {
    param($Adapter)
    $normalState = Get-RuntimeProperty -Object $Adapter -Name 'normalState'
    $account = Get-RuntimeProperty -Object $Adapter -Name 'account'
    $stateSubdir = Get-RuntimeProperty -Object $normalState -Name 'runtimeSubdir'
    if ($stateSubdir) { Assert-RuntimeRelativePath -RelativePath $stateSubdir -Label 'runtime subdirectory' -AdapterId $Adapter.id }
    $directPaths = @(Get-RuntimeProperty -Object $normalState -Name 'directPaths')
    $lines = @()
    foreach ($relativePath in @($normalState.sharedPaths) + @($normalState.sessionPaths)) {
        if (-not $relativePath) { continue }
        Assert-RuntimeRelativePath -RelativePath $relativePath -Label 'shared state' -AdapterId $Adapter.id
        if ($directPaths -contains $relativePath) { continue }
        $lines += $(if ($stateSubdir) { "$stateSubdir/$relativePath" } else { $relativePath })
    }
    foreach ($relativePath in @($account.credentialFiles)) {
        if (-not $relativePath) { continue }
        Assert-RuntimeRelativePath -RelativePath $relativePath -Label 'credential' -AdapterId $Adapter.id
        $lines += $(if ($stateSubdir) { "$stateSubdir/$relativePath" } else { $relativePath })
    }
    $sharedCredentialState = Get-RuntimeProperty -Object $Adapter -Name 'sharedCredentialState'
    foreach ($entry in @(Get-RuntimeProperty -Object $sharedCredentialState -Name 'entries')) {
        $relativePath = Get-RuntimeProperty -Object $entry -Name 'path'
        if (-not $relativePath) { continue }
        Assert-RuntimeRelativePath -RelativePath $relativePath -Label 'shared credential' -AdapterId $Adapter.id
        $lines += $(if ($stateSubdir) { "$stateSubdir/$relativePath" } else { $relativePath })
    }
    return @($lines)
}

function Test-RuntimePathTarget {
    param([string]$Path, [string]$ExpectedSource)
    if (-not (Test-Path -LiteralPath $Path) -or -not (Test-Path -LiteralPath $ExpectedSource)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    $linkType = Get-RuntimeProperty -Object $item -Name 'LinkType'
    if (-not $linkType) { return $false }
    $targets = @(Get-RuntimeProperty -Object $item -Name 'Target')
    $expected = [System.IO.Path]::GetFullPath($ExpectedSource).TrimEnd('\')
    foreach ($target in $targets) {
        if (-not $target) { continue }
        $candidate = [string]$target
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            $candidate = Join-Path (Split-Path -Parent $Path) $candidate
        }
        if ([System.IO.Path]::GetFullPath($candidate).TrimEnd('\') -eq $expected) { return $true }
    }
    return $false
}

function Test-RuntimeOverlayCurrent {
    param($Adapter, [string]$RuntimeRoot)
    $manifestPath = Join-Path $RuntimeRoot '.runtime-manifest'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }
    $expected = @(Get-RuntimeManifestLines -Adapter $Adapter)
    $actual = @(Get-Content -LiteralPath $manifestPath)
    if (($expected -join "`n") -ne ($actual -join "`n")) { return $false }
    $profileDir = Split-Path -Parent $RuntimeRoot
    $sharedRoot = Get-RuntimePlatformRoot -Adapter $Adapter
    $sharedCredentialRoot = Get-RuntimeSharedCredentialRoot -Adapter $Adapter -ProfileDir $profileDir
    $normalState = Get-RuntimeProperty -Object $Adapter -Name 'normalState'
    $account = Get-RuntimeProperty -Object $Adapter -Name 'account'
    $stateSubdir = Get-RuntimeProperty -Object $normalState -Name 'runtimeSubdir'
    foreach ($relativePath in $expected) {
        $runtimePath = Join-Path $RuntimeRoot ($relativePath -replace '/', '\')
        if (-not (Test-Path -LiteralPath $runtimePath)) { return $false }
        $declaredPath = $relativePath
        if ($stateSubdir) {
            $prefix = ($stateSubdir -replace '\\', '/').TrimEnd('/') + '/'
            if ($declaredPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $declaredPath = $declaredPath.Substring($prefix.Length)
            }
        }
        $sharedCredentialState = Get-RuntimeProperty -Object $Adapter -Name 'sharedCredentialState'
        $sharedCredentialPaths = @(Get-RuntimeProperty -Object $sharedCredentialState -Name 'entries') |
            ForEach-Object { Get-RuntimeProperty -Object $_ -Name 'path' }
        $expectedSource = if (@($account.credentialFiles) -contains $declaredPath) {
            Join-Path (Join-Path $profileDir 'auth') ($declaredPath -replace '/', '\')
        } elseif ($sharedCredentialRoot -and $sharedCredentialPaths -contains $declaredPath) {
            $source = Join-Path $sharedCredentialRoot ($declaredPath -replace '/', '\')
            $sourceItem = Get-Item -LiteralPath $source -Force -ErrorAction SilentlyContinue
            if ($sourceItem -and ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
            $source
        } else {
            Join-Path $sharedRoot ($declaredPath -replace '/', '\')
        }
        if (-not (Test-RuntimePathTarget -Path $runtimePath -ExpectedSource $expectedSource)) { return $false }
    }
    return $true
}

function Get-RuntimeMutexName {
    param([string]$ProfileDir)
    $bytes = [Text.Encoding]::UTF8.GetBytes([System.IO.Path]::GetFullPath($ProfileDir).ToLowerInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') } finally { $sha.Dispose() }
    return "Local\MultiCliRuntime_$hash"
}

# Serialize builds across processes. A current overlay is reused so launching a
# second process never removes the runtime tree from beneath the first.
function New-RuntimeOverlay {
    param($Adapter, [string]$ProfileDir)
    $runtimeRoot = Join-Path $ProfileDir '.runtime'
    $sharedCredentialRoot = Get-RuntimeSharedCredentialRoot -Adapter $Adapter -ProfileDir $ProfileDir
    if ($sharedCredentialRoot) {
        New-RuntimeSharedCredentialSources -Adapter $Adapter -ProfileDir $ProfileDir -SharedCredentialRoot $sharedCredentialRoot
    }
    if (Test-RuntimeOverlayCurrent -Adapter $Adapter -RuntimeRoot $runtimeRoot) { return $runtimeRoot }
    $mutex = New-Object Threading.Mutex($false, (Get-RuntimeMutexName -ProfileDir $ProfileDir))
    $hasLock = $false
    try {
        try { $hasLock = $mutex.WaitOne([TimeSpan]::FromSeconds(30)) }
        catch [Threading.AbandonedMutexException] { $hasLock = $true }
        if (-not $hasLock) { throw "Timed out waiting for the profile runtime lock. Close a stuck nini-agents launch and retry." }
        return New-RuntimeOverlayLocked -Adapter $Adapter -ProfileDir $ProfileDir
    } finally {
        if ($hasLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function New-RuntimeOverlayLocked {
    param($Adapter, [string]$ProfileDir)
    $runtimeRoot = Join-Path $ProfileDir '.runtime'
    $sharedCredentialRoot = Get-RuntimeSharedCredentialRoot -Adapter $Adapter -ProfileDir $ProfileDir
    if ($sharedCredentialRoot) {
        New-RuntimeSharedCredentialSources -Adapter $Adapter -ProfileDir $ProfileDir -SharedCredentialRoot $sharedCredentialRoot
    }
    if (Test-RuntimeOverlayCurrent -Adapter $Adapter -RuntimeRoot $runtimeRoot) { return $runtimeRoot }
    $sharedRoot = Get-RuntimePlatformRoot -Adapter $Adapter
    New-Item -ItemType Directory -Force -Path $sharedRoot | Out-Null
    $stagingRoot = "$runtimeRoot.staging.$PID"
    $normalState = Get-RuntimeProperty -Object $Adapter -Name 'normalState'
    $stateSubdir = Get-RuntimeProperty -Object $normalState -Name 'runtimeSubdir'
    if ($stateSubdir) { Assert-RuntimeRelativePath -RelativePath $stateSubdir -Label 'runtime subdirectory' -AdapterId $Adapter.id }
    $linkRoot = if ($stateSubdir) { Join-Path $stagingRoot ($stateSubdir -replace '/', '\') } else { $stagingRoot }
    foreach ($stale in Get-ChildItem -LiteralPath $ProfileDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.runtime.staging.*' -and $_.FullName -ne $stagingRoot }) {
        Remove-RuntimeOverlay -Adapter $Adapter -RuntimeRoot $stale.FullName
    }
    if (Test-Path -LiteralPath $stagingRoot) {
        $stagingItem = Get-Item -LiteralPath $stagingRoot -Force
        if ($stagingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing to build overlay: '$stagingRoot' is a reparse point." }
        Remove-RuntimeOverlay -Adapter $Adapter -RuntimeRoot $stagingRoot
    }
    New-Item -ItemType Directory -Force -Path $linkRoot | Out-Null
    Add-RuntimeStateLinks -Adapter $Adapter -ProfileDir $ProfileDir -SharedRoot $sharedRoot -LinkRoot $linkRoot
    if ($sharedCredentialRoot) {
        Add-RuntimeSharedCredentialLinks -Adapter $Adapter -SharedCredentialRoot $sharedCredentialRoot -LinkRoot $linkRoot
    }
    Set-Content -LiteralPath (Join-Path $stagingRoot '.runtime-manifest') -Value @(Get-RuntimeManifestLines -Adapter $Adapter) -Encoding ASCII
    Remove-RuntimeOverlay -Adapter $Adapter -RuntimeRoot $runtimeRoot
    Move-Item -LiteralPath $stagingRoot -Destination $runtimeRoot
    return $runtimeRoot
}

function Add-RuntimeStateLinks {
    param($Adapter, [string]$ProfileDir, [string]$SharedRoot, [string]$LinkRoot)
    $normalState = Get-RuntimeProperty -Object $Adapter -Name 'normalState'
    foreach ($relativePath in @($normalState.sharedPaths) + @($normalState.sessionPaths)) {
        if (-not $relativePath) { continue }
        Assert-RuntimeRelativePath -RelativePath $relativePath -Label 'shared state' -AdapterId $Adapter.id
        if (Test-RuntimeDirectPath -Adapter $Adapter -RelativePath $relativePath) { continue }
        $source = New-RuntimeStateSource -Adapter $Adapter -SharedRoot $SharedRoot -RelativePath $relativePath
        New-RuntimeLink -Source $source -Destination (Join-Path $LinkRoot ($relativePath -replace '/', '\')) -Label 'shared state'
    }
    $account = Get-RuntimeProperty -Object $Adapter -Name 'account'
    foreach ($relativePath in @($account.credentialFiles)) {
        if (-not $relativePath) { continue }
        Assert-RuntimeRelativePath -RelativePath $relativePath -Label 'credential' -AdapterId $Adapter.id
        $source = Join-Path (Join-Path $ProfileDir 'auth') ($relativePath -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $source) | Out-Null
        if (-not (Test-Path -LiteralPath $source)) { New-Item -ItemType File -Force -Path $source | Out-Null }
        New-RuntimeLink -Source $source -Destination (Join-Path $LinkRoot ($relativePath -replace '/', '\')) -Label 'profile credential'
    }
}

function Add-RuntimeSharedCredentialLinks {
    param($Adapter, [string]$SharedCredentialRoot, [string]$LinkRoot)
    $sharedCredentialState = Get-RuntimeProperty -Object $Adapter -Name 'sharedCredentialState'
    foreach ($entry in @(Get-RuntimeProperty -Object $sharedCredentialState -Name 'entries')) {
        $relativePath = [string](Get-RuntimeProperty -Object $entry -Name 'path')
        if (-not $relativePath) { continue }
        Assert-RuntimeRelativePath -RelativePath $relativePath -Label 'shared credential' -AdapterId $Adapter.id
        $source = Join-Path $SharedCredentialRoot ($relativePath -replace '/', '\')
        $destination = Join-Path $LinkRoot ($relativePath -replace '/', '\')
        New-RuntimeLink -Source $source -Destination $destination -Label 'shared credential state'
    }
}

# Expand the six adapter placeholders against the concrete launch-time paths.
function Expand-RuntimeValue {
    param(
        [string]$Value,
        [string]$ProfileDir,
        [string]$ProfileId,
        [string]$AuthDir,
        [string]$RuntimeRoot,
        [string]$SharedRoot
    )
    return $Value.Replace('{profileDir}', $ProfileDir).
        Replace('{profileId}', $ProfileId).
        Replace('{authDir}', $AuthDir).
        Replace('{runtimeRoot}', $RuntimeRoot).
        Replace('{sharedStateRoot}', $SharedRoot).
        Replace('{realHome}', $env:USERPROFILE)
}

# Credential Manager target for a process-secret profile:
# multi-cli/<adapterId>/<profileId>/<envVar>.
function Get-ProfileCredentialTarget {
    param($Adapter, $Metadata)
    $environmentVariable = $Adapter.account.secret.environmentVariable
    return "multi-cli/$($Adapter.id)/$($Metadata.profileId)/$environmentVariable"
}

# Plan one accountOverlay launch. fileOverlay builds the per-profile runtime
# view; processSecret reads the profile's secret from Credential Manager and
# injects it into the child environment only (fail-closed until auth set);
# osUserCredentialStore launches through the OS-user module (MultiCli.OsUser);
# inseparable refuses by design.
function Get-AccountOverlayLaunchPlan {
    param($Adapter, [string]$ProfileDir, [string]$Binary, [string[]]$BinaryArgs)
    switch ($Adapter.account.mechanism) {
        'fileOverlay' { }
        'processSecret' { }
        'osUserCredentialStore' { throw "Profile '$($Adapter.id)/$(Split-Path $ProfileDir -Leaf)' uses the OS-user runtime; it must launch through Invoke-OsUserLaunch, not a process launch plan." }
        'inseparable' { throw "$($Adapter.account.reason) Create this profile with --isolated to use a separate whole-root profile." }
        default { throw "Unsupported schema-v2 account mechanism '$($Adapter.account.mechanism)'." }
    }
    $metadata = Get-Content -LiteralPath (Join-Path $ProfileDir '.profile.json') -Raw | ConvertFrom-Json
    $sharedRoot = Get-RuntimePlatformRoot -Adapter $Adapter
    $runtimeRoot = if ($Adapter.account.mechanism -eq 'fileOverlay') {
        New-RuntimeOverlay -Adapter $Adapter -ProfileDir $ProfileDir
    } else {
        $sharedRoot
    }
    $authDir = Join-Path $ProfileDir 'auth'
    $environment = @{}
    foreach ($property in $Adapter.isolation.env.PSObject.Properties) {
        $environment[$property.Name] = Expand-RuntimeValue -Value $property.Value -ProfileDir $ProfileDir -ProfileId $metadata.profileId -AuthDir $authDir -RuntimeRoot $runtimeRoot -SharedRoot $sharedRoot
    }
    $environment['MULTICLI_PROFILE_ID'] = $metadata.profileId
    if ($Adapter.account.mechanism -eq 'processSecret') {
        $credentialModule = Join-Path $PSScriptRoot 'MultiCli.CredentialStore.psm1'
        Import-Module $credentialModule -Force
        $target = Get-ProfileCredentialTarget -Adapter $Adapter -Metadata $metadata
        $secret = Get-MultiCliCredential -Target $target
        if ([string]::IsNullOrEmpty($secret)) {
            throw "Profile '$($Adapter.id)/$(Split-Path $ProfileDir -Leaf)' has no stored credential. Run: nini-agents auth set $($Adapter.id)/$(Split-Path $ProfileDir -Leaf)"
        }
        $environment[$Adapter.account.secret.environmentVariable] = $secret
    }
    $adapterArgs = @()
    foreach ($argument in @(Get-RuntimeProperty -Object $Adapter.isolation -Name 'args')) {
        if ($null -eq $argument -or $argument -eq '') { continue }
        $adapterArgs += Expand-RuntimeValue -Value ([string]$argument) -ProfileDir $ProfileDir -ProfileId $metadata.profileId -AuthDir $authDir -RuntimeRoot $runtimeRoot -SharedRoot $sharedRoot
    }
    $launchArgs = @()
    $adapterArgsInserted = $false
    foreach ($argument in @($BinaryArgs)) {
        if (-not $adapterArgsInserted -and $argument -eq '--') {
            $launchArgs += @($adapterArgs)
            $adapterArgsInserted = $true
        }
        $launchArgs += $argument
    }
    if (-not $adapterArgsInserted) { $launchArgs += @($adapterArgs) }
    return [pscustomobject]@{
        Binary = $Binary
        Arguments = @($launchArgs)
        Environment = $environment
        ClearEnvironment = @($Adapter.isolation.clearEnv)
        Mode = $Adapter.isolation.mode
    }
}

Export-ModuleMember -Function Initialize-RuntimeProfile, Get-AccountOverlayLaunchPlan
