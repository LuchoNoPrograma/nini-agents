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
    $sharedCredentialState = Get-TransferProperty -Object $Adapter -Name 'sharedCredentialState'
    $backupPattern = Get-TransferProperty -Object $sharedCredentialState -Name 'legacyBackupPattern'
    foreach ($entry in @(Get-TransferProperty -Object $sharedCredentialState -Name 'entries')) {
        $declaredSharedCredential = [string](Get-TransferProperty -Object $entry -Name 'path')
        if (-not $declaredSharedCredential) { continue }
        $declaredSharedCredential = $declaredSharedCredential -replace '\\', '/'
        if ($normalized -eq $declaredSharedCredential -or $normalized.StartsWith("$declaredSharedCredential/", [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if ($backupPattern -eq 'dotSuffix' -and
            $normalized.StartsWith("$declaredSharedCredential.", [StringComparison]::OrdinalIgnoreCase) -and
            $normalized.Length -gt ($declaredSharedCredential.Length + 1)) {
            return $true
        }
    }
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

# Read the profile mode from schema-v2 metadata. Missing or malformed metadata
# is treated as the ordinary account-overlay mode for backward compatibility.
function Get-TransferProfileMode {
    param([string]$ProfileDir)
    $metadataPath = Join-Path $ProfileDir '.profile.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return 'accountOverlay' }
    try {
        $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
        if ($metadata.mode -eq 'isolated') { return 'isolated' }
    } catch { }
    return 'accountOverlay'
}

# Where the profile resolves a declared shared path to. Isolated profiles read
# their own root; ordinary profiles read the runtime view or native shared root.
function Get-TransferProfileSource {
    param($Adapter, [string]$ProfileDir, [string]$RelativePath, [string]$SharedRoot)
    $windowsRelative = $RelativePath -replace '/', '\'
    if ((Get-TransferProfileMode -ProfileDir $ProfileDir) -eq 'isolated') {
        $normalState = Get-TransferProperty -Object $Adapter -Name 'normalState'
        $runtimeSubdir = Get-TransferProperty -Object $normalState -Name 'runtimeSubdir'
        $stateRoot = if ($runtimeSubdir) { Join-Path $ProfileDir ($runtimeSubdir -replace '/', '\') } else { $ProfileDir }
        $candidate = Join-Path $stateRoot $windowsRelative
        if (Test-Path -LiteralPath $candidate) { return $candidate }
        return $null
    }
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

# Return why a file cannot cross the transfer boundary, or $null when its full
# text content is small enough to scan and contains no secret-shaped pattern.
function Get-TransferFileRefusal {
    param([string]$Path)
    $info = Get-Item -LiteralPath $Path -Force
    if ($info.Length -gt $script:TransferSecretScanMaxBytes) {
        return "is larger than the $($script:TransferSecretScanMaxBytes)-byte secret-scan limit"
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes -contains 0) { return 'is binary and cannot be secret-scanned safely' }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $utf8.GetString($bytes)
    } catch [System.Text.DecoderFallbackException] {
        return 'is binary and cannot be secret-scanned safely'
    }
    if ($script:TransferSecretPattern.IsMatch($text)) { return 'looks like it contains a secret (credential pattern match)' }
    return $null
}

function Test-TransferFileSecret {
    param([string]$Path)
    return $null -ne (Get-TransferFileRefusal -Path $Path)
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
    $refusal = Get-TransferFileRefusal -Path $Source
    if ($refusal) {
        throw "Cannot ${Action}: '$relative' $refusal. Remove it from shared state or replace it with inspectable non-secret text, then retry."
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
        $source = Get-TransferProfileSource -Adapter $Adapter -ProfileDir $ProfileDir -RelativePath $relativePath -SharedRoot $SharedRoot
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

function Get-TransferIsolatedStateRoot {
    param($Adapter, [string]$ProfileDir)
    $normalState = Get-TransferProperty -Object $Adapter -Name 'normalState'
    $runtimeSubdir = Get-TransferProperty -Object $normalState -Name 'runtimeSubdir'
    if ($runtimeSubdir) { return Join-Path $ProfileDir ($runtimeSubdir -replace '/', '\') }
    return $ProfileDir
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

# Return every regular template file except its transport manifest, refusing
# links, credential/session/runtime paths, undeclared top-level paths, and any
# content that cannot pass the secret scanner.
function Get-TransferTemplatePlan {
    param([string]$TemplateDir, $Adapter)
    $plan = New-Object System.Collections.Generic.List[object]
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((Get-Item -LiteralPath $TemplateDir -Force))
    while ($stack.Count -gt 0) {
        foreach ($item in (Get-ChildItem -LiteralPath $stack.Pop().FullName -Force)) {
            $relative = $item.FullName.Substring($TemplateDir.Length).TrimStart('\', '/').Replace('\', '/')
            if ($relative -eq $script:TransferManifestName) { continue }
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Template '$(Split-Path -Leaf $TemplateDir)' contains link '$relative'; templates may contain only regular files and directories."
            }
            if ((Test-TransferCredentialPath -Adapter $Adapter -RelativePath $relative) -or
                (Test-TransferSessionPath -Adapter $Adapter -RelativePath $relative) -or
                $relative -eq '.runtime' -or $relative.StartsWith('.runtime/')) {
                throw "Template '$(Split-Path -Leaf $TemplateDir)' contains forbidden path '$relative'."
            }
            if (-not (Test-TransferPayloadPath -Adapter $Adapter -RelativePath $relative)) {
                throw "Template '$(Split-Path -Leaf $TemplateDir)' contains undeclared path '$relative'."
            }
            if ($item.PSIsContainer) { $stack.Push($item); continue }
            $refusal = Get-TransferFileRefusal -Path $item.FullName
            if ($refusal) { throw "Template '$(Split-Path -Leaf $TemplateDir)' file '$relative' $refusal." }
            $plan.Add([pscustomobject]@{ Relative = $relative; Source = $item.FullName })
        }
    }
    Write-Output -NoEnumerate $plan
}

# Throw unless a template belongs to this adapter and every payload entry is
# safe. Returns the validated copy plan so callers never recurse blindly.
function Assert-TransferTemplateCompatible {
    param([string]$TemplateDir, $Adapter)
    $templateName = Split-Path -Leaf $TemplateDir
    $manifest = Read-TransferManifest -Directory $TemplateDir
    if ($null -eq $manifest -or -not (Get-TransferProperty -Object $manifest -Name 'adapterId')) {
        throw "Template '$templateName' has no manifest; it was not saved by this version of nini-agents."
    }
    if ($manifest.adapterId -ne $Adapter.id) {
        throw "Template '$templateName' was saved from adapter '$($manifest.adapterId)' and cannot be applied to '$($Adapter.id)'. Save a new template from a '$($Adapter.id)' profile."
    }
    return Get-TransferTemplatePlan -TemplateDir $TemplateDir -Adapter $Adapter
}

# Apply an already validated template to the actual state location used by the
# selected mode: profile root for isolated, native shared root otherwise.
function Apply-MultiCliTemplate {
    param([string]$TemplateDir, $Adapter, [string]$ProfileDir, [switch]$Isolated)
    $plan = Assert-TransferTemplateCompatible -TemplateDir $TemplateDir -Adapter $Adapter
    $destination = if ($Isolated) { Get-TransferIsolatedStateRoot -Adapter $Adapter -ProfileDir $ProfileDir } else { Get-TransferSharedRoot -Adapter $Adapter }
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Write-TransferPlan -Plan $plan -DestinationRoot $destination
}

# Replace only adapter-declared shared payload in the native shared root. The
# staged import stays intact until all replacements succeed.
function Install-TransferSharedState {
    param($Adapter, [string]$Staging)
    $sharedRoot = Get-TransferSharedRoot -Adapter $Adapter
    New-Item -ItemType Directory -Force -Path $sharedRoot | Out-Null
    $normalState = Get-TransferProperty -Object $Adapter -Name 'normalState'
    foreach ($relativePath in @(Get-TransferProperty -Object $normalState -Name 'sharedPaths')) {
        if (-not $relativePath) { continue }
        $source = Join-Path $Staging ($relativePath -replace '/', '\')
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $destination = Join-Path $sharedRoot ($relativePath -replace '/', '\')
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
        $parent = Split-Path -Parent $destination
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Move-Item -LiteralPath $source -Destination $destination
    }
}

# Write fresh metadata without creating account-overlay credential placeholders.
function Write-ImportedIsolatedMetadata {
    param($Adapter, [string]$DestinationDir)
    $metadata = [ordered]@{
        schemaVersion = 2
        adapterId = $Adapter.id
        profileId = [guid]::NewGuid().ToString()
        mode = 'isolated'
    }
    $metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $DestinationDir '.profile.json') -Encoding UTF8
    New-Item -ItemType File -Force -Path (Join-Path $DestinationDir '.isolated') | Out-Null
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

# True when an archive/template payload path is declared shared state, a child
# of declared state, or a parent directory needed to contain a declared path.
function Test-TransferPayloadPath {
    param($Adapter, [string]$RelativePath)
    $normalState = Get-TransferProperty -Object $Adapter -Name 'normalState'
    foreach ($declared in @(Get-TransferProperty -Object $normalState -Name 'sharedPaths')) {
        if (-not $declared) { continue }
        if ($RelativePath -eq $declared -or $RelativePath.StartsWith("$declared/") -or $declared.StartsWith("$RelativePath/")) {
            return $true
        }
    }
    return $false
}

# Reject one archive entry name that is unsafe or outside the adapter-declared
# shared-state allowlist. Empty/root and transport metadata entries are allowed.
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
    if ($Name -eq $script:TransferManifestName -or $Name -eq '.profile.json') { return }
    if (-not (Test-TransferPayloadPath -Adapter $Adapter -RelativePath $Name)) {
        throw "Refusing to import: archive entry '$Name' is not adapter-declared shared state."
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
            throw "Refusing to import: archive has no nini-agents manifest; only archives written by nini-agents export are accepted."
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
            $refusal = Get-TransferFileRefusal -Path $file.FullName
            if ($refusal) { throw "Refusing to import: '$relative' $refusal." }
        }
        $archivedMode = 'accountOverlay'
        $archivedMetadata = Join-Path $staging '.profile.json'
        if (Test-Path -LiteralPath $archivedMetadata -PathType Leaf) {
            try {
                $mode = (Get-Content -LiteralPath $archivedMetadata -Raw | ConvertFrom-Json).mode
                if ($mode -eq 'isolated') { $archivedMode = 'isolated' }
            } catch { throw 'Refusing to import: archived profile metadata is invalid.' }
            Remove-Item -LiteralPath $archivedMetadata -Force
        }
        Remove-Item -LiteralPath (Join-Path $staging $script:TransferManifestName) -Force
        New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
        if ($archivedMode -eq 'isolated') {
            foreach ($item in (Get-ChildItem -LiteralPath $staging -Force)) {
                Move-Item -LiteralPath $item.FullName -Destination $DestinationDir
            }
            Write-ImportedIsolatedMetadata -Adapter $Adapter -DestinationDir $DestinationDir
        } else {
            Install-TransferSharedState -Adapter $Adapter -Staging $staging
            Initialize-RuntimeProfile -Adapter $Adapter -ProfileDir $DestinationDir
        }
    } catch {
        Remove-Item -LiteralPath $DestinationDir -Recurse -Force -ErrorAction SilentlyContinue
        throw
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# Credential-bearing transactional movement
# =============================================================================
# This API is intentionally separate from credential-free template/export/
# import. The caller supplies a transport and a process probe; this module
# exclusively owns staging, integrity, activation, backup and rollback.

function New-MoveResult {
    param([bool]$Succeeded, [string]$Code, [string]$State, [string]$Format = 'unknown')
    return [pscustomobject]@{
        Succeeded = $Succeeded
        Code = $Code
        State = $State
        Format = $Format
    }
}

function Test-MoveSafeComponent {
    param([string]$Value)
    return $Value -match '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

function Test-MoveRelativeDeclaration {
    param($Values, [string]$RelativePath)
    foreach ($declared in @($Values)) {
        if (-not $declared) { continue }
        if ($RelativePath -eq $declared -or $RelativePath.StartsWith("$declared/") -or $declared.StartsWith("$RelativePath/")) {
            return $true
        }
    }
    return $false
}

function Test-MoveRelativeAllowed {
    param($Adapter, [string]$RelativePath, [string]$Format, [string]$Mode)
    if ($RelativePath.Contains(':') -or $RelativePath.Contains('\') -or $RelativePath.Contains("`n") -or $RelativePath.Contains("`r")) {
        return $false
    }
    $account = Get-TransferProperty -Object $Adapter -Name 'account'
    $normalState = Get-TransferProperty -Object $Adapter -Name 'normalState'
    if ($Format -eq 'v2') {
        if ($RelativePath -eq '.profile.json' -or $RelativePath -eq '.cli') { return $true }
        if ($RelativePath -eq 'auth') { return $true }
        if ($RelativePath.StartsWith('auth/')) {
            return Test-MoveRelativeDeclaration -Values (Get-TransferProperty -Object $account -Name 'credentialFiles') -RelativePath $RelativePath.Substring(5)
        }
        if ($RelativePath -eq '.runtime' -or $RelativePath.StartsWith('.runtime/')) { return $true }
        if ($Mode -ne 'isolated') { return $false }
        if ($RelativePath -eq '.isolated') { return $true }
        $runtimeSubdir = Get-TransferProperty -Object $normalState -Name 'runtimeSubdir'
        $declaredPath = $RelativePath
        if ($runtimeSubdir) {
            $prefix = $runtimeSubdir.Replace('\', '/').TrimEnd('/')
            if ($declaredPath -eq $prefix) { return $true }
            if (-not $declaredPath.StartsWith("$prefix/", [StringComparison]::OrdinalIgnoreCase)) { return $false }
            $declaredPath = $declaredPath.Substring($prefix.Length + 1)
        }
        if (Test-MoveRelativeDeclaration -Values (Get-TransferProperty -Object $normalState -Name 'sharedPaths') -RelativePath $declaredPath) { return $true }
        if (Test-MoveRelativeDeclaration -Values (Get-TransferProperty -Object $normalState -Name 'sessionPaths') -RelativePath $declaredPath) { return $true }
        return Test-MoveRelativeDeclaration -Values (Get-TransferProperty -Object $normalState -Name 'unsafePaths') -RelativePath $declaredPath
    }

    if ($RelativePath -eq '.cli') { return $true }
    if (Test-MoveRelativeDeclaration -Values (Get-TransferProperty -Object $account -Name 'credentialFiles') -RelativePath $RelativePath) { return $true }
    if (Test-MoveRelativeDeclaration -Values (Get-TransferProperty -Object $normalState -Name 'sharedPaths') -RelativePath $RelativePath) { return $true }
    if (Test-MoveRelativeDeclaration -Values (Get-TransferProperty -Object $normalState -Name 'sessionPaths') -RelativePath $RelativePath) { return $true }
    return Test-MoveRelativeDeclaration -Values (Get-TransferProperty -Object $normalState -Name 'unsafePaths') -RelativePath $RelativePath
}

function Test-MoveJsonObject {
    param([string]$Path)
    try {
        $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        return $parsed -is [pscustomobject]
    } catch {
        return $false
    }
}

function Test-MoveExpectedRuntimeHardLink {
    param($Adapter, [string]$ProfilePath, [string]$RelativePath, $Item, [string]$Mode)
    if ($Mode -ne 'accountOverlay' -or -not $RelativePath.StartsWith('auth/')) { return $false }
    $credentialRelative = $RelativePath.Substring(5)
    $account = Get-TransferProperty -Object $Adapter -Name 'account'
    if (-not (Test-MoveRelativeDeclaration -Values (Get-TransferProperty -Object $account -Name 'credentialFiles') -RelativePath $credentialRelative)) {
        return $false
    }
    $normalState = Get-TransferProperty -Object $Adapter -Name 'normalState'
    $runtimeSubdir = Get-TransferProperty -Object $normalState -Name 'runtimeSubdir'
    $runtimeRoot = Join-Path $ProfilePath '.runtime'
    if ($runtimeSubdir) { $runtimeRoot = Join-Path $runtimeRoot ($runtimeSubdir -replace '/', '\') }
    $expectedRuntime = [System.IO.Path]::GetFullPath((Join-Path $runtimeRoot ($credentialRelative -replace '/', '\')))
    $targets = @(@(Get-TransferProperty -Object $Item -Name 'Target') | Where-Object { $_ })
    if ($targets.Count -ne 1) { return $false }
    return [System.IO.Path]::GetFullPath([string]$targets[0]) -eq $expectedRuntime
}

# Return structural validation without ever returning credential or metadata
# values. Schema-v2 runtime contents are derived and excluded from transport.
function Test-MoveProfile {
    param($Adapter, [string]$ProfilePath)
    $format = 'unknown'
    $mode = 'unknown'
    if (-not (Test-Path -LiteralPath $ProfilePath -PathType Container)) {
        return [pscustomobject]@{ Valid = $false; Code = 'source_missing'; Format = $format; Mode = $mode }
    }
    $profileItem = Get-Item -LiteralPath $ProfilePath -Force
    if ($profileItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        return [pscustomobject]@{ Valid = $false; Code = 'unsafe_link'; Format = $format; Mode = $mode }
    }
    $account = Get-TransferProperty -Object $Adapter -Name 'account'
    if (-not $Adapter.id -or (Get-TransferProperty -Object $account -Name 'mechanism') -ne 'fileOverlay') {
        return [pscustomobject]@{ Valid = $false; Code = 'unsupported_mechanism'; Format = $format; Mode = $mode }
    }

    $metadataPath = Join-Path $ProfilePath '.profile.json'
    if (Test-Path -LiteralPath $metadataPath) {
        $format = 'v2'
        $metadataItem = Get-Item -LiteralPath $metadataPath -Force
        if ($metadataItem.PSIsContainer -or ($metadataItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            return [pscustomobject]@{ Valid = $false; Code = 'invalid_metadata'; Format = $format; Mode = $mode }
        }
        try { $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json }
        catch { return [pscustomobject]@{ Valid = $false; Code = 'invalid_metadata'; Format = $format; Mode = $mode } }
        $schemaVersion = Get-TransferProperty -Object $metadata -Name 'schemaVersion'
        $adapterId = Get-TransferProperty -Object $metadata -Name 'adapterId'
        $profileId = Get-TransferProperty -Object $metadata -Name 'profileId'
        $mode = Get-TransferProperty -Object $metadata -Name 'mode'
        if ($schemaVersion -ne 2 -or $adapterId -ne $Adapter.id -or -not ($profileId -is [string]) -or -not $profileId -or $mode -notin @('accountOverlay', 'isolated')) {
            return [pscustomobject]@{ Valid = $false; Code = 'invalid_metadata'; Format = $format; Mode = $mode }
        }
        foreach ($relativePath in @(Get-TransferProperty -Object $account -Name 'credentialFiles')) {
            if (-not $relativePath) { continue }
            $credentialPath = Join-Path (Join-Path $ProfilePath 'auth') ($relativePath -replace '/', '\')
            if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
                return [pscustomobject]@{ Valid = $false; Code = 'missing_credential'; Format = $format; Mode = $mode }
            }
            $credentialItem = Get-Item -LiteralPath $credentialPath -Force
            if ($credentialItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                return [pscustomobject]@{ Valid = $false; Code = 'unsafe_link'; Format = $format; Mode = $mode }
            }
            if ((Split-Path -Leaf $relativePath) -eq 'auth.json' -and -not (Test-MoveJsonObject -Path $credentialPath)) {
                return [pscustomobject]@{ Valid = $false; Code = 'invalid_auth_json'; Format = $format; Mode = $mode }
            }
        }
    } else {
        $format = 'legacy'
        $mode = 'legacy'
        $credentialPath = Join-Path $ProfilePath 'auth.json'
        if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
            return [pscustomobject]@{ Valid = $false; Code = 'missing_credential'; Format = $format; Mode = $mode }
        }
        $credentialItem = Get-Item -LiteralPath $credentialPath -Force
        if (($credentialItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or -not (Test-MoveJsonObject -Path $credentialPath)) {
            $code = if ($credentialItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { 'unsafe_link' } else { 'invalid_auth_json' }
            return [pscustomobject]@{ Valid = $false; Code = $code; Format = $format; Mode = $mode }
        }
    }

    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((Get-Item -LiteralPath $ProfilePath -Force))
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        foreach ($item in (Get-ChildItem -LiteralPath $directory.FullName -Force)) {
            $relative = $item.FullName.Substring($ProfilePath.Length).TrimStart('\', '/').Replace('\', '/')
            if ($format -eq 'v2' -and $relative -eq '.runtime') {
                if (-not $item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    return [pscustomobject]@{ Valid = $false; Code = 'unsafe_link'; Format = $format; Mode = $mode }
                }
                continue
            }
            if (-not (Test-MoveRelativeAllowed -Adapter $Adapter -RelativePath $relative -Format $format -Mode $mode)) {
                return [pscustomobject]@{ Valid = $false; Code = 'unknown_content'; Format = $format; Mode = $mode }
            }
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                return [pscustomobject]@{ Valid = $false; Code = 'unsafe_link'; Format = $format; Mode = $mode }
            }
            $linkType = Get-TransferProperty -Object $item -Name 'LinkType'
            if (-not $item.PSIsContainer -and $linkType -eq 'HardLink' -and
                -not (Test-MoveExpectedRuntimeHardLink -Adapter $Adapter -ProfilePath $ProfilePath -RelativePath $relative -Item $item -Mode $mode)) {
                return [pscustomobject]@{ Valid = $false; Code = 'unsafe_hardlink'; Format = $format; Mode = $mode }
            }
            if ($item.PSIsContainer) { $stack.Push($item) }
        }
    }
    return [pscustomobject]@{ Valid = $true; Code = 'ok'; Format = $format; Mode = $mode }
}

function Get-MoveFileHash {
    param([string]$Path)
    $stream = [System.IO.File]::OpenRead($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Get-MoveInventory {
    param([string]$Root)
    $entries = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push((Get-Item -LiteralPath $Root -Force))
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        foreach ($item in (Get-ChildItem -LiteralPath $directory.FullName -Force)) {
            $relative = $item.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
            if ($relative -eq '.runtime') { continue }
            if ($item.PSIsContainer) {
                $entries.Add("d`t$relative")
                $stack.Push($item)
            } else {
                $entries.Add("f`t$relative`t$($item.Length)`t$(Get-MoveFileHash -Path $item.FullName)")
            }
        }
    }
    return @($entries | Sort-Object)
}

function Test-MoveTreesEqual {
    param([string]$Left, [string]$Right)
    try {
        $leftInventory = @(Get-MoveInventory -Root $Left)
        $rightInventory = @(Get-MoveInventory -Root $Right)
        return ($leftInventory -join "`n") -ceq ($rightInventory -join "`n")
    } catch {
        return $false
    }
}

function Copy-MoveCandidateLocal {
    param([string]$Source, [string]$Staging)
    foreach ($item in (Get-ChildItem -LiteralPath $Source -Force)) {
        if ($item.Name -eq '.runtime') { continue }
        $destination = Join-Path $Staging $item.Name
        if ($item.PSIsContainer) {
            New-Item -ItemType Directory -Force -Path $destination | Out-Null
            Copy-MoveTree -Source $item.FullName -Destination $destination
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $destination -Force
        }
    }
}

function Copy-MoveTree {
    param([string]$Source, [string]$Destination)
    foreach ($item in (Get-ChildItem -LiteralPath $Source -Force)) {
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Copy-MoveTree -Source $item.FullName -Destination $target
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

function Invoke-MoveProbe {
    param([scriptblock]$Probe, [string]$Path)
    try {
        $result = & $Probe $Path
        if ($result -isnot [bool]) { return [pscustomobject]@{ Valid = $false; Busy = $false } }
        return [pscustomobject]@{ Valid = $true; Busy = $result }
    } catch {
        return [pscustomobject]@{ Valid = $false; Busy = $false }
    }
}

function Invoke-MoveActivation {
    param([string]$Staging, [string]$Destination, [scriptblock]$Activation)
    try {
        if ($Activation) { & $Activation $Staging $Destination | Out-Null }
        else { Move-Item -LiteralPath $Staging -Destination $Destination -ErrorAction Stop }
        return $true
    } catch { return $false }
}

function Invoke-MoveDeactivation {
    param([string]$Source, [string]$Backup, [scriptblock]$Deactivation)
    try {
        if ($Deactivation) { & $Deactivation $Source $Backup | Out-Null }
        else { Move-Item -LiteralPath $Source -Destination $Backup -ErrorAction Stop }
        return (-not (Test-Path -LiteralPath $Source)) -and (Test-Path -LiteralPath $Backup)
    } catch { return $false }
}

function Invoke-MoveQuarantine {
    param([string]$Destination, [string]$Failed, [scriptblock]$Quarantine)
    try {
        if (Test-Path -LiteralPath $Failed) { return $false }
        $parent = Split-Path -Parent $Failed
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        if ($Quarantine) { & $Quarantine $Destination $Failed | Out-Null }
        else { Move-Item -LiteralPath $Destination -Destination $Failed -ErrorAction Stop }
        return -not (Test-Path -LiteralPath $Destination)
    } catch { return $false }
}

function Restore-MoveSource {
    param(
        [string]$Source, [string]$Backup, [string]$Destination, [string]$Failed,
        [string]$Code, [string]$Format, [scriptblock]$Quarantine
    )
    if (Test-Path -LiteralPath $Destination) {
        if (-not (Invoke-MoveQuarantine -Destination $Destination -Failed $Failed -Quarantine $Quarantine)) {
            return New-MoveResult -Succeeded $false -Code 'rollback_failed' -State 'ownership_indeterminate' -Format $Format
        }
    }
    try {
        Move-Item -LiteralPath $Backup -Destination $Source -ErrorAction Stop
        return New-MoveResult -Succeeded $false -Code $Code -State 'source_restored' -Format $Format
    } catch {
        return New-MoveResult -Succeeded $false -Code 'rollback_failed' -State 'ownership_indeterminate' -Format $Format
    }
}

function New-MoveRuntimeOverlay {
    param($Adapter, [string]$ProfilePath)
    try {
        $runtimeModule = Get-Module MultiCli.Runtime
        if (-not $runtimeModule) { return $false }
        $runtimeRoot = & $runtimeModule { param($a, $p) New-RuntimeOverlay -Adapter $a -ProfileDir $p } $Adapter $ProfilePath
        return [bool](& $runtimeModule { param($a, $r) Test-RuntimeOverlayCurrent -Adapter $a -RuntimeRoot $r } $Adapter $runtimeRoot)
    } catch { return $false }
}

function Remove-MoveTransactionLock {
    param([string]$Path)
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Invoke-MultiCliProfileMove {
    param(
        $Adapter,
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string]$ProfileName,
        [string]$OperationId,
        [scriptblock]$ProcessProbe,
        [scriptblock]$TransportCopy,
        [scriptblock]$Deactivation,
        [scriptblock]$Activation,
        [scriptblock]$Quarantine,
        [scriptblock]$RuntimeBuilder,
        [switch]$DryRun
    )
    $format = 'unknown'
    if (-not (Test-MoveSafeComponent -Value $ProfileName) -or -not (Test-MoveSafeComponent -Value $OperationId)) {
        return New-MoveResult -Succeeded $false -Code 'invalid_identifier' -State 'preflight_rejected'
    }
    if (-not $ProcessProbe -or -not $TransportCopy) {
        return New-MoveResult -Succeeded $false -Code 'invalid_callback' -State 'preflight_rejected'
    }
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container) -or -not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) {
        return New-MoveResult -Succeeded $false -Code 'unsafe_root' -State 'preflight_rejected'
    }
    $sourceRootItem = Get-Item -LiteralPath $SourceRoot -Force
    $destinationRootItem = Get-Item -LiteralPath $DestinationRoot -Force
    if (($sourceRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
        ($destinationRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or
        ([System.IO.Path]::GetFullPath($SourceRoot).TrimEnd('\') -eq [System.IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\'))) {
        return New-MoveResult -Succeeded $false -Code 'unsafe_root' -State 'preflight_rejected'
    }

    $source = Join-Path $SourceRoot $ProfileName
    $destination = Join-Path $DestinationRoot $ProfileName
    $staging = Join-Path (Join-Path $DestinationRoot '.staging') "$ProfileName.$OperationId"
    $backup = Join-Path (Join-Path $SourceRoot '.inactive') "$ProfileName.$OperationId"
    $failed = Join-Path (Join-Path $DestinationRoot '.failed') "$ProfileName.$OperationId"
    $lock = Join-Path $SourceRoot ".move-lock.$ProfileName"
    foreach ($transactionParent in @((Split-Path -Parent $staging), (Split-Path -Parent $backup), (Split-Path -Parent $failed))) {
        if (-not (Test-Path -LiteralPath $transactionParent)) { continue }
        $parentItem = Get-Item -LiteralPath $transactionParent -Force
        if (-not $parentItem.PSIsContainer -or ($parentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            return New-MoveResult -Succeeded $false -Code 'unsafe_root' -State 'preflight_rejected'
        }
    }
    if (Test-Path -LiteralPath $destination) {
        return New-MoveResult -Succeeded $false -Code 'destination_active' -State 'preflight_rejected'
    }
    $validation = Test-MoveProfile -Adapter $Adapter -ProfilePath $source
    $format = $validation.Format
    if (-not $validation.Valid) {
        return New-MoveResult -Succeeded $false -Code $validation.Code -State 'preflight_rejected' -Format $format
    }
    if (Test-Path -LiteralPath $staging) { return New-MoveResult -Succeeded $false -Code 'staging_conflict' -State 'preflight_rejected' -Format $format }
    if (Test-Path -LiteralPath $backup) { return New-MoveResult -Succeeded $false -Code 'backup_conflict' -State 'preflight_rejected' -Format $format }
    if (Test-Path -LiteralPath $failed) { return New-MoveResult -Succeeded $false -Code 'failed_artifact_conflict' -State 'preflight_rejected' -Format $format }
    if (Test-Path -LiteralPath $lock) { return New-MoveResult -Succeeded $false -Code 'transaction_locked' -State 'preflight_rejected' -Format $format }

    foreach ($path in @($source, $destination)) {
        $probe = Invoke-MoveProbe -Probe $ProcessProbe -Path $path
        if (-not $probe.Valid) { return New-MoveResult -Succeeded $false -Code 'process_probe_failed' -State 'preflight_rejected' -Format $format }
        if ($probe.Busy) { return New-MoveResult -Succeeded $false -Code 'process_active' -State 'preflight_rejected' -Format $format }
    }
    if ($DryRun) { return New-MoveResult -Succeeded $true -Code 'dry_run' -State 'validated' -Format $format }

    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $staging) | Out-Null
        New-Item -ItemType Directory -Path $staging -ErrorAction Stop | Out-Null
    } catch { return New-MoveResult -Succeeded $false -Code 'staging_create_failed' -State 'source_active' -Format $format }
    try { & $TransportCopy $source $staging | Out-Null }
    catch { return New-MoveResult -Succeeded $false -Code 'transport_failed' -State 'staging_preserved' -Format $format }
    if (-not (Test-MoveTreesEqual -Left $source -Right $staging)) {
        return New-MoveResult -Succeeded $false -Code 'integrity_mismatch' -State 'staging_rejected' -Format $format
    }

    try { New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null }
    catch { return New-MoveResult -Succeeded $false -Code 'transaction_locked' -State 'staging_preserved' -Format $format }
    if (Test-Path -LiteralPath $destination) {
        Remove-MoveTransactionLock -Path $lock | Out-Null
        return New-MoveResult -Succeeded $false -Code 'destination_appeared' -State 'staging_preserved' -Format $format
    }
    $lockedValidation = Test-MoveProfile -Adapter $Adapter -ProfilePath $source
    if (-not $lockedValidation.Valid -or -not (Test-MoveTreesEqual -Left $source -Right $staging)) {
        Remove-MoveTransactionLock -Path $lock | Out-Null
        return New-MoveResult -Succeeded $false -Code 'integrity_mismatch' -State 'staging_rejected' -Format $format
    }
    foreach ($path in @($source, $destination)) {
        $probe = Invoke-MoveProbe -Probe $ProcessProbe -Path $path
        if (-not $probe.Valid) {
            Remove-MoveTransactionLock -Path $lock | Out-Null
            return New-MoveResult -Succeeded $false -Code 'process_probe_failed' -State 'staging_preserved' -Format $format
        }
        if ($probe.Busy) {
            Remove-MoveTransactionLock -Path $lock | Out-Null
            return New-MoveResult -Succeeded $false -Code 'process_appeared' -State 'staging_preserved' -Format $format
        }
    }

    try { New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null }
    catch {
        Remove-MoveTransactionLock -Path $lock | Out-Null
        return New-MoveResult -Succeeded $false -Code 'backup_prepare_failed' -State 'source_active' -Format $format
    }
    if (-not (Invoke-MoveDeactivation -Source $source -Backup $backup -Deactivation $Deactivation)) {
        Remove-MoveTransactionLock -Path $lock | Out-Null
        return New-MoveResult -Succeeded $false -Code 'source_deactivation_failed' -State 'source_active' -Format $format
    }
    if (-not (Invoke-MoveActivation -Staging $staging -Destination $destination -Activation $Activation)) {
        $result = Restore-MoveSource -Source $source -Backup $backup -Destination $destination -Failed $failed -Code 'activation_failed_rolled_back' -Format $format -Quarantine $Quarantine
        Remove-MoveTransactionLock -Path $lock | Out-Null
        return $result
    }

    $destinationValidation = Test-MoveProfile -Adapter $Adapter -ProfilePath $destination
    if (-not $destinationValidation.Valid -or -not (Test-MoveTreesEqual -Left $backup -Right $destination)) {
        $result = Restore-MoveSource -Source $source -Backup $backup -Destination $destination -Failed $failed -Code 'destination_invalid_rolled_back' -Format $format -Quarantine $Quarantine
        Remove-MoveTransactionLock -Path $lock | Out-Null
        return $result
    }
    if ($format -eq 'v2' -and $validation.Mode -eq 'accountOverlay') {
        $runtimeReady = if ($RuntimeBuilder) {
            try { [bool](& $RuntimeBuilder $Adapter $destination) } catch { $false }
        } else {
            New-MoveRuntimeOverlay -Adapter $Adapter -ProfilePath $destination
        }
        if (-not $runtimeReady) {
            $result = Restore-MoveSource -Source $source -Backup $backup -Destination $destination -Failed $failed -Code 'destination_runtime_failed_rolled_back' -Format $format -Quarantine $Quarantine
            Remove-MoveTransactionLock -Path $lock | Out-Null
            return $result
        }
    }
    if (-not (Test-MoveTreesEqual -Left $backup -Right $destination)) {
        $result = Restore-MoveSource -Source $source -Backup $backup -Destination $destination -Failed $failed -Code 'destination_invalid_rolled_back' -Format $format -Quarantine $Quarantine
        Remove-MoveTransactionLock -Path $lock | Out-Null
        return $result
    }
    if (-not (Remove-MoveTransactionLock -Path $lock)) {
        return New-MoveResult -Succeeded $false -Code 'lock_release_failed' -State 'destination_active' -Format $format
    }
    return New-MoveResult -Succeeded $true -Code 'ok' -State 'destination_active' -Format $format
}

Export-ModuleMember -Function Save-MultiCliTemplate, Export-MultiCliProfile, Import-MultiCliProfile, Assert-TransferTemplateCompatible, Apply-MultiCliTemplate, Invoke-MultiCliProfileMove
