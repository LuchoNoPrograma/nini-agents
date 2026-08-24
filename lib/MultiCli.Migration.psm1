# Legacy -> schema-v2 migration engine for nini-agents (Windows).
#
# Imported by nini-agents.ps1, which resolves the adapter and profile directory
# and wires the `migrate` command to Invoke-MultiCliMigration. Mirrors
# lib/migration.sh: same classification rules, plan lines, journal shape, and
# refusal messages.
#
# A legacy profile (a profile directory without .profile.json) is migrated to
# the schema-v2 accountOverlay layout:
#   - declared credential files move into <profile>/auth/<rel>, subpaths kept;
#   - declared shared/session state merges into the adapter's native shared
#     root without overwriting differing content (skip + report, unless
#     -PreferProfile); credential targets are never overwritten;
#   - migrationPreservePaths retain legacy transactional/volatile normal state
#     inactive instead of merging it into an unrelated live state family;
#   - legacy --shared links are recognized and left in place;
#   - entries the adapter does not declare refuse the migration by default;
#     an explicit PreserveUnknown switch moves those objects into inactive
#     recovery without following or reading them. Overlaps and unsafe
#     declarations always refuse the migration;
#   - every filesystem operation is journaled; handled failures automatically
#     reverse completed moves, while an unprovable rollback preserves evidence
#     and blocks reuse. All credential moves are same-volume renames.

Set-StrictMode -Version Latest

$script:MigrationJournalName = '.migration-journal.json'
$script:MigrationLockName = '.migration.lock'
$script:MigrationRollbackName = '.migration-rollback'
$script:MigrationMetaEntries = @('.shared', '.cli', '.profile.json', '.runtime', '.isolated', 'auth', $script:MigrationLockName, $script:MigrationRollbackName)

function Get-MigrationProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# True when $ProfileDir is a profile directory without schema-v2 metadata.
function Test-MultiCliLegacyProfile {
    param([string]$ProfileDir)
    if (-not (Test-Path -LiteralPath $ProfileDir -PathType Container)) { return $false }
    return -not (Test-Path -LiteralPath (Join-Path $ProfileDir '.profile.json'))
}

# Expand the path tokens adapters use for per-OS roots: $HOME and %VARS%.
function Resolve-MigrationPathToken {
    param([string]$Path)
    if (-not $Path) { return $Path }
    $expanded = $Path -replace '\$HOME', $env:USERPROFILE.Replace('\', '\\')
    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($expanded))
}

# The adapter's native shared-state root for Windows, or throw.
function Get-MigrationSharedRoot {
    param($Adapter)
    $normalState = Get-MigrationProperty -Object $Adapter -Name 'normalState'
    $roots = Get-MigrationProperty -Object $normalState -Name 'root'
    $root = Get-MigrationProperty -Object $roots -Name 'windows'
    if (-not $root) { throw "Adapter '$($Adapter.id)' has no normal-state root for windows." }
    return Resolve-MigrationPathToken $root
}

# One declared path list with separators normalized to '/' and trailing '/'
# trimmed, so prefix comparisons see one canonical form.
function Get-MigrationPathList {
    param($Object, [string]$Name)
    $value = Get-MigrationProperty -Object $Object -Name $Name
    $list = @()
    foreach ($entry in @($value)) {
        if ($entry) { $list += (($entry -replace '\\', '/').TrimEnd('/')) }
    }
    return , $list
}

# The adapter's credential/shared/session declarations as normalized lists.
function Get-MigrationDeclarations {
    param($Adapter)
    $account = Get-MigrationProperty -Object $Adapter -Name 'account'
    $normalState = Get-MigrationProperty -Object $Adapter -Name 'normalState'
    return @{
        Credentials = Get-MigrationPathList -Object $account -Name 'credentialFiles'
        Shared      = Get-MigrationPathList -Object $normalState -Name 'sharedPaths'
        Session     = Get-MigrationPathList -Object $normalState -Name 'sessionPaths'
        Runtime     = Get-MigrationPathList -Object $normalState -Name 'runtimePaths'
        Preserve    = Get-MigrationPathList -Object $normalState -Name 'migrationPreservePaths'
        SharedCredentials = @(
            @(Get-MigrationProperty -Object (Get-MigrationProperty -Object $Adapter -Name 'sharedCredentialState') -Name 'entries') |
                ForEach-Object { Get-MigrationProperty -Object $_ -Name 'path' } |
                Where-Object { $_ } |
                ForEach-Object { (($_ -replace '\\', '/').TrimEnd('/')) }
        )
        SharedCredentialBackupPattern = Get-MigrationProperty -Object (Get-MigrationProperty -Object $Adapter -Name 'sharedCredentialState') -Name 'legacyBackupPattern'
        Unsafe      = Get-MigrationPathList -Object $normalState -Name 'unsafePaths'
    }
}

# =============================================================================
# Classification
# =============================================================================

# The first declared path related to $Rel: equal to it, an ancestor directory
# of it, or sitting underneath it.
function Find-MigrationDeclaredPath {
    param([string]$Rel, [string[]]$Declared)
    foreach ($path in $Declared) {
        if ($Rel -eq $path -or $path.StartsWith("$Rel/") -or $Rel.StartsWith("$path/")) { return $path }
    }
    return $null
}

function Find-MigrationSharedCredentialPath {
    param([string]$Rel, $Declarations)
    $match = Find-MigrationDeclaredPath -Rel $Rel -Declared $Declarations.SharedCredentials
    if ($match) { return $match }
    if ($Declarations.SharedCredentialBackupPattern -ne 'dotSuffix') { return $null }
    foreach ($path in $Declarations.SharedCredentials) {
        if ($Rel.StartsWith("$path.", [StringComparison]::OrdinalIgnoreCase) -and $Rel.Length -gt ($path.Length + 1)) {
            return $Rel
        }
    }
    return $null
}

# Launcher/migration-owned entries that are never tool state. 'auth' and
# '.runtime' predate this migration only in partial/failed runs; a legacy
# profile cannot meaningfully own them.
function Test-MigrationMetaEntry {
    param([string]$Rel)
    if ($script:MigrationMetaEntries -contains $Rel) { return $true }
    if ($Rel -like "$($script:MigrationJournalName)*") { return $true }
    return $false
}

# Return idle/busy/unknown. Tests may inject a scriptblock; production checks
# every adapter-declared Windows binary name and conservatively blocks when
# any matching process is running.
function Get-MigrationProcessState {
    param($Adapter, [string]$ProfileDir, [scriptblock]$ProcessProbe)
    if ($ProcessProbe) {
        try { $state = [string](& $ProcessProbe $ProfileDir | Select-Object -Last 1) }
        catch { return 'unknown' }
        $state = $state.ToLowerInvariant()
        if ($state -in @('idle', 'busy', 'unknown')) { return $state }
        return 'unknown'
    }

    try { $processes = @(Get-Process -ErrorAction Stop) }
    catch { return 'unknown' }
    $binary = Get-MigrationProperty -Object $Adapter -Name 'binary'
    foreach ($candidate in @((Get-MigrationProperty -Object $binary -Name 'windows'))) {
        if (-not $candidate -or $candidate -like 'appx:*' -or $candidate -match '^https?://') { continue }
        $normalized = ([string]$candidate).Replace('/', '\')
        $processName = [System.IO.Path]::GetFileName($normalized) -replace '(?i)\.(cmd|exe)$', ''
        if (-not $processName) { continue }
        foreach ($process in $processes) {
            if ($process.ProcessName.Equals($processName, [StringComparison]::OrdinalIgnoreCase)) { return 'busy' }
        }
    }
    return 'idle'
}

function Assert-MigrationProcessIdle {
    param($Adapter, [string]$ProfileDir, [string]$Spec, [scriptblock]$ProcessProbe, [switch]$AfterLock)
    $state = Get-MigrationProcessState -Adapter $Adapter -ProfileDir $ProfileDir -ProcessProbe $ProcessProbe
    if ($state -eq 'busy') {
        if ($AfterLock) {
            throw "Cannot migrate ${Spec}: a tool process appeared while acquiring the migration lock. The lock was released and no profile data was changed."
        }
        throw "Cannot migrate ${Spec}: an active process is using this profile. Close it and retry. No changes were made."
    }
    if ($state -ne 'idle') {
        throw "Cannot migrate ${Spec}: could not prove that tool processes are stopped. No changes were made."
    }
}

function Enter-MigrationLock {
    param([string]$ProfileDir, [string]$Spec)
    $lock = Join-Path $ProfileDir $script:MigrationLockName
    $entry = Get-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    if ($entry) {
        if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Cannot migrate ${Spec}: migration lock is an unsafe link. No changes were made."
        }
        throw "Cannot migrate ${Spec}: migration is already locked. Close the other migration or recover the stale lock before retrying. No changes were made."
    }
    try {
        New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
        Set-Content -LiteralPath (Join-Path $lock 'pid') -Value $PID -Encoding ASCII -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath (Join-Path $lock 'pid') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
        throw "Cannot migrate ${Spec}: could not acquire and record the migration lock. No changes were made."
    }
    return $lock
}

function Exit-MigrationLock {
    param([string]$LockPath)
    if (-not $LockPath) { return $true }
    Remove-Item -LiteralPath (Join-Path $LockPath 'pid') -Force -ErrorAction SilentlyContinue
    try {
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# Refuse stale or linked control paths before planning, including dry-run.
function Assert-MigrationControlPathsSafe {
    param([string]$ProfileDir, [string]$Spec)
    $profileItem = Get-Item -LiteralPath $ProfileDir -Force -ErrorAction Stop
    if (($profileItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Cannot migrate ${Spec}: the profile directory is a link. No changes were made."
    }

    $lock = Join-Path $ProfileDir $script:MigrationLockName
    $lockItem = Get-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    if ($lockItem) {
        if (($lockItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Cannot migrate ${Spec}: migration lock is an unsafe link. No changes were made."
        }
        throw "Cannot migrate ${Spec}: migration is already locked. Close the other migration or recover the stale lock before retrying. No changes were made."
    }

    $rollback = Join-Path $ProfileDir $script:MigrationRollbackName
    if (Get-Item -LiteralPath $rollback -Force -ErrorAction SilentlyContinue) {
        throw "Cannot migrate ${Spec}: recovery artifacts already exist. Do not launch the profile; inspect the previous journal before retrying. No changes were made."
    }

    foreach ($rel in @("$($script:MigrationJournalName).tmp", '.profile.json.tmp')) {
        if (Get-Item -LiteralPath (Join-Path $ProfileDir $rel) -Force -ErrorAction SilentlyContinue) {
            throw "Cannot migrate ${Spec}: unfinished migration control artifact '$rel' exists. Inspect it before retrying. No changes were made."
        }
    }
    foreach ($rel in @($script:MigrationJournalName, '.profile.json')) {
        $item = Get-Item -LiteralPath (Join-Path $ProfileDir $rel) -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Cannot migrate ${Spec}: migration control path '$rel' is an unsafe link. No changes were made."
        }
    }
}

# Verify that an adapter-declared destination remains below its lexical root
# and crosses no symlink, junction, or non-directory ancestor.
function Assert-MigrationDestinationPathSafe {
    param([string]$Root, [string]$Target, [string]$Spec, [string]$Label)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $targetFull = [System.IO.Path]::GetFullPath($Target).TrimEnd('\', '/')
    $prefix = "$rootFull\"
    if (-not $targetFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $targetFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Cannot migrate ${Spec}: $Label escapes its declared root. No changes were made."
    }

    $relative = $targetFull.Substring($rootFull.Length).TrimStart('\')
    $parts = @()
    if ($relative) { $parts = @($relative -split '\\') }
    $current = $rootFull
    for ($index = 0; $index -le $parts.Count; $index++) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Cannot migrate ${Spec}: $Label crosses a link at '$current'. No changes were made."
            }
            if (-not $current.Equals($targetFull, [StringComparison]::OrdinalIgnoreCase) -and -not $item.PSIsContainer) {
                throw "Cannot migrate ${Spec}: $Label crosses a non-directory path at '$current'. No changes were made."
            }
        }
        if ($index -lt $parts.Count) { $current = Join-Path $current $parts[$index] }
    }
}

function Get-MigrationVolumeRoot {
    param([string]$Path)
    return [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
}

function Assert-MigrationCredentialSameVolume {
    param([string]$From, [string]$To, [string]$Spec, [string]$Rel)
    $sourceVolume = Get-MigrationVolumeRoot -Path $From
    $destinationVolume = Get-MigrationVolumeRoot -Path $To
    if (-not $sourceVolume -or -not $destinationVolume) {
        throw "Cannot migrate ${Spec}: could not prove the volume for credential '$Rel'. No changes were made."
    }
    if (-not $sourceVolume.Equals($destinationVolume, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Cannot migrate ${Spec}: credential '$Rel' and its destination are on different volumes; refusing a copy-based move. No changes were made."
    }
}

# Classify every entry of the profile tree: credential, shared, session,
# metadata, unknown, or overlapping. Unknown/overlap refuse the migration.
function Get-MigrationClassification {
    param([string]$ProfileDir, $Declarations)
    $result = @{ Entries = @(); Unknown = @(); Overlap = @(); Unsafe = @() }
    Add-MigrationClassification -Dir $ProfileDir -Prefix '' -Declarations $Declarations -Result $result
    return $result
}

# Walk one level of the profile tree, classifying each entry against the
# adapter declarations. Directories that are strict ancestors of a declared
# path are descended into so undeclared siblings are caught; directories that
# are themselves declared are adopted whole.
function Add-MigrationClassification {
    param([string]$Dir, [string]$Prefix, $Declarations, $Result)
    foreach ($item in (Get-ChildItem -LiteralPath $Dir -Force | Sort-Object Name)) {
        $rel = $item.Name
        if ($Prefix) { $rel = "$Prefix/$($item.Name)" }
        if (Test-MigrationMetaEntry -Rel $rel) {
            $Result.Entries += [pscustomobject]@{ Class = 'metadata'; Rel = $rel }
            continue
        }
        $credMatch = Find-MigrationDeclaredPath -Rel $rel -Declared $Declarations.Credentials
        $sharedMatch = Find-MigrationDeclaredPath -Rel $rel -Declared $Declarations.Shared
        $sessionMatch = Find-MigrationDeclaredPath -Rel $rel -Declared $Declarations.Session
        $runtimeMatch = Find-MigrationDeclaredPath -Rel $rel -Declared $Declarations.Runtime
        $preserveMatch = Find-MigrationDeclaredPath -Rel $rel -Declared $Declarations.Preserve
        $sharedCredentialMatch = Find-MigrationSharedCredentialPath -Rel $rel -Declarations $Declarations
        $unsafeMatch = Find-MigrationDeclaredPath -Rel $rel -Declared $Declarations.Unsafe
        $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        if ($unsafeMatch) {
            if ($item.PSIsContainer -and -not $isReparse -and $rel -ne $unsafeMatch -and $unsafeMatch.StartsWith("$rel/")) {
                Add-MigrationClassification -Dir $item.FullName -Prefix $rel -Declarations $Declarations -Result $Result
            } else {
                $Result.Unsafe += $rel
            }
            continue
        }
        $stateMatch = $sharedMatch
        if (-not $stateMatch) { $stateMatch = $sessionMatch }
        if (-not $stateMatch) { $stateMatch = $runtimeMatch }
        if (($credMatch -and $stateMatch) -or ($sharedCredentialMatch -and ($credMatch -or $stateMatch))) {
            $Result.Overlap += $rel
            continue
        }
        if ($sharedCredentialMatch) {
            if ($item.PSIsContainer -and -not $isReparse -and $rel -ne $sharedCredentialMatch -and $sharedCredentialMatch.StartsWith("$rel/")) {
                Add-MigrationClassification -Dir $item.FullName -Prefix $rel -Declarations $Declarations -Result $Result
            } else {
                $Result.Entries += [pscustomobject]@{ Class = 'shared-credential'; Rel = $rel }
            }
            continue
        }
        if ($credMatch) {
            if ($item.PSIsContainer -and -not $isReparse -and $rel -ne $credMatch -and $credMatch.StartsWith("$rel/")) {
                Add-MigrationClassification -Dir $item.FullName -Prefix $rel -Declarations $Declarations -Result $Result
            } else {
                $Result.Entries += [pscustomobject]@{ Class = 'credential'; Rel = $rel }
            }
            continue
        }
        if ($preserveMatch) {
            if ($item.PSIsContainer -and -not $isReparse -and $rel -ne $preserveMatch -and $preserveMatch.StartsWith("$rel/")) {
                Add-MigrationClassification -Dir $item.FullName -Prefix $rel -Declarations $Declarations -Result $Result
            } else {
                $Result.Entries += [pscustomobject]@{ Class = 'preserve-profile-state'; Rel = $rel }
            }
            continue
        }
        if ($stateMatch) {
            $class = 'shared'
            if ($sessionMatch -and -not $sharedMatch) { $class = 'session' }
            if ($runtimeMatch -and -not $sharedMatch -and -not $sessionMatch) { $class = 'runtime' }
            if ($item.PSIsContainer -and -not $isReparse -and $rel -ne $stateMatch -and $stateMatch.StartsWith("$rel/")) {
                Add-MigrationClassification -Dir $item.FullName -Prefix $rel -Declarations $Declarations -Result $Result
            } else {
                $Result.Entries += [pscustomobject]@{ Class = $class; Rel = $rel }
            }
            continue
        }
        $Result.Unknown += $rel
    }
}

# The refusal message listing every unknown/overlapping entry. Used before
# any write, so "No changes were made" is true by construction.
function Get-MigrationRefusalMessage {
    param([string]$Spec, $Classification)
    $message = "Cannot migrate ${Spec}: legacy profile contains entries the adapter does not declare:"
    foreach ($entry in $Classification.Unknown) {
        $message += "`n  unknown: $entry"
    }
    foreach ($entry in $Classification.Overlap) {
        $message += "`n  overlap: $entry (matches both credential and shared-state declarations)"
    }
    foreach ($entry in $Classification.Unsafe) {
        $message += "`n  unsafe: $entry"
    }
    $message += "`nDeclare safe paths in the adapter or remove unsafe/unknown entries from the profile. No changes were made."
    return $message
}

# =============================================================================
# Planning
# =============================================================================

# One pending migration operation (Op/Rel/From/To/Status/Note).
function New-MigrationOp {
    param([string]$Op, [string]$Rel, [string]$From, [string]$To, [string]$Note)
    return [ordered]@{ Op = $Op; Rel = $Rel; From = $From; To = $To; Status = 'pending'; Note = $Note }
}

# True when two files are byte-identical (SHA-256).
function Test-MigrationContentEqual {
    param([string]$First, [string]$Second)
    $firstHash = (Get-FileHash -LiteralPath $First -Algorithm SHA256).Hash
    $secondHash = (Get-FileHash -LiteralPath $Second -Algorithm SHA256).Hash
    return $firstHash -eq $secondHash
}

# True when a file leaf name collides with a declared credential leaf, so a
# lookalike hiding inside a shared directory is never merged into the root.
function Test-MigrationCredentialLeaf {
    param([string]$Leaf, [string[]]$Credentials)
    foreach ($cred in $Credentials) {
        $credLeaf = ($cred -split '/')[-1]
        if ($Leaf -eq $credLeaf) { return $true }
    }
    return $false
}

# True when a filesystem item is a symlink/junction/reparse point; missing
# paths are not links.
function Test-MigrationReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $false }
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

# Plan one file against its shared-root target: move when absent, dedupe when
# identical, replace only with -PreferProfile, otherwise skip the conflict.
function Add-MigrationFileMergePlan {
    param([string]$From, [string]$To, [string]$Rel, [string]$Kind, [bool]$PreferProfile, [string]$SharedRoot, [string]$Spec, $Ops)
    Assert-MigrationDestinationPathSafe -Root $SharedRoot -Target $To -Spec $Spec -Label "shared-state destination '$Rel'"
    if (-not (Test-Path -LiteralPath $To)) {
        [void]$Ops.Add((New-MigrationOp -Op 'merge-move' -Rel $Rel -From $From -To $To -Note $Kind))
        return
    }
    if (Test-Path -LiteralPath $To -PathType Container) {
        Add-MigrationTypeConflictPlan -From $From -To $To -Rel $Rel -PreferProfile $PreferProfile `
            -Reason 'shared root has a directory where the profile has a file' -Ops $Ops
        return
    }
    if (Test-MigrationContentEqual -First $From -Second $To) {
        [void]$Ops.Add((New-MigrationOp -Op 'remove-duplicate' -Rel $Rel -From $From -To $To -Note ''))
        return
    }
    if ($PreferProfile) {
        [void]$Ops.Add((New-MigrationOp -Op 'replace-shared' -Rel $Rel -From $From -To $To -Note 'content differs'))
    } else {
        [void]$Ops.Add((New-MigrationOp -Op 'skip-conflict' -Rel $Rel -From $From -To $To -Note 'content differs'))
    }
}

# Plan a file-vs-directory type conflict: replace with -PreferProfile,
# skip otherwise.
function Add-MigrationTypeConflictPlan {
    param([string]$From, [string]$To, [string]$Rel, [bool]$PreferProfile, [string]$Reason, $Ops)
    if ($PreferProfile) {
        [void]$Ops.Add((New-MigrationOp -Op 'replace-shared' -Rel $Rel -From $From -To $To -Note $Reason))
    } else {
        [void]$Ops.Add((New-MigrationOp -Op 'skip-conflict' -Rel $Rel -From $From -To $To -Note $Reason))
    }
}

# Plan one shared/session entry: whole links are kept, files merge per the
# conflict policy, clean new directories move whole, and everything else
# falls back to per-file merging.
function Add-MigrationSharedPlan {
    param([string]$ProfileDir, [string]$SharedRoot, [string]$Rel, [string]$Kind, [bool]$PreferProfile, [string]$Spec, $Declarations, $Ops)
    $from = Join-Path $ProfileDir ($Rel -replace '/', '\')
    $to = Join-Path $SharedRoot ($Rel -replace '/', '\')
    Assert-MigrationDestinationPathSafe -Root $SharedRoot -Target $to -Spec $Spec -Label "shared-state destination '$Rel'"
    if (Test-MigrationReparsePoint -Path $from) {
        [void]$Ops.Add((New-MigrationOp -Op 'keep-link' -Rel $Rel -From $from -To $to -Note 'existing link retained'))
        return
    }
    if (Test-Path -LiteralPath $from -PathType Leaf) {
        Add-MigrationFileMergePlan -From $from -To $to -Rel $Rel -Kind $Kind -PreferProfile $PreferProfile -SharedRoot $SharedRoot -Spec $Spec -Ops $Ops
        return
    }
    if ((Test-Path -LiteralPath $to) -and -not (Test-Path -LiteralPath $to -PathType Container)) {
        Add-MigrationTypeConflictPlan -From $from -To $to -Rel $Rel -PreferProfile $PreferProfile `
            -Reason 'shared root has a file where the profile has a directory' -Ops $Ops
        return
    }
    if (-not (Test-Path -LiteralPath $to -PathType Container)) {
        $treeItems = @(Get-MigrationTreeItems -Root $from)
        $blocked = @($treeItems | Where-Object { $_.IsLink -or (Test-MigrationCredentialLeaf -Leaf $_.Name -Credentials $Declarations.Credentials) })
        if ($blocked.Count -eq 0) {
            [void]$Ops.Add((New-MigrationOp -Op 'merge-move' -Rel $Rel -From $from -To $to -Note $Kind))
            return
        }
        # The target does not exist yet but the tree holds links or credential
        # lookalikes; fall through to per-file merging so nothing unsafe rides
        # along into the shared root.
    } else {
        # Both directories: merge per file so existing shared content is preserved.
        $treeItems = @(Get-MigrationTreeItems -Root $from)
    }
    # Merge per file: either both sides are directories (existing shared content
    # is preserved), or the tree contains blocked entries handled individually.
    foreach ($item in $treeItems) {
        $sub = $item.FullName.Substring($from.Length).TrimStart('\') -replace '\\', '/'
        $childRel = "$Rel/$sub"
        if ($item.IsLink) {
            [void]$Ops.Add((New-MigrationOp -Op 'skip-link' -Rel $childRel -From $item.FullName -To '' -Note 'left in profile'))
            continue
        }
        if (Test-MigrationCredentialLeaf -Leaf $item.Name -Credentials $Declarations.Credentials) {
            [void]$Ops.Add((New-MigrationOp -Op 'skip-credential-lookalike' -Rel $childRel -From $item.FullName -To '' -Note 'name matches a declared credential; left in profile'))
            continue
        }
        Add-MigrationFileMergePlan -From $item.FullName -To (Join-Path $to ($sub -replace '/', '\')) -Rel $childRel -Kind $Kind -PreferProfile $PreferProfile -SharedRoot $SharedRoot -Spec $Spec -Ops $Ops
    }
}

# All regular files and links under a root, never descending into reparse
# points. Each item: FullName, Name, IsLink.
function Get-MigrationTreeItems {
    param([string]$Root)
    $items = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue('')
    while ($queue.Count -gt 0) {
        $rel = $queue.Dequeue()
        $dir = $Root
        if ($rel) { $dir = Join-Path $Root $rel }
        foreach ($item in (Get-ChildItem -LiteralPath $dir -Force | Sort-Object Name)) {
            $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            if ($isReparse) {
                $items += [pscustomobject]@{ FullName = $item.FullName; Name = $item.Name; IsLink = $true }
                continue
            }
            if ($item.PSIsContainer) {
                $childRel = $item.Name
                if ($rel) { $childRel = "$rel\$($item.Name)" }
                $queue.Enqueue($childRel)
                continue
            }
            $items += [pscustomobject]@{ FullName = $item.FullName; Name = $item.Name; IsLink = $false }
        }
    }
    return $items
}

# Build the full op list from the classification: credentials first
# (profile-local moves), then state merges, then metadata, then the closing
# .profile.json write.
function New-MigrationPlan {
    param([string]$ProfileDir, [string]$SharedRoot, [bool]$PreferProfile, [string]$Spec, $Classification, $Declarations)
    $ops = New-Object System.Collections.ArrayList
    # Credentials first (profile-local moves), then state merges, then metadata.
    foreach ($entry in @($Classification.Entries | Where-Object { $_.Class -eq 'credential' })) {
        $from = Join-Path $ProfileDir ($entry.Rel -replace '/', '\')
        $authRoot = Join-Path $ProfileDir 'auth'
        $to = Join-Path $authRoot ($entry.Rel -replace '/', '\')
        if (Test-MigrationReparsePoint -Path $from) {
            throw "Cannot migrate ${Spec}: credential '$($entry.Rel)' is a link. Replace it with the real credential file before migrating. No changes were made."
        }
        if (-not (Test-Path -LiteralPath $from -PathType Leaf)) {
            throw "Cannot migrate ${Spec}: credential '$($entry.Rel)' is not a regular file. No changes were made."
        }
        $credentialItem = Get-Item -LiteralPath $from -Force
        if ((Get-MigrationProperty -Object $credentialItem -Name 'LinkType') -eq 'HardLink') {
            throw "Cannot migrate ${Spec}: credential '$($entry.Rel)' is a hardlink. Detach it before migrating. No changes were made."
        }
        Assert-MigrationDestinationPathSafe -Root $authRoot -Target $to -Spec $Spec -Label "credential destination 'auth/$($entry.Rel)'"
        $targetItem = Get-Item -LiteralPath $to -Force -ErrorAction SilentlyContinue
        if ($targetItem) {
            $targetLinkType = Get-MigrationProperty -Object $targetItem -Name 'LinkType'
            if ($targetItem.PSIsContainer -or
                ($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $targetLinkType -eq 'HardLink') {
                throw "Cannot migrate ${Spec}: credential target 'auth/$($entry.Rel)' is not one regular unlinked file. Resolve the conflict manually. No changes were made."
            }
            if (Test-MigrationContentEqual -First $from -Second $to) {
                [void]$ops.Add((New-MigrationOp -Op 'remove-duplicate-credential' -Rel $entry.Rel -From $from -To $to -Note ''))
            } else {
                throw "Cannot migrate ${Spec}: credential target 'auth/$($entry.Rel)' already exists with different content; refusing to overwrite credentials. Resolve the conflict manually. No changes were made."
            }
        } else {
            Assert-MigrationCredentialSameVolume -From $from -To $to -Spec $Spec -Rel $entry.Rel
            [void]$ops.Add((New-MigrationOp -Op 'move-credential' -Rel $entry.Rel -From $from -To $to -Note ''))
        }
    }
    $sharedCredentialEntries = @($Classification.Entries | Where-Object { $_.Class -eq 'shared-credential' })
    if ($sharedCredentialEntries.Count -gt 0) {
        $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
        $inactiveBase = Join-Path $profileStore '.inactive'
        $inactiveRoot = Get-MigrationInactiveSharedCredentialRoot -ProfileDir $ProfileDir
        Assert-MigrationDestinationPathSafe -Root $inactiveBase -Target $inactiveRoot -Spec $Spec -Label 'inactive shared-credential recovery root'
        if (Get-Item -LiteralPath $inactiveRoot -Force -ErrorAction SilentlyContinue) {
            throw "Cannot migrate ${Spec}: inactive shared-credential recovery already exists. Inspect it before retrying. No changes were made."
        }
        foreach ($entry in $sharedCredentialEntries) {
            $from = Join-Path $ProfileDir ($entry.Rel -replace '/', '\')
            $to = Join-Path $inactiveRoot ($entry.Rel -replace '/', '\')
            Assert-MigrationDestinationPathSafe -Root $inactiveBase -Target $to -Spec $Spec -Label "inactive shared-credential destination '$($entry.Rel)'"
            if (-not (Get-Item -LiteralPath $from -Force -ErrorAction SilentlyContinue)) {
                throw "Cannot migrate ${Spec}: shared credential '$($entry.Rel)' disappeared during planning. No changes were made."
            }
            if (Get-Item -LiteralPath $to -Force -ErrorAction SilentlyContinue) {
                throw "Cannot migrate ${Spec}: inactive shared-credential destination '$($entry.Rel)' already exists. No changes were made."
            }
            $sourceVolume = Get-MigrationVolumeRoot -Path $from
            $destinationVolume = Get-MigrationVolumeRoot -Path $to
            if (-not $sourceVolume -or -not $destinationVolume -or
                -not $sourceVolume.Equals($destinationVolume, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Cannot migrate ${Spec}: shared credential '$($entry.Rel)' cannot be preserved by same-volume rename. No changes were made."
            }
            [void]$ops.Add((New-MigrationOp -Op 'preserve-shared-credential' -Rel $entry.Rel -From $from -To $to -Note 'inactive recovery'))
        }
    }
    $runtimeEntries = @($Classification.Entries | Where-Object { $_.Class -eq 'runtime' })
    if ($runtimeEntries.Count -gt 0) {
        $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
        $inactiveBase = Join-Path $profileStore '.inactive'
        $inactiveRoot = Get-MigrationInactiveRuntimeRoot -ProfileDir $ProfileDir
        Assert-MigrationDestinationPathSafe -Root $inactiveBase -Target $inactiveRoot -Spec $Spec -Label 'inactive runtime-state recovery root'
        if (Get-Item -LiteralPath $inactiveRoot -Force -ErrorAction SilentlyContinue) {
            throw "Cannot migrate ${Spec}: inactive runtime-state recovery already exists. Inspect it before retrying. No changes were made."
        }
        foreach ($entry in $runtimeEntries) {
            $from = Join-Path $ProfileDir ($entry.Rel -replace '/', '\')
            $to = Join-Path $inactiveRoot ($entry.Rel -replace '/', '\')
            Assert-MigrationDestinationPathSafe -Root $inactiveBase -Target $to -Spec $Spec -Label "inactive runtime-state destination '$($entry.Rel)'"
            if (-not (Get-Item -LiteralPath $from -Force -ErrorAction SilentlyContinue)) {
                throw "Cannot migrate ${Spec}: runtime state '$($entry.Rel)' disappeared during planning. No changes were made."
            }
            if (Get-Item -LiteralPath $to -Force -ErrorAction SilentlyContinue) {
                throw "Cannot migrate ${Spec}: inactive runtime-state destination '$($entry.Rel)' already exists. No changes were made."
            }
            $sourceVolume = Get-MigrationVolumeRoot -Path $from
            $destinationVolume = Get-MigrationVolumeRoot -Path $to
            if (-not $sourceVolume -or -not $destinationVolume -or
                -not $sourceVolume.Equals($destinationVolume, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Cannot migrate ${Spec}: runtime state '$($entry.Rel)' cannot be preserved by same-volume rename. No changes were made."
            }
            [void]$ops.Add((New-MigrationOp -Op 'preserve-runtime-state' -Rel $entry.Rel -From $from -To $to -Note 'inactive recovery'))
        }
    }
    $profileStateEntries = @($Classification.Entries | Where-Object { $_.Class -eq 'preserve-profile-state' })
    if ($profileStateEntries.Count -gt 0) {
        $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
        $inactiveBase = Join-Path $profileStore '.inactive'
        $inactiveRoot = Get-MigrationInactiveProfileStateRoot -ProfileDir $ProfileDir
        Assert-MigrationDestinationPathSafe -Root $inactiveBase -Target $inactiveRoot -Spec $Spec -Label 'inactive profile-state recovery root'
        if (Get-Item -LiteralPath $inactiveRoot -Force -ErrorAction SilentlyContinue) {
            throw "Cannot migrate ${Spec}: inactive profile-state recovery already exists. Inspect it before retrying. No changes were made."
        }
        foreach ($entry in $profileStateEntries) {
            $from = Join-Path $ProfileDir ($entry.Rel -replace '/', '\')
            $to = Join-Path $inactiveRoot ($entry.Rel -replace '/', '\')
            Assert-MigrationDestinationPathSafe -Root $inactiveBase -Target $to -Spec $Spec -Label "inactive profile-state destination '$($entry.Rel)'"
            if (-not (Get-Item -LiteralPath $from -Force -ErrorAction SilentlyContinue)) {
                throw "Cannot migrate ${Spec}: profile state '$($entry.Rel)' disappeared during planning. No changes were made."
            }
            if (Get-Item -LiteralPath $to -Force -ErrorAction SilentlyContinue) {
                throw "Cannot migrate ${Spec}: inactive profile-state destination '$($entry.Rel)' already exists. No changes were made."
            }
            $sourceVolume = Get-MigrationVolumeRoot -Path $from
            $destinationVolume = Get-MigrationVolumeRoot -Path $to
            if (-not $sourceVolume -or -not $destinationVolume -or
                -not $sourceVolume.Equals($destinationVolume, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Cannot migrate ${Spec}: profile state '$($entry.Rel)' cannot be preserved by same-volume rename. No changes were made."
            }
            [void]$ops.Add((New-MigrationOp -Op 'preserve-profile-state' -Rel $entry.Rel -From $from -To $to -Note 'inactive recovery'))
        }
    }
    $unknownEntries = @($Classification.Entries | Where-Object { $_.Class -eq 'preserve-unknown' })
    if ($unknownEntries.Count -gt 0) {
        $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
        $inactiveBase = Join-Path $profileStore '.inactive'
        $inactiveRoot = Get-MigrationInactiveUnknownRoot -ProfileDir $ProfileDir
        Assert-MigrationDestinationPathSafe -Root $inactiveBase -Target $inactiveRoot -Spec $Spec -Label 'inactive unknown-state recovery root'
        if (Get-Item -LiteralPath $inactiveRoot -Force -ErrorAction SilentlyContinue) {
            throw "Cannot migrate ${Spec}: inactive unknown-state recovery already exists. Inspect it before retrying. No changes were made."
        }
        foreach ($entry in $unknownEntries) {
            $from = Join-Path $ProfileDir ($entry.Rel -replace '/', '\')
            $to = Join-Path $inactiveRoot ($entry.Rel -replace '/', '\')
            Assert-MigrationDestinationPathSafe -Root $inactiveBase -Target $to -Spec $Spec -Label "inactive unknown-state destination '$($entry.Rel)'"
            if (-not (Get-Item -LiteralPath $from -Force -ErrorAction SilentlyContinue)) {
                throw "Cannot migrate ${Spec}: unknown state '$($entry.Rel)' disappeared during planning. No changes were made."
            }
            if (Get-Item -LiteralPath $to -Force -ErrorAction SilentlyContinue) {
                throw "Cannot migrate ${Spec}: inactive unknown-state destination '$($entry.Rel)' already exists. No changes were made."
            }
            $sourceVolume = Get-MigrationVolumeRoot -Path $from
            $destinationVolume = Get-MigrationVolumeRoot -Path $to
            if (-not $sourceVolume -or -not $destinationVolume -or
                -not $sourceVolume.Equals($destinationVolume, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Cannot migrate ${Spec}: unknown state '$($entry.Rel)' cannot be preserved by same-volume rename. No changes were made."
            }
            [void]$ops.Add((New-MigrationOp -Op 'preserve-unknown' -Rel $entry.Rel -From $from -To $to -Note 'explicit inactive recovery'))
        }
    }
    foreach ($entry in @($Classification.Entries | Where-Object { $_.Class -eq 'shared' -or $_.Class -eq 'session' })) {
        Add-MigrationSharedPlan -ProfileDir $ProfileDir -SharedRoot $SharedRoot -Rel $entry.Rel -Kind $entry.Class -PreferProfile $PreferProfile -Spec $Spec -Declarations $Declarations -Ops $ops
    }
    foreach ($entry in @($Classification.Entries | Where-Object { $_.Class -eq 'metadata' })) {
        [void]$ops.Add((New-MigrationOp -Op 'keep-metadata' -Rel $entry.Rel -From '' -To '' -Note ''))
    }
    # Declared credential files the legacy profile never had get the same empty
    # placeholders the runtime creates for fresh schema-v2 profiles.
    foreach ($cred in $Declarations.Credentials) {
        $covered = $false
        foreach ($op in $ops) {
            if (($op.Op -eq 'move-credential' -or $op.Op -eq 'remove-duplicate-credential') -and $op.Rel -eq $cred) {
                $covered = $true
                break
            }
        }
        if ($covered) { continue }
        if (Test-Path -LiteralPath (Join-Path $ProfileDir ($cred -replace '/', '\'))) { continue }
        $authRoot = Join-Path $ProfileDir 'auth'
        $placeholder = Join-Path $authRoot ($cred -replace '/', '\')
        if (Test-Path -LiteralPath $placeholder) { continue }
        Assert-MigrationDestinationPathSafe -Root $authRoot -Target $placeholder -Spec $Spec -Label "credential destination 'auth/$cred'"
        [void]$ops.Add((New-MigrationOp -Op 'ensure-placeholder' -Rel $cred -From '' -To $placeholder -Note ''))
    }
    [void]$ops.Add((New-MigrationOp -Op 'write-metadata' -Rel '.profile.json' -From '' -To (Join-Path $ProfileDir '.profile.json') -Note ''))
    return , $ops
}

function Test-MigrationObjectExists {
    param([string]$Path)
    return $null -ne (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
}

function Get-MigrationInactiveSharedCredentialRoot {
    param([string]$ProfileDir)
    $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
    $tool = Split-Path -Leaf (Split-Path -Parent $ProfileDir)
    $name = Split-Path -Leaf $ProfileDir
    return Join-Path $profileStore ".inactive\migrations\$tool\$name\shared-credentials"
}

function Get-MigrationInactiveRuntimeRoot {
    param([string]$ProfileDir)
    $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
    $tool = Split-Path -Leaf (Split-Path -Parent $ProfileDir)
    $name = Split-Path -Leaf $ProfileDir
    return Join-Path $profileStore ".inactive\migrations\$tool\$name\runtime-state"
}

function Get-MigrationInactiveProfileStateRoot {
    param([string]$ProfileDir)
    $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
    $tool = Split-Path -Leaf (Split-Path -Parent $ProfileDir)
    $name = Split-Path -Leaf $ProfileDir
    return Join-Path $profileStore ".inactive\migrations\$tool\$name\profile-state"
}

function Get-MigrationInactiveUnknownRoot {
    param([string]$ProfileDir)
    $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
    $tool = Split-Path -Leaf (Split-Path -Parent $ProfileDir)
    $name = Split-Path -Leaf $ProfileDir
    return Join-Path $profileStore ".inactive\migrations\$tool\$name\unknown-state"
}

# =============================================================================
# Journal
# =============================================================================

# Write the journal atomically (temp + move): overall status plus every op
# with its current status, so a crash mid-migration leaves a truthful record.
function Write-MigrationJournal {
    param([string]$JournalPath, [string]$Status, $Context, $Ops)
    $preserveUnknown = @($Ops | Where-Object { $_.Op -eq 'preserve-unknown' }).Count -gt 0
    $retryCommand = "nini-agents migrate $($Context.Tool)/$($Context.Name)"
    if ($Context.PreferProfile) { $retryCommand += ' --prefer-profile' }
    if ($preserveUnknown) { $retryCommand += ' --preserve-unknown' }
    $payload = [ordered]@{
        tool          = $Context.Tool
        profile       = $Context.Name
        sharedRoot    = $Context.SharedRoot
        status        = $Status
        preferProfile = [bool]$Context.PreferProfile
        preserveUnknown = [bool]$preserveUnknown
        action        = "Automatic rollback is attempted after any failed apply. Re-run '$retryCommand' only when status is rolled_back; do not launch when status is rollback_failed."
        operations    = @($Ops)
    }
    $temporaryPath = "$JournalPath.tmp"
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $JournalPath -Force
}

# =============================================================================
# Reporting
# =============================================================================

# One human-readable plan line for an operation.
function Get-MigrationOpLine {
    param($Op)
    switch ($Op.Op) {
        'move-credential'             { return "  move credential $($Op.Rel) -> auth/$($Op.Rel)" }
        'remove-duplicate-credential' { return "  remove duplicate credential $($Op.Rel) (already migrated)" }
        'preserve-shared-credential'   { return "  preserve shared credential $($Op.Rel) in inactive recovery" }
        'preserve-runtime-state'       { return "  preserve runtime state $($Op.Rel) in inactive recovery" }
        'preserve-profile-state'       { return "  preserve profile state $($Op.Rel) in inactive recovery" }
        'preserve-unknown'             { return "  preserve unknown state $($Op.Rel) in inactive recovery (--preserve-unknown)" }
        'merge-move'                  { return "  merge $($Op.Note) $($Op.Rel) -> $($Op.To)" }
        'remove-duplicate'            { return "  remove duplicate $($Op.Rel) (shared root already has identical content)" }
        'skip-conflict'               { return "  skip $($Op.Rel) (conflict: $($Op.Note); use --prefer-profile to override)" }
        'replace-shared'              { return "  replace $($Op.Rel) -> $($Op.To) (--prefer-profile: $($Op.Note))" }
        'keep-link'                   { return "  keep shared link $($Op.Rel) ($($Op.Note))" }
        'skip-link'                   { return "  skip nested link $($Op.Rel) ($($Op.Note))" }
        'skip-credential-lookalike'   { return "  skip $($Op.Rel) ($($Op.Note))" }
        'keep-metadata'               { return "  keep launcher metadata $($Op.Rel)" }
        'ensure-placeholder'          { return "  create empty credential placeholder auth/$($Op.Rel)" }
        'write-metadata'              { return '  write .profile.json (schemaVersion 2, mode accountOverlay)' }
        default                       { return "  $($Op.Op) $($Op.Rel)" }
    }
}

# =============================================================================
# Execution
# =============================================================================

# Move one entry, creating the destination parents first.
function Invoke-MigrationFileMove {
    param([string]$From, [string]$To)
    $parent = Split-Path -Parent $To
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $sourceVolume = Get-MigrationVolumeRoot -Path $From
    $destinationVolume = Get-MigrationVolumeRoot -Path $parent
    if (-not $sourceVolume -or -not $destinationVolume -or
        -not $sourceVolume.Equals($destinationVolume, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'migration move would cross volumes and copy data'
    }
    Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop
}

# Same-volume Move-Item is a rename. Reject links before it and verify that the
# source disappeared and exactly one regular credential path remains.
function Invoke-MigrationCredentialMove {
    param([string]$From, [string]$To)
    $source = Get-Item -LiteralPath $From -Force -ErrorAction Stop
    $linkType = Get-MigrationProperty -Object $source -Name 'LinkType'
    if (($source.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $linkType -eq 'HardLink') {
        throw 'credential identity verification failed before move'
    }
    $sourceVolume = Get-MigrationVolumeRoot -Path $From
    $destinationVolume = Get-MigrationVolumeRoot -Path $To
    if (-not $sourceVolume -or -not $destinationVolume -or
        -not $sourceVolume.Equals($destinationVolume, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'credential destination volume changed before move'
    }
    Invoke-MigrationFileMove -From $From -To $To
    try {
        if (Test-Path -LiteralPath $From) { throw 'credential source still exists after move' }
        $destination = Get-Item -LiteralPath $To -Force -ErrorAction Stop
        $destinationLinkType = Get-MigrationProperty -Object $destination -Name 'LinkType'
        if ($destination.PSIsContainer -or
            ($destination.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $destinationLinkType -eq 'HardLink') {
            throw 'credential destination is not one regular file'
        }
    } catch {
        if (-not (Test-Path -LiteralPath $From) -and (Test-Path -LiteralPath $To)) {
            try { Invoke-MigrationFileMove -From $To -To $From } catch { }
        }
        throw
    }
}

function Get-MigrationRollbackSlot {
    param([string]$RollbackRoot, [int]$Index)
    return Join-Path $RollbackRoot ('{0:D6}' -f $Index)
}

function Register-MigrationMissingParentDirs {
    param([string]$Target, [string]$Boundary, $Context)
    $boundaryFull = [System.IO.Path]::GetFullPath($Boundary).TrimEnd('\', '/')
    $current = [System.IO.Path]::GetFullPath((Split-Path -Parent $Target)).TrimEnd('\', '/')
    $missing = @()
    while (-not $current.Equals($boundaryFull, [StringComparison]::OrdinalIgnoreCase)) {
        if (-not $current.StartsWith("$boundaryFull\", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'destination escaped its migration boundary'
        }
        if (-not (Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue)) {
            $missing += $current
        }
        $current = [System.IO.Path]::GetFullPath((Split-Path -Parent $current)).TrimEnd('\', '/')
    }
    for ($index = $missing.Count - 1; $index -ge 0; $index--) {
        [void]$Context.CreatedDestinationDirs.Add($missing[$index])
    }
}

function Remove-MigrationCreatedDestinationDirs {
    param($Context)
    for ($index = $Context.CreatedDestinationDirs.Count - 1; $index -ge 0; $index--) {
        $dir = [string]$Context.CreatedDestinationDirs[$index]
        $item = Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        if (-not $item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if (@(Get-ChildItem -LiteralPath $dir -Force).Count -ne 0) { return $false }
        try { Remove-Item -LiteralPath $dir -Force -ErrorAction Stop }
        catch { return $false }
    }
    return $true
}

function Remove-MigrationCreatedSharedRoot {
    param($Context)
    if (-not $Context.SharedRootCreated) { return $true }
    $item = Get-Item -LiteralPath $Context.SharedRoot -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $true }
    if (-not $item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    if (@(Get-ChildItem -LiteralPath $Context.SharedRoot -Force).Count -ne 0) { return $false }
    try {
        Remove-Item -LiteralPath $Context.SharedRoot -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Move-MigrationEntryToRollback {
    param([string]$From, [string]$Slot)
    if (Test-Path -LiteralPath $Slot) { throw "rollback slot already exists: $Slot" }
    $parent = Split-Path -Parent $Slot
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Invoke-MigrationFileMove -From $From -To $Slot
}

# Replace the shared-root target while retaining it in private rollback
# staging until the completed journal is durable.
function Invoke-MigrationReplace {
    param([string]$From, [string]$To, [string]$RollbackSlot)
    Move-MigrationEntryToRollback -From $To -Slot $RollbackSlot
    try {
        Invoke-MigrationFileMove -From $From -To $To
    } catch {
        try { Invoke-MigrationFileMove -From $RollbackSlot -To $To } catch { }
        throw
    }
}

# Create an empty credential placeholder file (and parents) when missing.
function Invoke-MigrationPlaceholder {
    param([string]$To)
    $parent = Split-Path -Parent $To
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (-not (Test-Path -LiteralPath $To)) { New-Item -ItemType File -Force -Path $To | Out-Null }
}

# Same metadata shape the runtime writes for fresh schema-v2 profiles.
function Write-MigrationProfileMetadata {
    param($Adapter, [string]$ProfileDir)
    $metadata = [ordered]@{
        schemaVersion = 2
        adapterId     = $Adapter.id
        profileId     = [guid]::NewGuid().ToString()
        mode          = 'accountOverlay'
    }
    $temporaryPath = Join-Path $ProfileDir '.profile.json.tmp'
    $metadata | ConvertTo-Json | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination (Join-Path $ProfileDir '.profile.json') -Force
}

# Remove directories left empty by moves, keeping the schema-v2 skeleton and
# never touching reparse points.
function Remove-MigrationEmptyDirs {
    param([string]$ProfileDir)
    $dirs = @()
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue('')
    while ($queue.Count -gt 0) {
        $rel = $queue.Dequeue()
        $dir = $ProfileDir
        if ($rel) { $dir = Join-Path $ProfileDir $rel }
        foreach ($item in (Get-ChildItem -LiteralPath $dir -Directory -Force)) {
            $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
            if ($isReparse) { continue }
            $childRel = $item.Name
            if ($rel) { $childRel = "$rel/$($item.Name)" }
            $dirs += $childRel
            $queue.Enqueue($childRel)
        }
    }
    foreach ($rel in ($dirs | Sort-Object { $_.Length } -Descending)) {
        if ($rel -eq 'auth' -or $rel -like 'auth/*' -or $rel -like '.runtime*') { continue }
        $full = Join-Path $ProfileDir ($rel -replace '/', '\')
        if (@(Get-ChildItem -LiteralPath $full -Force).Count -eq 0) {
            Remove-Item -LiteralPath $full -Force
        }
    }
}

# Reverse completed operations in strict reverse order. No credential is
# copied: rename operations are inverted, and recoverable shared targets move
# back out of private rollback staging.
function Undo-MigrationOps {
    param([string]$ProfileDir, [string]$RollbackRoot, $Ops)
    $rollbackFailed = $false
    for ($index = $Ops.Count - 1; $index -ge 0; $index--) {
        $op = $Ops[$index]
        if ($op.Status -ne 'done') { continue }
        $slot = Get-MigrationRollbackSlot -RollbackRoot $RollbackRoot -Index $index
        try {
            switch ($op.Op) {
                { $_ -in 'move-credential', 'merge-move', 'preserve-shared-credential', 'preserve-runtime-state', 'preserve-profile-state', 'preserve-unknown' } {
                    if ((Test-MigrationObjectExists -Path $op.From) -or -not (Test-MigrationObjectExists -Path $op.To)) { throw 'move rollback precondition failed' }
                    Invoke-MigrationFileMove -From $op.To -To $op.From
                }
                { $_ -in 'remove-duplicate', 'remove-duplicate-credential' } {
                    if ((Test-Path -LiteralPath $op.From) -or -not (Test-Path -LiteralPath $slot)) { throw 'dedupe rollback precondition failed' }
                    Invoke-MigrationFileMove -From $slot -To $op.From
                }
                'replace-shared' {
                    if ((Test-Path -LiteralPath $op.From) -or -not (Test-Path -LiteralPath $op.To) -or -not (Test-Path -LiteralPath $slot)) {
                        throw 'replace rollback precondition failed'
                    }
                    Invoke-MigrationFileMove -From $op.To -To $op.From
                    Invoke-MigrationFileMove -From $slot -To $op.To
                }
                'ensure-placeholder' {
                    $placeholder = Get-Item -LiteralPath $op.To -Force -ErrorAction Stop
                    if ($placeholder.PSIsContainer -or $placeholder.Length -ne 0 -or
                        ($placeholder.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw 'placeholder changed before rollback'
                    }
                    Remove-Item -LiteralPath $op.To -Force -ErrorAction Stop
                }
                'write-metadata' {
                    Remove-Item -LiteralPath $op.To -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath "$($op.To).tmp" -Force -ErrorAction SilentlyContinue
                }
                default { throw "cannot roll back operation '$($op.Op)'" }
            }
            $op.Status = 'rolled-back'
        } catch {
            $rollbackFailed = $true
        }
    }
    if ($rollbackFailed) { return $false }
    if (Test-Path -LiteralPath $RollbackRoot) {
        if (Test-MigrationReparsePoint -Path $RollbackRoot) { return $false }
        try { Remove-Item -LiteralPath $RollbackRoot -Recurse -Force -ErrorAction Stop }
        catch { return $false }
    }
    return $true
}

function Remove-MigrationRollbackRoot {
    param([string]$ProfileDir, [string]$RollbackRoot)
    $expected = Join-Path $ProfileDir $script:MigrationRollbackName
    if (-not $RollbackRoot.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not (Test-Path -LiteralPath $RollbackRoot)) { return $true }
    if (Test-MigrationReparsePoint -Path $RollbackRoot) { return $false }
    try {
        Remove-Item -LiteralPath $RollbackRoot -Recurse -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Test-MigrationLegacyFailureState {
    param([string]$ProfileDir, [string]$RollbackRoot, $Context, $Ops)
    if ((Test-Path -LiteralPath (Join-Path $ProfileDir '.profile.json')) -or
        (Test-Path -LiteralPath (Join-Path $ProfileDir '.profile.json.tmp')) -or
        (Test-Path -LiteralPath $RollbackRoot)) { return $false }
    if ($Context.SharedRootCreated -and (Test-Path -LiteralPath $Context.SharedRoot)) { return $false }
    for ($index = 0; $index -lt $Ops.Count; $index++) {
        $op = $Ops[$index]
        if ($op.Status -eq 'done') { return $false }
        if ($op.Status -ne 'failed') { continue }
        $slot = Get-MigrationRollbackSlot -RollbackRoot $RollbackRoot -Index $index
        switch ($op.Op) {
            { $_ -in 'move-credential', 'merge-move', 'preserve-shared-credential', 'preserve-runtime-state', 'preserve-profile-state', 'preserve-unknown' } {
                if (-not (Test-MigrationObjectExists -Path $op.From) -or (Test-MigrationObjectExists -Path $op.To)) { return $false }
            }
            { $_ -in 'remove-duplicate', 'remove-duplicate-credential' } {
                if (-not (Test-Path -LiteralPath $op.From) -or (Test-Path -LiteralPath $slot)) { return $false }
            }
            'replace-shared' {
                if (-not (Test-Path -LiteralPath $op.From) -or -not (Test-Path -LiteralPath $op.To) -or (Test-Path -LiteralPath $slot)) { return $false }
            }
            'ensure-placeholder' {
                if (Test-Path -LiteralPath $op.To) { return $false }
            }
            'write-metadata' {
                if ((Test-Path -LiteralPath $op.To) -or (Test-Path -LiteralPath "$($op.To).tmp")) { return $false }
            }
        }
    }
    return $true
}

function Invoke-MigrationFailure {
    param([int]$Index, [string]$Failure, [string]$ProfileDir, [string]$RollbackRoot, [string]$JournalPath, $Context, $Ops)
    if ($Index -ge 0) { $Ops[$Index].Status = 'failed' }
    try { Write-MigrationJournal -JournalPath $JournalPath -Status 'failed' -Context $Context -Ops $Ops } catch { }
    if ((Undo-MigrationOps -ProfileDir $ProfileDir -RollbackRoot $RollbackRoot -Ops $Ops) -and
        (Remove-MigrationCreatedDestinationDirs -Context $Context) -and
        (Remove-MigrationCreatedSharedRoot -Context $Context) -and
        (Test-MigrationLegacyFailureState -ProfileDir $ProfileDir -RollbackRoot $RollbackRoot -Context $Context -Ops $Ops)) {
        try { Write-MigrationJournal -JournalPath $JournalPath -Status 'rolled_back' -Context $Context -Ops $Ops } catch { }
        throw "Migration failed: $Failure`nAutomatic rollback restored the legacy layout. Journal written to $JournalPath`nFix the cause, verify the profile is idle, and re-run 'nini-agents migrate $($Context.Spec)'."
    }
    try { Write-MigrationJournal -JournalPath $JournalPath -Status 'rollback_failed' -Context $Context -Ops $Ops } catch { }
    throw "Migration failed: $Failure`nAutomatic rollback could not prove the legacy layout was restored. Do not launch this profile. Preserve $JournalPath and $RollbackRoot for recovery."
}

# Run every planned op in order, journaling after each. Any failure rolls all
# completed operations back before the command returns.
function Invoke-MigrationOps {
    param($Adapter, [string]$ProfileDir, [string]$JournalPath, $Context, $Ops, $Lines)
    $rollbackRoot = Join-Path $ProfileDir $script:MigrationRollbackName
    for ($index = 0; $index -lt $Ops.Count; $index++) {
        $op = $Ops[$index]
        $slot = Get-MigrationRollbackSlot -RollbackRoot $rollbackRoot -Index $index
        $failed = $null
        try {
            switch ($op.Op) {
                { $_ -in 'keep-metadata', 'keep-link', 'skip-conflict', 'skip-link', 'skip-credential-lookalike' } {
                    $op.Status = 'skipped'
                }
                { $_ -in 'remove-duplicate', 'remove-duplicate-credential' } {
                    Move-MigrationEntryToRollback -From $op.From -Slot $slot
                    $op.Status = 'done'
                }
                'move-credential' {
                    Register-MigrationMissingParentDirs -Target $op.To -Boundary $ProfileDir -Context $Context
                    Invoke-MigrationCredentialMove -From $op.From -To $op.To
                    $op.Status = 'done'
                }
                'preserve-shared-credential' {
                    $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
                    Register-MigrationMissingParentDirs -Target $op.To -Boundary $profileStore -Context $Context
                    $inactiveBase = Join-Path $profileStore '.inactive'
                    Assert-MigrationDestinationPathSafe -Root $inactiveBase -Target $op.To -Spec $Context.Spec -Label "inactive shared-credential destination '$($op.Rel)'"
                    if (Get-Item -LiteralPath $op.To -Force -ErrorAction SilentlyContinue) {
                        throw "inactive shared-credential destination '$($op.Rel)' appeared during apply"
                    }
                    Invoke-MigrationFileMove -From $op.From -To $op.To
                    $op.Status = 'done'
                }
                'preserve-runtime-state' {
                    $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
                    Register-MigrationMissingParentDirs -Target $op.To -Boundary $profileStore -Context $Context
                    $inactiveBase = Join-Path $profileStore '.inactive'
                    Assert-MigrationDestinationPathSafe -Root $inactiveBase -Target $op.To -Spec $Context.Spec -Label "inactive runtime-state destination '$($op.Rel)'"
                    if (Get-Item -LiteralPath $op.To -Force -ErrorAction SilentlyContinue) {
                        throw "inactive runtime-state destination '$($op.Rel)' appeared during apply"
                    }
                    Invoke-MigrationFileMove -From $op.From -To $op.To
                    $op.Status = 'done'
                }
                'preserve-profile-state' {
                    $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
                    Register-MigrationMissingParentDirs -Target $op.To -Boundary $profileStore -Context $Context
                    $inactiveBase = Join-Path $profileStore '.inactive'
                    Assert-MigrationDestinationPathSafe -Root $inactiveBase -Target $op.To -Spec $Context.Spec -Label "inactive profile-state destination '$($op.Rel)'"
                    if (Get-Item -LiteralPath $op.To -Force -ErrorAction SilentlyContinue) {
                        throw "inactive profile-state destination '$($op.Rel)' appeared during apply"
                    }
                    Invoke-MigrationFileMove -From $op.From -To $op.To
                    $op.Status = 'done'
                }
                'preserve-unknown' {
                    $profileStore = Split-Path -Parent (Split-Path -Parent $ProfileDir)
                    Register-MigrationMissingParentDirs -Target $op.To -Boundary $profileStore -Context $Context
                    $inactiveBase = Join-Path $profileStore '.inactive'
                    Assert-MigrationDestinationPathSafe -Root $inactiveBase -Target $op.To -Spec $Context.Spec -Label "inactive unknown-state destination '$($op.Rel)'"
                    if (Get-Item -LiteralPath $op.To -Force -ErrorAction SilentlyContinue) {
                        throw "inactive unknown-state destination '$($op.Rel)' appeared during apply"
                    }
                    Invoke-MigrationFileMove -From $op.From -To $op.To
                    $op.Status = 'done'
                }
                'merge-move' {
                    Register-MigrationMissingParentDirs -Target $op.To -Boundary $Context.SharedRoot -Context $Context
                    Invoke-MigrationFileMove -From $op.From -To $op.To
                    $op.Status = 'done'
                }
                'replace-shared' {
                    Invoke-MigrationReplace -From $op.From -To $op.To -RollbackSlot $slot
                    $op.Status = 'done'
                }
                'ensure-placeholder' {
                    Register-MigrationMissingParentDirs -Target $op.To -Boundary $ProfileDir -Context $Context
                    Invoke-MigrationPlaceholder -To $op.To
                    $op.Status = 'done'
                }
                'write-metadata' {
                    try {
                        Write-MigrationProfileMetadata -Adapter $Adapter -ProfileDir $ProfileDir
                    } catch {
                        Remove-Item -LiteralPath (Join-Path $ProfileDir '.profile.json') -Force -ErrorAction SilentlyContinue
                        Remove-Item -LiteralPath (Join-Path $ProfileDir '.profile.json.tmp') -Force -ErrorAction SilentlyContinue
                        throw
                    }
                    $op.Status = 'done'
                }
                default {
                    throw "unknown operation '$($op.Op)'"
                }
            }
        } catch {
            $failed = $_.Exception.Message
        }
        if ($failed) {
            Invoke-MigrationFailure -Index $index -Failure $failed -ProfileDir $ProfileDir -RollbackRoot $rollbackRoot -JournalPath $JournalPath -Context $Context -Ops $Ops
        }
        $line = Get-MigrationOpLine -Op $op
        $Lines.Add($line) | Out-Null
        Write-Host $line
        try { Write-MigrationJournal -JournalPath $JournalPath -Status 'running' -Context $Context -Ops $Ops }
        catch {
            Invoke-MigrationFailure -Index -1 -Failure 'could not update the migration journal' -ProfileDir $ProfileDir -RollbackRoot $rollbackRoot -JournalPath $JournalPath -Context $Context -Ops $Ops
        }
    }
}

# =============================================================================
# Entry point -- wired into the launcher as `nini-agents migrate`
# =============================================================================

# Entry point wired to `nini-agents migrate`. Refuses unclassifiable profiles
# before writing, plans, then either prints the plan (dry run) or executes it
# under the journal. Returns a result object with Lines/Migrated/JournalPath.
function Invoke-MultiCliMigration {
    param(
        [Parameter(Mandatory = $true)]$Adapter,
        [Parameter(Mandatory = $true)][string]$ProfileDir,
        [switch]$DryRun,
        [switch]$PreferProfile,
        [switch]$PreserveUnknown,
        [scriptblock]$ProcessProbe
    )
    $tool = $Adapter.id
    $name = Split-Path -Leaf ($ProfileDir.TrimEnd('\', '/'))
    $spec = "$tool/$name"
    if (-not (Test-Path -LiteralPath $ProfileDir -PathType Container)) { throw "Profile '$spec' does not exist" }
    Assert-MigrationControlPathsSafe -ProfileDir $ProfileDir -Spec $spec
    $rollbackRoot = Join-Path $ProfileDir $script:MigrationRollbackName

    if (-not (Test-MultiCliLegacyProfile -ProfileDir $ProfileDir)) {
        $line = "Profile '$spec' is already schema-v2 (accountOverlay); nothing to do."
        Write-Host $line
        return [pscustomobject]@{ Spec = $spec; Mode = 'noop'; Migrated = $false; Lines = @($line); JournalPath = $null }
    }

    $account = Get-MigrationProperty -Object $Adapter -Name 'account'
    $mechanism = Get-MigrationProperty -Object $account -Name 'mechanism'
    switch ($mechanism) {
        'fileOverlay' { }
        'processSecret' { }
        'osUserCredentialStore' {
            throw "Cannot migrate ${spec}: adapter '$tool' uses 'osUserCredentialStore' credentials. Only fileOverlay and processSecret adapters can be migrated; keep the legacy profile."
        }
        'inseparable' {
            $reason = Get-MigrationProperty -Object $account -Name 'reason'
            throw "Cannot migrate ${spec}: adapter '$tool' is marked inseparable ($reason) Keep the legacy-isolated profile."
        }
        default {
            throw "Cannot migrate ${spec}: unsupported account mechanism '$mechanism'."
        }
    }

    $sharedRoot = Get-MigrationSharedRoot -Adapter $Adapter
    Assert-MigrationDestinationPathSafe -Root $sharedRoot -Target $sharedRoot -Spec $spec -Label 'shared-state root'

    # Atomic moves need profile storage and the shared root on one volume.
    $profileRoot = Get-MigrationVolumeRoot -Path $ProfileDir
    $sharedVolume = Get-MigrationVolumeRoot -Path $sharedRoot
    if (-not $profileRoot.Equals($sharedVolume, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Cannot migrate ${spec}: profile storage and the shared state root '$sharedRoot' are on different volumes. Migration uses atomic same-volume moves; set MULTICLI_HOME to the same volume as '$sharedRoot' and retry."
    }

    $declarations = Get-MigrationDeclarations -Adapter $Adapter
    $classification = Get-MigrationClassification -ProfileDir $ProfileDir -Declarations $declarations
    if ($PreserveUnknown -and $classification.Unknown.Count -gt 0) {
        foreach ($entry in @($classification.Unknown)) {
            $classification.Entries += [pscustomobject]@{ Class = 'preserve-unknown'; Rel = $entry }
        }
        $classification.Unknown = @()
    }
    if ($classification.Unknown.Count -gt 0 -or $classification.Overlap.Count -gt 0 -or $classification.Unsafe.Count -gt 0) {
        throw (Get-MigrationRefusalMessage -Spec $spec -Classification $classification)
    }

    $ops = New-MigrationPlan -ProfileDir $ProfileDir -SharedRoot $sharedRoot -PreferProfile ([bool]$PreferProfile) -Spec $spec -Classification $classification -Declarations $declarations

    $lines = New-Object System.Collections.ArrayList
    if ($DryRun) {
        [void]$lines.Add("Migration plan for $spec (legacy-isolated -> accountOverlay):")
        foreach ($op in $ops) { [void]$lines.Add((Get-MigrationOpLine -Op $op)) }
        [void]$lines.Add('Dry run -- no changes written.')
        foreach ($line in $lines) { Write-Host $line }
        return [pscustomobject]@{ Spec = $spec; Mode = 'dry-run'; Migrated = $false; Lines = @($lines); JournalPath = $null }
    }

    Assert-MigrationProcessIdle -Adapter $Adapter -ProfileDir $ProfileDir -Spec $spec -ProcessProbe $ProcessProbe
    [void]$lines.Add("Migrating $spec (legacy-isolated -> accountOverlay):")
    Write-Host $lines[0]
    $journalPath = Join-Path $ProfileDir $script:MigrationJournalName
    $context = [pscustomobject]@{
        Tool          = $tool
        Name          = $name
        Spec          = $spec
        SharedRoot    = $sharedRoot
        PreferProfile = [bool]$PreferProfile
        SharedRootCreated = $false
        CreatedDestinationDirs = (New-Object System.Collections.ArrayList)
    }
    $lock = Enter-MigrationLock -ProfileDir $ProfileDir -Spec $spec
    try {
        if (Get-Item -LiteralPath $rollbackRoot -Force -ErrorAction SilentlyContinue) {
            throw "Cannot migrate ${spec}: recovery artifacts appeared while acquiring the migration lock. No profile data was changed."
        }
        Assert-MigrationProcessIdle -Adapter $Adapter -ProfileDir $ProfileDir -Spec $spec -ProcessProbe $ProcessProbe -AfterLock
        try { Write-MigrationJournal -JournalPath $journalPath -Status 'running' -Context $context -Ops $ops }
        catch { throw "Cannot migrate ${spec}: could not create the migration journal. No profile data was changed." }
        $context.SharedRootCreated = -not [bool](Get-Item -LiteralPath $sharedRoot -Force -ErrorAction SilentlyContinue)
        try { New-Item -ItemType Directory -Force -Path $sharedRoot -ErrorAction Stop | Out-Null }
        catch {
            if (Remove-MigrationCreatedSharedRoot -Context $context) {
                try { Write-MigrationJournal -JournalPath $journalPath -Status 'rolled_back' -Context $context -Ops $ops } catch { }
                throw "Cannot migrate ${spec}: could not prepare the shared state root. No profile data was changed."
            }
            try { Write-MigrationJournal -JournalPath $journalPath -Status 'rollback_failed' -Context $context -Ops $ops } catch { }
            throw "Cannot migrate ${spec}: could not prepare or remove the new shared state root. Do not launch this profile; preserve the journal for recovery."
        }
        Invoke-MigrationOps -Adapter $Adapter -ProfileDir $ProfileDir -JournalPath $journalPath -Context $context -Ops $ops -Lines $lines
        Remove-MigrationEmptyDirs -ProfileDir $ProfileDir
        try { Write-MigrationJournal -JournalPath $journalPath -Status 'completed' -Context $context -Ops $ops }
        catch {
            Invoke-MigrationFailure -Index -1 -Failure 'could not finalize the migration journal' -ProfileDir $ProfileDir -RollbackRoot $rollbackRoot -JournalPath $journalPath -Context $context -Ops $ops
        }
        if (-not (Remove-MigrationRollbackRoot -ProfileDir $ProfileDir -RollbackRoot $rollbackRoot)) {
            throw "Migration reached schema-v2 but could not remove recovery artifacts at $rollbackRoot. Do not launch the profile until they are inspected."
        }
    } finally {
        if (-not (Exit-MigrationLock -LockPath $lock)) {
            Write-Warning "Migration lock could not be released at $lock. Inspect it before the next migration."
        }
    }
    [void]$lines.Add("Migrated $spec to schema-v2 (accountOverlay).")
    Write-Host "Migrated $spec to schema-v2 (accountOverlay)."
    if ($mechanism -eq 'processSecret') {
        $note = "Note: adapter '$tool' uses process-secret credentials. Run: nini-agents auth set $spec before launching."
        [void]$lines.Add($note)
        Write-Host $note
    }
    return [pscustomobject]@{ Spec = $spec; Mode = 'apply'; Migrated = $true; Lines = @($lines); JournalPath = $journalPath }
}

Export-ModuleMember -Function Test-MultiCliLegacyProfile, Invoke-MultiCliMigration
