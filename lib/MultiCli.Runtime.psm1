Set-StrictMode -Version Latest

# Schema-v2 accountOverlay runtime for multi-cli (Windows).
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

# Create the shared-root source for a declared path when missing: a file for
# declared file paths, a directory otherwise. Returns the source path.
function New-RuntimeStateSource {
    param($Adapter, [string]$SharedRoot, [string]$RelativePath)
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

# Build the overlay in a PID-unique staging dir (sweeping stale stagings from
# crashed runs) and swap it into place. Returns the runtime root. Throws on a
# hostile staging reparse point instead of removing it.
function New-RuntimeOverlay {
    param($Adapter, [string]$ProfileDir)
    $sharedRoot = Get-RuntimePlatformRoot -Adapter $Adapter
    New-Item -ItemType Directory -Force -Path $sharedRoot | Out-Null
    $runtimeRoot = Join-Path $ProfileDir '.runtime'
    $stagingRoot = "$runtimeRoot.staging.$PID"
    $normalState = Get-RuntimeProperty -Object $Adapter -Name 'normalState'
    $linkRoot = $stagingRoot
    $stateSubdir = Get-RuntimeProperty -Object $normalState -Name 'runtimeSubdir'
    if ($stateSubdir) { $linkRoot = Join-Path $stagingRoot ($stateSubdir -replace '/', '\') }
    # Sweep staging leftovers from other processes only; this process's own
    # staging root is inspected below so a hostile reparse point is refused
    # instead of silently removed.
    foreach ($stale in Get-ChildItem -LiteralPath $ProfileDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '.runtime.staging.*' -and $_.FullName -ne $stagingRoot }) {
        Remove-RuntimeOverlay -Adapter $Adapter -RuntimeRoot $stale.FullName
    }
    if (Test-Path -LiteralPath $stagingRoot) {
        $stagingItem = Get-Item -LiteralPath $stagingRoot -Force
        if ($stagingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to build overlay: '$stagingRoot' is a reparse point."
        }
        Remove-RuntimeOverlay -Adapter $Adapter -RuntimeRoot $stagingRoot
    }
    New-Item -ItemType Directory -Force -Path $linkRoot | Out-Null

    foreach ($relativePath in @($normalState.sharedPaths) + @($normalState.sessionPaths)) {
        if (-not $relativePath) { continue }
        $source = New-RuntimeStateSource -Adapter $Adapter -SharedRoot $sharedRoot -RelativePath $relativePath
        $destination = Join-Path $linkRoot ($relativePath -replace '/', '\')
        New-RuntimeLink -Source $source -Destination $destination -Label 'shared state'
    }

    $account = Get-RuntimeProperty -Object $Adapter -Name 'account'
    foreach ($relativePath in @($account.credentialFiles)) {
        if (-not $relativePath) { continue }
        $source = Join-Path (Join-Path $ProfileDir 'auth') ($relativePath -replace '/', '\')
        $sourceParent = Split-Path -Parent $source
        New-Item -ItemType Directory -Force -Path $sourceParent | Out-Null
        if (-not (Test-Path -LiteralPath $source)) { New-Item -ItemType File -Force -Path $source | Out-Null }
        $destination = Join-Path $linkRoot ($relativePath -replace '/', '\')
        New-RuntimeLink -Source $source -Destination $destination -Label 'profile credential'
    }

    $manifestLines = @($normalState.sharedPaths) + @($normalState.sessionPaths) + @($account.credentialFiles) | Where-Object { $_ } | ForEach-Object { if ($stateSubdir) { "$stateSubdir/$_" } else { $_ } }
    Set-Content -LiteralPath (Join-Path $stagingRoot '.runtime-manifest') -Value $manifestLines -Encoding ASCII

    Remove-RuntimeOverlay -Adapter $Adapter -RuntimeRoot $runtimeRoot
    Move-Item -LiteralPath $stagingRoot -Destination $runtimeRoot
    return $runtimeRoot
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
# osUserCredentialStore and inseparable refuse by design.
function Get-AccountOverlayLaunchPlan {
    param($Adapter, [string]$ProfileDir, [string]$Binary, [string[]]$BinaryArgs)
    switch ($Adapter.account.mechanism) {
        'fileOverlay' { }
        'processSecret' { }
        'osUserCredentialStore' { throw "Profile '$($Adapter.id)/$(Split-Path $ProfileDir -Leaf)' requires an owned OS-user credential context; this platform implementation is not enabled yet." }
        'inseparable' { throw "$($Adapter.account.reason) Use a legacy-isolated profile until the vendor exposes a safe account boundary." }
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
            throw "Profile '$($Adapter.id)/$(Split-Path $ProfileDir -Leaf)' has no stored credential. Run: multi-cli auth set $($Adapter.id)/$(Split-Path $ProfileDir -Leaf)"
        }
        $environment[$Adapter.account.secret.environmentVariable] = $secret
    }
    return [pscustomobject]@{
        Binary = $Binary
        Arguments = @($BinaryArgs)
        Environment = $environment
        ClearEnvironment = @($Adapter.isolation.clearEnv)
        Mode = $Adapter.isolation.mode
    }
}

Export-ModuleMember -Function Initialize-RuntimeProfile, Get-AccountOverlayLaunchPlan
