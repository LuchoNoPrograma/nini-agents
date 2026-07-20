Set-StrictMode -Version Latest

# Allowlist-driven profile transfer (templates, export, import) for schema-v2
# profiles. Only adapter-declared normalState.sharedPaths content is copied;
# credentials, sessions, links, hardlinks, and unclassified files never travel.

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Get-Command Initialize-RuntimeProfile -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot 'MultiCli.Runtime.psm1') -Force
}

$script:TransferManifestName = '.multicli-manifest.json'
$script:TransferSecretScanMaxBytes = 1MB
$script:TransferCredentialBasenames = @(
    'auth.json', '.credentials.json', 'oauth_creds.json',
    'google_accounts.json', 'mcp-oauth-tokens.json', 'a2a-oauth-tokens.json'
)
$script:TransferSecretPattern = [regex]'sk-|access_token|refresh_token|id_token|Bearer '

function Get-TransferProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# True when a file leaf name is one of the legacy credential basenames
# blocked at any depth.
function Test-TransferCredentialBasename {
    param([string]$Name)
    return $script:TransferCredentialBasenames -contains $Name
}

# True when $RelativePath appears verbatim in the declared value list.
function Test-TransferDeclaredPath {
    param($Values, [string]$RelativePath)
    foreach ($value in @($Values)) {
        if ($value -eq $RelativePath) { return $true }
    }
    return $false
}

# Credential paths are the adapter-declared credential files, the legacy
# hardcoded credential basenames at any depth, and the profile auth boundary.
function Test-TransferCredentialPath {
    param($Adapter, [string]$RelativePath)
    $normalized = $RelativePath -replace '\\', '/'
    $account = Get-TransferProperty -Object $Adapter -Name 'account'
    $declared = Get-TransferProperty -Object $account -Name 'credentialFiles'
    if (Test-TransferDeclaredPath -Values $declared -RelativePath $normalized) { return $true }
    $leaf = ($normalized -split '/')[-1]
    if (Test-TransferCredentialBasename -Name $leaf) { return $true }
    if ($normalized -eq 'auth' -or $normalized.StartsWith('auth/')) { return $true }
    return $false
}

# True when $RelativePath is one of the adapter-declared session paths.
function Test-TransferSessionPath {
    param($Adapter, [string]$RelativePath)
    $normalized = $RelativePath -replace '\\', '/'
    $normalState = Get-TransferProperty -Object $Adapter -Name 'normalState'
    $declared = Get-TransferProperty -Object $normalState -Name 'sessionPaths'
    return (Test-TransferDeclaredPath -Values $declared -RelativePath $normalized)
}

# Expand the path tokens adapters use for per-OS roots: $HOME and %VARS%.
function Resolve-TransferPathToken {
    param([string]$Path)
    if (-not $Path) { return $Path }
    $expanded = $Path.Replace('$HOME', $env:USERPROFILE)
    return [Environment]::ExpandEnvironmentVariables($expanded)
}

# The adapter's native shared-state root for Windows, or throw.
function Get-TransferSharedRoot {
    param($Adapter)
    $normalState = Get-TransferProperty -Object $Adapter -Name 'normalState'
    $roots = Get-TransferProperty -Object $normalState -Name 'root'
    $root = Get-TransferProperty -Object $roots -Name 'windows'
    if (-not $root) { throw "Adapter '$($Adapter.id)' has no normal-state root for windows." }
    return [System.IO.Path]::GetFullPath((Resolve-TransferPathToken $root))
}

# Absolute normalized form of a path for prefix comparisons.
function Get-TransferCanonical {
    param([string]$Path)
    return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
}

# True when canonical $Child equals canonical $Root or sits underneath it.
function Test-TransferPathWithin {
    param([string]$Child, [string]$Root)
    if (-not $Root) { return $false }
    $prefix = $Root.TrimEnd('\', '/') + '\'
    return ($Child.TrimEnd('\', '/') + '\').StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

# Canonical link target for junctions/symlinks, or $null when the path is not
# a reparse point. NTFS link targets are always absolute and non-empty (the
# reparse data keeps the stale absolute path even for a broken link), so the
# target never needs resolution or empty-target handling.
function Get-TransferLinkTarget {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    $linkType = Get-TransferProperty -Object $item -Name 'LinkType'
    if ($linkType -ne 'Junction' -and $linkType -ne 'SymbolicLink') { return $null }
    return Get-TransferCanonical -Path @(Get-TransferProperty -Object $item -Name 'Target')[0]
}

# Where the profile resolves a declared shared path to: the overlay view when
# it exists, otherwise the native shared root; $null when neither exists.
function Get-TransferProfileSource {
    param([string]$ProfileDir, [string]$RelativePath, [string]$SharedRoot)
    $windowsRelative = $RelativePath -replace '/', '\'
    $candidate = Join-Path (Join-Path $ProfileDir '.runtime') $windowsRelative
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    $candidate = Join-Path $SharedRoot $windowsRelative
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

# Resolve one declared top-level path to the physical location holding its
# content. Overlay links into the shared root are the expected fileOverlay
# mechanism; a link pointing anywhere else is tampering and refuses the run.
function Resolve-TransferTopPath {
    param([string]$Path, [string]$RelativePath, [string]$SharedRoot, [string]$ProfileDir, [string]$Action)
    $target = Get-TransferLinkTarget -Path $Path
    if ($null -eq $target) { return Get-TransferCanonical -Path $Path }
    $canonicalShared = if (Test-Path -LiteralPath $SharedRoot) { Get-TransferCanonical -Path $SharedRoot } else { '' }
    $canonicalProfile = Get-TransferCanonical -Path $ProfileDir
    if (-not (Test-TransferPathWithin -Child $target -Root $canonicalShared) -and
        -not (Test-TransferPathWithin -Child $target -Root $canonicalProfile)) {
        throw "Cannot ${Action}: '$RelativePath' is a link to '$target' outside the profile's shared state. Remove the link and retry."
    }
    return $target
}

# True when a text file below the scan cap matches a secret-shaped pattern;
# oversized and binary files are never scanned (and never match).
function Test-TransferFileSecret {
    param([string]$Path)
    $info = Get-Item -LiteralPath $Path -Force
    if ($info.Length -gt $script:TransferSecretScanMaxBytes) { return $false }
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] 8192
        $read = $stream.Read($buffer, 0, $buffer.Length)
        for ($i = 0; $i -lt $read; $i++) {
            if ($buffer[$i] -eq 0) { return $false }
        }
    } finally { $stream.Dispose() }
    return $script:TransferSecretPattern.IsMatch([System.IO.File]::ReadAllText($Path))
}

# Append every regular file under a resolved declared path to the plan. Links
# are never included and never followed; one pointing outside the allowed
# roots means the tree was tampered with.
function Add-TransferPlanEntry {
    param(
        [string]$Source, [string]$RelativePath, $Adapter, [string]$Action, [bool]$IsTop,
        [string]$AllowedShared, [string]$AllowedProfile,
        [System.Collections.Generic.List[object]]$Plan
    )
    $relative = $RelativePath -replace '\\', '/'
    $linkTarget = Get-TransferLinkTarget -Path $Source
    if ($null -ne $linkTarget) {
        if ((Test-TransferPathWithin -Child $linkTarget -Root $AllowedShared) -or
            (Test-TransferPathWithin -Child $linkTarget -Root $AllowedProfile)) { return }
        throw "Cannot ${Action}: '$relative' is a link to '$linkTarget' outside the profile's shared state. Remove the link and retry."
    }
    $item = Get-Item -LiteralPath $Source -Force
    if ($item.PSIsContainer) {
        foreach ($child in (Get-ChildItem -LiteralPath $Source -Force)) {
            Add-TransferPlanEntry -Source $child.FullName -RelativePath "$relative/$($child.Name)" -Adapter $Adapter -Action $Action -IsTop $false -AllowedShared $AllowedShared -AllowedProfile $AllowedProfile -Plan $Plan
        }
        return
    }
    if (Test-TransferCredentialPath -Adapter $Adapter -RelativePath $relative) { return }
    if (Test-TransferSessionPath -Adapter $Adapter -RelativePath $relative) { return }
    # A nested hardlink can alias a credential under an innocent name; its
    # content cannot be proven shareable. Top-level declared paths are the
    # overlay mechanism itself and are copied as content.
    $linkType = Get-TransferProperty -Object $item -Name 'LinkType'
    if (-not $IsTop -and $linkType -eq 'HardLink') { return }
    if (Test-TransferFileSecret -Path $Source) {
        throw "Cannot ${Action}: '$relative' looks like it contains a secret (credential pattern match). Remove the secret from shared state and retry."
    }
    $Plan.Add([pscustomobject]@{ Relative = $relative; Source = $Source })
}

# Plan the copy of every declared shared path, skipping sessions/credentials
# and resolving each top-level entry before recursing. Returns the plan list.
function Get-TransferPlan {
    param($Adapter, [string]$ProfileDir, [string]$SharedRoot, [string]$Action)
    $plan = New-Object System.Collections.Generic.List[object]
    $allowedProfile = Get-TransferCanonical -Path $ProfileDir
    $allowedShared = if (Test-Path -LiteralPath $SharedRoot) { Get-TransferCanonical -Path $SharedRoot } else { '' }
    $normalState = Get-TransferProperty -Object $Adapter -Name 'normalState'
    foreach ($relativePath in @(Get-TransferProperty -Object $normalState -Name 'sharedPaths')) {
        if (-not $relativePath) { continue }
        if (Test-TransferSessionPath -Adapter $Adapter -RelativePath $relativePath) { continue }
        if (Test-TransferCredentialPath -Adapter $Adapter -RelativePath $relativePath) { continue }
        $source = Get-TransferProfileSource -ProfileDir $ProfileDir -RelativePath $relativePath -SharedRoot $SharedRoot
        if (-not $source) { continue }
        $resolved = Resolve-TransferTopPath -Path $source -RelativePath $relativePath -SharedRoot $SharedRoot -ProfileDir $ProfileDir -Action $Action
        Add-TransferPlanEntry -Source $resolved -RelativePath $relativePath -Adapter $Adapter -Action $Action -IsTop $true -AllowedShared $allowedShared -AllowedProfile $allowedProfile -Plan $plan
    }
    Write-Output -NoEnumerate $plan
}

# Copy the planned files into $DestinationRoot, creating parents. Only plan
# entries are copied -- never discovered files.
function Write-TransferPlan {
    param($Plan, [string]$DestinationRoot)
    foreach ($entry in $Plan) {
        $target = Join-Path $DestinationRoot ($entry.Relative -replace '/', '\')
        $parent = Split-Path -Parent $target
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Copy-Item -LiteralPath $entry.Source -Destination $target -Force
    }
}

# Write the transport manifest (adapter id, name, kind) that import and
# template-apply use to prove origin.
function Write-TransferManifest {
    param([string]$Destination, [string]$AdapterId, [string]$Name, [string]$Kind)
    $manifest = [ordered]@{
        schemaVersion = 2
        adapterId = $AdapterId
        name = $Name
        kind = $Kind
        createdUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    # UTF-8 without BOM so the bash runtime reads the manifest identically.
    $json = $manifest | ConvertTo-Json
    [System.IO.File]::WriteAllText($Destination, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# Parse a template/export transport manifest; $null when missing or invalid.
function Read-TransferManifest {
    param([string]$Directory)
    $path = Join-Path $Directory $script:TransferManifestName
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# Save a profile's shareable state as a named template. Refuses an existing
# name; -DryRun only lists the plan.
function Save-MultiCliTemplate {
    param($Adapter, [string]$ProfileDir, [string]$TemplatesRoot, [string]$Name, [switch]$DryRun)
    if (-not $Adapter.id) { throw "Adapter manifest has no id." }
    if ($Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$') {
        throw "Template name '$Name' invalid: must start with alphanumeric, contain only letters/numbers/hyphens"
    }
    if (-not (Test-Path -LiteralPath $ProfileDir -PathType Container)) {
        throw "Profile directory '$ProfileDir' does not exist."
    }
    $destination = Join-Path $TemplatesRoot $Name
    if (-not $DryRun -and (Test-Path -LiteralPath $destination)) { throw "Template '$Name' already exists" }
    $sharedRoot = Get-TransferSharedRoot -Adapter $Adapter
    $plan = Get-TransferPlan -Adapter $Adapter -ProfileDir $ProfileDir -SharedRoot $sharedRoot -Action "save template '$Name'"
    if ($DryRun) {
        Write-Output "Template '$Name' would contain:"
        foreach ($entry in $plan) { Write-Output "  $($entry.Relative)" }
        return
    }
    New-Item -ItemType Directory -Force -Path $TemplatesRoot | Out-Null
    $staging = Join-Path $TemplatesRoot ".staging.$Name.$PID"
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    Write-TransferPlan -Plan $plan -DestinationRoot $staging
    Write-TransferManifest -Destination (Join-Path $staging $script:TransferManifestName) -AdapterId $Adapter.id -Name $Name -Kind 'template'
    Move-Item -LiteralPath $staging -Destination $destination
}

# Throw unless the template was saved from the same adapter it is applied to.
function Assert-TransferTemplateCompatible {
    param([string]$TemplateDir, $Adapter)
    $templateName = Split-Path -Leaf $TemplateDir
    $manifest = Read-TransferManifest -Directory $TemplateDir
    if ($null -eq $manifest -or -not (Get-TransferProperty -Object $manifest -Name 'adapterId')) {
        throw "Template '$templateName' has no manifest; it was not saved by this version of multi-cli."
    }
    if ($manifest.adapterId -ne $Adapter.id) {
        throw "Template '$templateName' was saved from adapter '$($manifest.adapterId)' and cannot be applied to '$($Adapter.id)'. Save a new template from a '$($Adapter.id)' profile."
    }
}

# Write a .zip of the profile's shareable state plus transport metadata.
# The staging dir is removed on every path, success or failure.
function Export-MultiCliProfile {
    param($Adapter, [string]$ProfileDir, [string]$OutPath, [string]$ProfileName)
    if (-not $Adapter.id) { throw "Adapter manifest has no id." }
    if (-not (Test-Path -LiteralPath $ProfileDir -PathType Container)) {
        throw "Profile directory '$ProfileDir' does not exist."
    }
    $sharedRoot = Get-TransferSharedRoot -Adapter $Adapter
    $plan = Get-TransferPlan -Adapter $Adapter -ProfileDir $ProfileDir -SharedRoot $sharedRoot -Action "export profile '$ProfileName'"
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("multicli-export-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        Write-TransferPlan -Plan $plan -DestinationRoot $staging
        # .profile.json is metadata only (schemaVersion/adapterId/profileId/
        # mode) and holds no secrets; import always regenerates the profileId.
        $metadata = Join-Path $ProfileDir '.profile.json'
        if (Test-Path -LiteralPath $metadata) {
            Copy-Item -LiteralPath $metadata -Destination (Join-Path $staging '.profile.json')
        }
        Write-TransferManifest -Destination (Join-Path $staging $script:TransferManifestName) -AdapterId $Adapter.id -Name $ProfileName -Kind 'export'
        $parent = Split-Path -Parent $OutPath
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $OutPath)
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# One archive entry name with separators normalized and ./ and trailing /
# stripped, so the safety checks see the canonical relative form.
function ConvertTo-TransferEntryName {
    param([string]$Name)
    $normalized = $Name -replace '\\', '/'
    while ($normalized.StartsWith('./')) { $normalized = $normalized.Substring(2) }
    return $normalized.TrimEnd('/')
}

# Reject one archive entry name that is absolute, drive-qualified, carries an
# alternate data stream, escapes via '..', is a credential, or is runtime
# state. Empty/root entries are allowed.
function Assert-TransferEntrySafe {
    param([string]$Name, $Adapter)
    if (-not $Name -or $Name -eq '.') { return }
    if ($Name.StartsWith('/')) {
        throw "Refusing to import: archive entry '$Name' is an absolute path."
    }
    if ($Name -match '^[a-zA-Z]:') {
        throw "Refusing to import: archive entry '$Name' is a drive-qualified path."
    }
    if ($Name.Contains(':')) {
        throw "Refusing to import: archive entry '$Name' contains an alternate data stream."
    }
    if (("/$Name/") -match '/\.\./') {
        throw "Refusing to import: archive entry '$Name' escapes the profile directory."
    }
    if (Test-TransferCredentialPath -Adapter $Adapter -RelativePath $Name) {
        throw "Refusing to import: archive entry '$Name' is a credential path."
    }
    if ($Name -eq '.runtime' -or $Name.StartsWith('.runtime/')) {
        throw "Refusing to import: archive entry '$Name' is disposable runtime state."
    }
}

# Links and device files in archives carry their unix file type in the high
# word of ExternalAttributes; only regular files and directories may import.
function Assert-TransferEntryTypeSafe {
    param($Entry)
    $mode = ($Entry.ExternalAttributes -shr 16) -band 0xFFFF
    if ($mode -eq 0) { return }
    $fileType = $mode -band 0xF000
    if ($fileType -eq 0x8000 -or $fileType -eq 0x4000) { return }
    throw "Refusing to import: archive entry '$($Entry.FullName)' is not a regular file or directory."
}

# Extract every archive entry as a plain file or directory via streams --
# links and device files can never materialize from a zip this way.
function Expand-TransferArchive {
    param([string]$ArchivePath, [string]$Staging)
    $stream = [System.IO.File]::OpenRead($ArchivePath)
    $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        foreach ($entry in $archive.Entries) {
            $name = ConvertTo-TransferEntryName -Name $entry.FullName
            if (-not $name -or $name -eq '.') { continue }
            $target = Join-Path $Staging ($name -replace '/', '\')
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                continue
            }
            $parent = Split-Path -Parent $target
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            $entryStream = $entry.Open()
            try {
                $fileStream = [System.IO.File]::Create($target)
                try { $entryStream.CopyTo($fileStream) } finally { $fileStream.Dispose() }
            } finally { $entryStream.Dispose() }
        }
    } finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}

# Import an export archive into a fresh profile dir: entries are inspected
# before extraction, staging is re-scanned after extraction, the archived
# adapter must match, and the profile gets a fresh identity and empty
# credential placeholders. Throws without creating $DestinationDir on any
# refusal.
function Import-MultiCliProfile {
    param($Adapter, [string]$ArchivePath, [string]$DestinationDir)
    if (-not $Adapter.id) { throw "Adapter manifest has no id." }
    if (-not (Test-Path -LiteralPath $ArchivePath)) { throw "File not found: $ArchivePath" }
    if (Test-Path -LiteralPath $DestinationDir) { throw "Profile destination '$DestinationDir' already exists" }

    # Inspect every entry before anything is extracted: names must be
    # relative, unique, and free of credentials; types must be file or dir.
    $stream = [System.IO.File]::OpenRead($ArchivePath)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read)
        $seen = @{}
        foreach ($entry in $archive.Entries) {
            Assert-TransferEntryTypeSafe -Entry $entry
            $name = ConvertTo-TransferEntryName -Name $entry.FullName
            Assert-TransferEntrySafe -Name $name -Adapter $Adapter
            if (-not $name -or $name -eq '.') { continue }
            $key = $name.ToLowerInvariant()
            if ($seen.ContainsKey($key)) {
                throw "Refusing to import: archive contains duplicate entry '$name'."
            }
            $seen[$key] = $true
        }
        $archive.Dispose()
    } finally {
        $stream.Dispose()
    }

    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("multicli-import-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        Expand-TransferArchive -ArchivePath $ArchivePath -Staging $staging
        $manifest = Read-TransferManifest -Directory $staging
        if ($null -eq $manifest) {
            throw "Refusing to import: archive has no multi-cli manifest; only archives written by multi-cli export are accepted."
        }
        $archivedAdapter = Get-TransferProperty -Object $manifest -Name 'adapterId'
        if (-not $archivedAdapter) {
            throw "Refusing to import: archive manifest is invalid."
        }
        if ($archivedAdapter -ne $Adapter.id) {
            throw "Refusing to import: archive was exported from adapter '$archivedAdapter' and cannot be imported as '$($Adapter.id)'."
        }
        foreach ($file in (Get-ChildItem -LiteralPath $staging -Recurse -Force -File)) {
            $relative = ($file.FullName.Substring($staging.Length).TrimStart('\') -replace '\\', '/')
            if (Test-TransferFileSecret -Path $file.FullName) {
                throw "Refusing to import: '$relative' looks like it contains a secret (credential pattern match)."
            }
        }
        # The manifest is transport metadata, not profile content.
        Remove-Item -LiteralPath (Join-Path $staging $script:TransferManifestName) -Force
        New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
        foreach ($item in (Get-ChildItem -LiteralPath $staging -Force)) {
            Move-Item -LiteralPath $item.FullName -Destination $DestinationDir
        }
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Fresh stable identity and empty credential placeholders: the imported
    # profile must authenticate again.
    Initialize-RuntimeProfile -Adapter $Adapter -ProfileDir $DestinationDir
}

Export-ModuleMember -Function Save-MultiCliTemplate, Export-MultiCliProfile, Import-MultiCliProfile, Assert-TransferTemplateCompatible
