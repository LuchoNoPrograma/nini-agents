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
#   - legacy --shared links are recognized and left in place;
#   - entries the adapter does not declare (or that match both credential and
#     shared declarations) refuse the migration before anything is written;
#   - every filesystem operation is journaled to
#     <profile>/.migration-journal.json so a failure leaves a
#     roll-forward/rollback report on disk. All moves are same-volume atomic.

Set-StrictMode -Version Latest

$script:MigrationJournalName = '.migration-journal.json'
$script:MigrationMetaEntries = @('.shared', '.cli', '.profile.json', '.runtime', '.isolated', 'auth')

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

# Launcher/migration-owned entries that are never tool state. 'auth' and
# '.runtime' predate this migration only in partial/failed runs; a legacy
# profile cannot meaningfully own them.
function Test-MigrationMetaEntry {
    param([string]$Rel)
    if ($script:MigrationMetaEntries -contains $Rel) { return $true }
    if ($Rel -like "$($script:MigrationJournalName)*") { return $true }
    return $false
}

# Classify every entry of the profile tree: credential, shared, session,
# metadata, unknown, or overlapping. Unknown/overlap refuse the migration.
function Get-MigrationClassification {
    param([string]$ProfileDir, $Declarations)
    $result = @{ Entries = @(); Unknown = @(); Overlap = @() }
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
        $stateMatch = $sharedMatch
        if (-not $stateMatch) { $stateMatch = $sessionMatch }
        if ($credMatch -and $stateMatch) {
            $Result.Overlap += $rel
            continue
        }
        $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        if ($credMatch) {
            if ($item.PSIsContainer -and -not $isReparse -and $rel -ne $credMatch -and $credMatch.StartsWith("$rel/")) {
                Add-MigrationClassification -Dir $item.FullName -Prefix $rel -Declarations $Declarations -Result $Result
            } else {
                $Result.Entries += [pscustomobject]@{ Class = 'credential'; Rel = $rel }
            }
            continue
        }
        if ($stateMatch) {
            $class = 'shared'
            if ($sessionMatch -and -not $sharedMatch) { $class = 'session' }
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
    $message += "`nDeclare the paths in the adapter (sharedPaths, sessionPaths, credentialFiles) or remove them from the profile. No changes were made."
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

# The link target for plan reporting; '?' when unreadable. Never throws.
function Get-MigrationLinkTarget {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Target) { return ($item.Target -join ';') }
    } catch {
        # Unreadable target; the link is still left in place.
    }
    return '?'
}

# Plan one file against its shared-root target: move when absent, dedupe when
# identical, replace only with -PreferProfile, otherwise skip the conflict.
function Add-MigrationFileMergePlan {
    param([string]$From, [string]$To, [string]$Rel, [string]$Kind, [bool]$PreferProfile, $Ops)
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
    param([string]$ProfileDir, [string]$SharedRoot, [string]$Rel, [string]$Kind, [bool]$PreferProfile, $Declarations, $Ops)
    $from = Join-Path $ProfileDir ($Rel -replace '/', '\')
    $to = Join-Path $SharedRoot ($Rel -replace '/', '\')
    if (Test-MigrationReparsePoint -Path $from) {
        $target = Get-MigrationLinkTarget -Path $from
        [void]$Ops.Add((New-MigrationOp -Op 'keep-link' -Rel $Rel -From $from -To $to -Note "target: $target"))
        return
    }
    if (Test-Path -LiteralPath $from -PathType Leaf) {
        Add-MigrationFileMergePlan -From $from -To $to -Rel $Rel -Kind $Kind -PreferProfile $PreferProfile -Ops $Ops
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
        Add-MigrationFileMergePlan -From $item.FullName -To (Join-Path $to ($sub -replace '/', '\')) -Rel $childRel -Kind $Kind -PreferProfile $PreferProfile -Ops $Ops
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
        $to = Join-Path (Join-Path $ProfileDir 'auth') ($entry.Rel -replace '/', '\')
        if (Test-MigrationReparsePoint -Path $from) {
            throw "Cannot migrate ${Spec}: credential '$($entry.Rel)' is a link. Replace it with the real credential file before migrating. No changes were made."
        }
        if (Test-Path -LiteralPath $to) {
            $bothFiles = (Test-Path -LiteralPath $to -PathType Leaf) -and (Test-Path -LiteralPath $from -PathType Leaf)
            if ($bothFiles -and (Test-MigrationContentEqual -First $from -Second $to)) {
                [void]$ops.Add((New-MigrationOp -Op 'remove-duplicate-credential' -Rel $entry.Rel -From $from -To $to -Note ''))
            } else {
                throw "Cannot migrate ${Spec}: credential target 'auth/$($entry.Rel)' already exists with different content; refusing to overwrite credentials. Resolve the conflict manually. No changes were made."
            }
        } else {
            [void]$ops.Add((New-MigrationOp -Op 'move-credential' -Rel $entry.Rel -From $from -To $to -Note ''))
        }
    }
    foreach ($entry in @($Classification.Entries | Where-Object { $_.Class -eq 'shared' -or $_.Class -eq 'session' })) {
        Add-MigrationSharedPlan -ProfileDir $ProfileDir -SharedRoot $SharedRoot -Rel $entry.Rel -Kind $entry.Class -PreferProfile $PreferProfile -Declarations $Declarations -Ops $ops
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
        $placeholder = Join-Path (Join-Path $ProfileDir 'auth') ($cred -replace '/', '\')
        if (Test-Path -LiteralPath $placeholder) { continue }
        [void]$ops.Add((New-MigrationOp -Op 'ensure-placeholder' -Rel $cred -From '' -To $placeholder -Note ''))
    }
    [void]$ops.Add((New-MigrationOp -Op 'write-metadata' -Rel '.profile.json' -From '' -To (Join-Path $ProfileDir '.profile.json') -Note ''))
    return , $ops
}

# =============================================================================
# Journal
# =============================================================================

# Write the journal atomically (temp + move): overall status plus every op
# with its current status, so a crash mid-migration leaves a truthful record.
function Write-MigrationJournal {
    param([string]$JournalPath, [string]$Status, $Context, $Ops)
    $payload = [ordered]@{
        tool          = $Context.Tool
        profile       = $Context.Name
        sharedRoot    = $Context.SharedRoot
        status        = $Status
        preferProfile = [bool]$Context.PreferProfile
        action        = "Re-run 'nini-agents migrate $($Context.Tool)/$($Context.Name)' to roll forward; to roll back, move each 'done' entry from 'to' back to 'from'."
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
    Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop
}

# Replace the shared-root target with the profile's entry (-PreferProfile).
function Invoke-MigrationReplace {
    param([string]$From, [string]$To)
    if (Test-Path -LiteralPath $To) { Remove-Item -LiteralPath $To -Recurse -Force -ErrorAction Stop }
    Invoke-MigrationFileMove -From $From -To $To
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

# Run every planned op in order, journaling after each. Any failure marks the
# op failed, finalizes the journal, and throws with roll-forward guidance.
function Invoke-MigrationOps {
    param($Adapter, [string]$ProfileDir, [string]$JournalPath, $Context, $Ops, $Lines)
    foreach ($op in $Ops) {
        $failed = $null
        try {
            switch ($op.Op) {
                { $_ -in 'keep-metadata', 'keep-link', 'skip-conflict', 'skip-link', 'skip-credential-lookalike' } {
                    $op.Status = 'skipped'
                }
                { $_ -in 'remove-duplicate', 'remove-duplicate-credential' } {
                    Remove-Item -LiteralPath $op.From -Force -ErrorAction Stop
                    $op.Status = 'done'
                }
                { $_ -in 'move-credential', 'merge-move' } {
                    Invoke-MigrationFileMove -From $op.From -To $op.To
                    $op.Status = 'done'
                }
                'replace-shared' {
                    Invoke-MigrationReplace -From $op.From -To $op.To
                    $op.Status = 'done'
                }
                'ensure-placeholder' {
                    Invoke-MigrationPlaceholder -To $op.To
                    $op.Status = 'done'
                }
                'write-metadata' {
                    Write-MigrationProfileMetadata -Adapter $Adapter -ProfileDir $ProfileDir
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
            $op.Status = 'failed'
            Write-MigrationJournal -JournalPath $JournalPath -Status 'failed' -Context $Context -Ops $Ops
            throw "Migration failed: $failed`nRoll-forward/rollback journal written to $JournalPath`nRe-run 'nini-agents migrate $($Context.Spec)' to roll forward."
        }
        $line = Get-MigrationOpLine -Op $op
        $Lines.Add($line) | Out-Null
        Write-Host $line
        Write-MigrationJournal -JournalPath $JournalPath -Status 'running' -Context $Context -Ops $Ops
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
        [switch]$PreferProfile
    )
    $tool = $Adapter.id
    $name = Split-Path -Leaf ($ProfileDir.TrimEnd('\', '/'))
    $spec = "$tool/$name"
    if (-not (Test-Path -LiteralPath $ProfileDir -PathType Container)) { throw "Profile '$spec' does not exist" }

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

    # Atomic moves need profile storage and the shared root on one volume.
    $profileRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($ProfileDir))
    $sharedVolume = [System.IO.Path]::GetPathRoot($sharedRoot)
    if (-not $profileRoot.Equals($sharedVolume, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Cannot migrate ${spec}: profile storage and the shared state root '$sharedRoot' are on different volumes. Migration uses atomic same-volume moves; set MULTICLI_HOME to the same volume as '$sharedRoot' and retry."
    }

    $declarations = Get-MigrationDeclarations -Adapter $Adapter
    $classification = Get-MigrationClassification -ProfileDir $ProfileDir -Declarations $declarations
    if ($classification.Unknown.Count -gt 0 -or $classification.Overlap.Count -gt 0) {
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

    [void]$lines.Add("Migrating $spec (legacy-isolated -> accountOverlay):")
    Write-Host $lines[0]
    New-Item -ItemType Directory -Force -Path $sharedRoot | Out-Null
    $journalPath = Join-Path $ProfileDir $script:MigrationJournalName
    $context = [pscustomobject]@{
        Tool          = $tool
        Name          = $name
        Spec          = $spec
        SharedRoot    = $sharedRoot
        PreferProfile = [bool]$PreferProfile
    }
    Write-MigrationJournal -JournalPath $journalPath -Status 'running' -Context $context -Ops $ops
    Invoke-MigrationOps -Adapter $Adapter -ProfileDir $ProfileDir -JournalPath $journalPath -Context $context -Ops $ops -Lines $lines
    Remove-MigrationEmptyDirs -ProfileDir $ProfileDir
    Write-MigrationJournal -JournalPath $journalPath -Status 'completed' -Context $context -Ops $ops
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
