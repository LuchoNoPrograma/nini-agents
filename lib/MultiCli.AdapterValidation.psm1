Set-StrictMode -Version Latest

# Semantic adapter.json validation for nini-agents (Windows).
# PowerShell mirror of lib/adapter-validation.sh: declared paths are relative
# and traversal-free, credential/shared/session/unsafe lists never overlap,
# placeholders come from the known set, and every unsupported support row
# carries the reason why.
#
# Entry point: Test-AdapterManifest -ManifestPath <path> -ExpectedId <id>;
# returns an array of validation error strings (empty = valid).

function Add-AdapterValidationError {
    param([System.Collections.Generic.List[string]]$Errors, [string]$Message)
    $Errors.Add($Message)
}

# True when $Path is a non-empty relative path with no drive letter, colon,
# or '..' component -- safe to join under a state root.
function Test-SafeAdapterPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = $Path -replace '\\', '/'
    if ($normalized -match '^/' -or $normalized -match '^[a-zA-Z]:' -or $normalized -match ':') { return $false }
    if ($normalized -eq '.' -or $normalized -eq '..' -or "/$normalized/" -match '/\.\./') { return $false }
    return $true
}

function Test-AdapterPathsOverlap {
    param([string]$Left, [string]$Right)
    # Case-insensitive like the bash validator: declared paths land on
    # case-insensitive filesystems (Windows, default macOS), where 'Auth.json'
    # and 'auth.json' are the same file.
    $leftPath = ($Left -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
    $rightPath = ($Right -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
    return ($leftPath -eq $rightPath -or $leftPath.StartsWith("$rightPath/") -or $rightPath.StartsWith("$leftPath/"))
}

function Test-AdapterDotSuffixBackup {
    param([string]$Base, [string]$Candidate)
    $normalizedBase = (($Base -replace '\\', '/').TrimEnd('/')).ToLowerInvariant()
    $normalizedCandidate = (($Candidate -replace '\\', '/').TrimEnd('/')).ToLowerInvariant()
    return $normalizedCandidate -ne "$normalizedBase." -and
        $normalizedCandidate.StartsWith("$normalizedBase.", [StringComparison]::Ordinal)
}

function Get-ObjectProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# Record an error for every list entry that is not a safe relative path;
# $Label names the list in messages.
function Test-AdapterPathList {
    param(
        [System.Collections.Generic.List[string]]$Errors,
        $Values,
        [string]$Label
    )
    foreach ($value in @($Values)) {
        if ($null -eq $value -or $value -eq '') { continue }
        if (-not (Test-SafeAdapterPath -Path ([string]$value))) {
            Add-AdapterValidationError -Errors $Errors -Message "$Label '$value' must be a safe relative path"
        }
    }
}

# Record an error for any pair of entries across two lists that overlap (a
# credential path nested under a shared path would leak).
function Test-AdapterPathSeparation {
    param(
        [System.Collections.Generic.List[string]]$Errors,
        $LeftValues,
        [string]$LeftLabel,
        $RightValues,
        [string]$RightLabel
    )
    foreach ($left in @($LeftValues)) {
        if ($null -eq $left -or $left -eq '') { continue }
        foreach ($right in @($RightValues)) {
            if ($null -eq $right -or $right -eq '') { continue }
            if (Test-AdapterPathsOverlap -Left ([string]$left) -Right ([string]$right)) {
                Add-AdapterValidationError -Errors $Errors -Message "$LeftLabel '$left' overlaps $RightLabel '$right'"
            }
        }
    }
}

# filePaths, directPaths, and migrationPreservePaths classify entries that
# already belong to sharedPaths or sessionPaths; none may introduce
# undeclared state.
function Test-AdapterStatePathMembership {
    param(
        [System.Collections.Generic.List[string]]$Errors,
        $Paths,
        [string]$Label,
        $SharedPaths,
        $SessionPaths
    )
    $declared = @($SharedPaths) + @($SessionPaths) | Where-Object { $null -ne $_ -and $_ -ne '' } | ForEach-Object {
        ([string]$_ -replace '\\', '/').ToLowerInvariant()
    }
    foreach ($path in @($Paths)) {
        if ($null -eq $path -or $path -eq '') { continue }
        if (-not (Test-SafeAdapterPath -Path ([string]$path))) { continue }
        $normalized = ([string]$path -replace '\\', '/').ToLowerInvariant()
        if ($declared -notcontains $normalized) {
            Add-AdapterValidationError -Errors $Errors -Message "$Label '$path' must also be declared in sharedPaths or sessionPaths"
        }
    }
}

# Reject any {placeholder} outside the known set; an unknown one would expand
# to a literal brace directory at launch time.
function Test-AdapterPlaceholders {
    param([System.Collections.Generic.List[string]]$Errors, [string]$Json)
    $allowed = @('{profileDir}', '{profileId}', '{authDir}', '{runtimeRoot}', '{sharedStateRoot}', '{realHome}')
    $matches = [regex]::Matches($Json, '\{[A-Za-z][A-Za-z0-9]*\}')
    foreach ($match in $matches) {
        if ($allowed -notcontains $match.Value) {
            Add-AdapterValidationError -Errors $Errors -Message "unknown placeholder '$($match.Value)'"
        }
    }
}

function Test-AdapterObjectFields {
    param(
        [System.Collections.Generic.List[string]]$Errors,
        $Object,
        [string[]]$Allowed,
        [string]$Label
    )
    if ($null -eq $Object) { return }
    foreach ($property in $Object.PSObject.Properties) {
        if ($Allowed -contains $property.Name) { continue }
        $message = if ($Label) { "unsupported field '$Label.$($property.Name)'" } else { "unsupported top-level field '$($property.Name)'" }
        Add-AdapterValidationError -Errors $Errors -Message $message
    }
}

function Test-AdapterFields {
    param([System.Collections.Generic.List[string]]$Errors, $Adapter, [int]$SchemaVersion)
    $allowedTopLevel = @('schemaVersion', 'id', 'displayName', 'kind', 'binary', 'isolation', 'install', 'versionCommand')
    if ($SchemaVersion -eq 1) { $allowedTopLevel += @('share', 'session', 'status') }
    if ($SchemaVersion -eq 2) { $allowedTopLevel += @('account', 'normalState', 'sharedCredentialState', 'concurrency', 'support') }
    Test-AdapterObjectFields -Errors $Errors -Object $Adapter -Allowed $allowedTopLevel -Label ''
    $isolation = Get-ObjectProperty -Object $Adapter -Name 'isolation'
    Test-AdapterObjectFields -Errors $Errors -Object $isolation -Allowed @('strategy', 'mode', 'env', 'clearEnv', 'args', 'shareFromRealHome') -Label 'isolation'
    if ($SchemaVersion -eq 1) {
        Test-AdapterObjectFields -Errors $Errors -Object (Get-ObjectProperty -Object $Adapter -Name 'share') -Allowed @('systemHome', 'linkable', 'neverLink') -Label 'share'
        Test-AdapterObjectFields -Errors $Errors -Object (Get-ObjectProperty -Object $Adapter -Name 'session') -Allowed @('portable', 'paths', 'credentials', 'reason', 'resumeHint') -Label 'session'
        return
    }
    $account = Get-ObjectProperty -Object $Adapter -Name 'account'
    Test-AdapterObjectFields -Errors $Errors -Object $account -Allowed @('mechanism', 'credentialFiles', 'credentialPrecedence', 'logoutScope', 'reason', 'secret') -Label 'account'
    Test-AdapterObjectFields -Errors $Errors -Object (Get-ObjectProperty -Object $account -Name 'secret') -Allowed @('environmentVariable') -Label 'account.secret'
    $normalState = Get-ObjectProperty -Object $Adapter -Name 'normalState'
    Test-AdapterObjectFields -Errors $Errors -Object $normalState -Allowed @('root', 'runtimeSubdir', 'sharedPaths', 'sessionPaths', 'runtimePaths', 'filePaths', 'directPaths', 'migrationPreservePaths', 'unsafePaths') -Label 'normalState'
    Test-AdapterObjectFields -Errors $Errors -Object (Get-ObjectProperty -Object $normalState -Name 'root') -Allowed @('windows', 'macos', 'linux') -Label 'normalState.root'
    $sharedCredentialState = Get-ObjectProperty -Object $Adapter -Name 'sharedCredentialState'
    Test-AdapterObjectFields -Errors $Errors -Object $sharedCredentialState -Allowed @('root', 'entries', 'legacyMigration', 'legacyBackupPattern') -Label 'sharedCredentialState'
    foreach ($entry in @(Get-ObjectProperty -Object $sharedCredentialState -Name 'entries')) {
        Test-AdapterObjectFields -Errors $Errors -Object $entry -Allowed @('path', 'kind') -Label 'sharedCredentialState.entries'
    }
    Test-AdapterObjectFields -Errors $Errors -Object (Get-ObjectProperty -Object $Adapter -Name 'concurrency') -Allowed @('level', 'singletonScope') -Label 'concurrency'
    $support = Get-ObjectProperty -Object $Adapter -Name 'support'
    Test-AdapterObjectFields -Errors $Errors -Object $support -Allowed @('windows', 'macos', 'linux') -Label 'support'
    foreach ($platform in @('windows', 'macos', 'linux')) {
        Test-AdapterObjectFields -Errors $Errors -Object (Get-ObjectProperty -Object $support -Name $platform) -Allowed @('level', 'reason') -Label "support.$platform"
    }
}

# Validate credential state that is shared intentionally across profiles. Its
# backing root must be adapter-owned below MULTICLI_HOME\.shared, while the
# paths exposed inside a runtime remain disjoint from every other state class.
function Test-AdapterSharedCredentialState {
    param([System.Collections.Generic.List[string]]$Errors, $Adapter)
    $sharedCredentialState = Get-ObjectProperty -Object $Adapter -Name 'sharedCredentialState'
    if ($null -eq $sharedCredentialState) { return }

    $account = Get-ObjectProperty -Object $Adapter -Name 'account'
    if ((Get-ObjectProperty -Object $account -Name 'mechanism') -ne 'fileOverlay') {
        Add-AdapterValidationError -Errors $Errors -Message "sharedCredentialState requires account.mechanism 'fileOverlay'"
    }

    $root = [string](Get-ObjectProperty -Object $sharedCredentialState -Name 'root')
    if (-not (Test-SafeAdapterPath -Path $root)) {
        Add-AdapterValidationError -Errors $Errors -Message "sharedCredentialState.root '$root' must be a safe relative path"
    } else {
        $normalizedRoot = ($root -replace '\\', '/').ToLowerInvariant()
        $expectedPrefix = ".shared/$(([string]$Adapter.id).ToLowerInvariant())/"
        if (-not $normalizedRoot.StartsWith($expectedPrefix, [StringComparison]::Ordinal)) {
            Add-AdapterValidationError -Errors $Errors -Message "sharedCredentialState.root must be below '.shared/$($Adapter.id)/'"
        }
    }

    if ((Get-ObjectProperty -Object $sharedCredentialState -Name 'legacyMigration') -ne 'preserveInactive') {
        Add-AdapterValidationError -Errors $Errors -Message "sharedCredentialState.legacyMigration must be 'preserveInactive'"
    }

    $backupPattern = Get-ObjectProperty -Object $sharedCredentialState -Name 'legacyBackupPattern'
    if ($backupPattern -and $backupPattern -ne 'dotSuffix') {
        Add-AdapterValidationError -Errors $Errors -Message "sharedCredentialState.legacyBackupPattern must be 'dotSuffix' when present"
    }

    $entriesValue = Get-ObjectProperty -Object $sharedCredentialState -Name 'entries'
    $entries = @($entriesValue)
    if ($null -eq $entriesValue -or $entries.Count -eq 0) {
        Add-AdapterValidationError -Errors $Errors -Message 'sharedCredentialState.entries must be a non-empty array'
        return
    }

    $paths = @()
    foreach ($entry in $entries) {
        $path = [string](Get-ObjectProperty -Object $entry -Name 'path')
        $kind = [string](Get-ObjectProperty -Object $entry -Name 'kind')
        if (-not $path) {
            Add-AdapterValidationError -Errors $Errors -Message 'shared credential entry path is required'
            continue
        }
        if (-not (Test-SafeAdapterPath -Path $path)) {
            Add-AdapterValidationError -Errors $Errors -Message "shared credential path '$path' must be a safe relative path"
        }
        if (@('jsonObjectFile', 'directory') -notcontains $kind) {
            Add-AdapterValidationError -Errors $Errors -Message "shared credential kind '$kind' is not supported"
        }
        $paths += $path
    }

    for ($leftIndex = 0; $leftIndex -lt $paths.Count; $leftIndex++) {
        $path = $paths[$leftIndex]
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $paths.Count; $rightIndex++) {
            $otherPath = $paths[$rightIndex]
            if ((Test-AdapterPathsOverlap -Left $path -Right $otherPath) -or
                ($backupPattern -eq 'dotSuffix' -and (Test-AdapterDotSuffixBackup -Base $path -Candidate $otherPath)) -or
                ($backupPattern -eq 'dotSuffix' -and (Test-AdapterDotSuffixBackup -Base $otherPath -Candidate $path))) {
                Add-AdapterValidationError -Errors $Errors -Message "shared credential path '$path' overlaps shared credential path '$otherPath'"
            }
        }
        $normalState = Get-ObjectProperty -Object $Adapter -Name 'normalState'
        foreach ($declaration in @(
            [pscustomobject]@{ Values = (Get-ObjectProperty -Object $account -Name 'credentialFiles'); Label = 'credential' },
            [pscustomobject]@{ Values = (Get-ObjectProperty -Object $normalState -Name 'sharedPaths'); Label = 'shared' },
            [pscustomobject]@{ Values = (Get-ObjectProperty -Object $normalState -Name 'sessionPaths'); Label = 'session' },
            [pscustomobject]@{ Values = (Get-ObjectProperty -Object $normalState -Name 'runtimePaths'); Label = 'runtime' },
            [pscustomobject]@{ Values = (Get-ObjectProperty -Object $normalState -Name 'unsafePaths'); Label = 'unsafe' }
        )) {
            foreach ($normalPath in @($declaration.Values)) {
                if (-not $normalPath) { continue }
                if ((Test-AdapterPathsOverlap -Left $path -Right ([string]$normalPath)) -or
                    ($backupPattern -eq 'dotSuffix' -and (Test-AdapterDotSuffixBackup -Base $path -Candidate ([string]$normalPath)))) {
                    Add-AdapterValidationError -Errors $Errors -Message "shared credential path '$path' overlaps $($declaration.Label) path '$normalPath'"
                }
            }
        }
    }
}

# Platform keys must be exactly windows/macos/linux; schema-v2 additionally
# requires at least one non-empty binary candidate per platform.
function Test-AdapterBinary {
    param([System.Collections.Generic.List[string]]$Errors, $Adapter, [int]$SchemaVersion)
    $binary = Get-ObjectProperty -Object $Adapter -Name 'binary'
    if ($null -eq $binary) { return }
    foreach ($property in $binary.PSObject.Properties) {
        switch ($property.Name) {
            'windows' { }
            'macos' { }
            'linux' { }
            'darwin' { Add-AdapterValidationError -Errors $Errors -Message "binary uses unsupported platform key 'darwin'; use 'macos'" }
            default { Add-AdapterValidationError -Errors $Errors -Message "binary uses unsupported platform key '$($property.Name)'" }
        }
    }
    if ($SchemaVersion -eq 2) {
        foreach ($platform in @('windows', 'macos', 'linux')) {
            $property = $binary.PSObject.Properties[$platform]
            if ($null -eq $property -or $null -eq $property.Value) {
                Add-AdapterValidationError -Errors $Errors -Message "binary.$platform must contain at least one candidate"
                continue
            }
            if ($property.Value -isnot [System.Array]) {
                Add-AdapterValidationError -Errors $Errors -Message "binary.$platform must be an array of candidates"
                continue
            }
            foreach ($candidate in $property.Value) {
                if ($null -eq $candidate -or [string]::IsNullOrWhiteSpace([string]$candidate)) {
                    Add-AdapterValidationError -Errors $Errors -Message "binary.$platform candidates must be non-empty strings"
                }
            }
            if ($property.Value.Count -eq 0) {
                Add-AdapterValidationError -Errors $Errors -Message "binary.$platform must contain at least one candidate"
            }
        }
    }
}

# Every platform row needs a level: 'supported' (reason optional, encouraged
# for mode requirements) or 'unsupported' (reason required). The retired
# verified/experimental levels are rejected with an explicit message.
function Test-AdapterSupport {
    param([System.Collections.Generic.List[string]]$Errors, $Support)
    foreach ($platform in @('windows', 'macos', 'linux')) {
        $entry = Get-ObjectProperty -Object $Support -Name $platform
        $level = Get-ObjectProperty -Object $entry -Name 'level'
        switch ($level) {
            'supported' { }
            'unsupported' {
                if (-not (Get-ObjectProperty -Object $entry -Name 'reason')) {
                    Add-AdapterValidationError -Errors $Errors -Message "support.$platform.reason is required for level 'unsupported'"
                }
            }
            { $_ -eq 'verified' -or $_ -eq 'experimental' } {
                Add-AdapterValidationError -Errors $Errors -Message "support.$platform.level '$level' was retired; use 'supported' or 'unsupported'"
            }
            default { Add-AdapterValidationError -Errors $Errors -Message "support.$platform.level must be supported or unsupported" }
        }
    }
}

# Schema-v1 (legacy whole-root isolation): a known strategy plus safe,
# non-overlapping share/session path lists.
function Test-AdapterV1 {
    param([System.Collections.Generic.List[string]]$Errors, $Adapter)
    $isolation = Get-ObjectProperty -Object $Adapter -Name 'isolation'
    $strategy = Get-ObjectProperty -Object $isolation -Name 'strategy'
    if (@('env', 'userDataDir', 'redirectHome', 'appdata', 'sandboxUser') -notcontains $strategy) {
        Add-AdapterValidationError -Errors $Errors -Message "isolation.strategy '$strategy' is not supported for schema-v1"
    }

    $share = Get-ObjectProperty -Object $Adapter -Name 'share'
    $session = Get-ObjectProperty -Object $Adapter -Name 'session'
    $linkable = Get-ObjectProperty -Object $share -Name 'linkable'
    $neverLink = Get-ObjectProperty -Object $share -Name 'neverLink'
    $sessionPaths = Get-ObjectProperty -Object $session -Name 'paths'
    $credentials = Get-ObjectProperty -Object $session -Name 'credentials'
    Test-AdapterPathList -Errors $Errors -Values $linkable -Label 'share.linkable path'
    Test-AdapterPathList -Errors $Errors -Values $neverLink -Label 'share.neverLink path'
    Test-AdapterPathList -Errors $Errors -Values $sessionPaths -Label 'session path'
    Test-AdapterPathList -Errors $Errors -Values $credentials -Label 'credential path'
    Test-AdapterPathSeparation -Errors $Errors -LeftValues $linkable -LeftLabel 'share.linkable path' -RightValues $neverLink -RightLabel 'share.neverLink path'
    Test-AdapterPathSeparation -Errors $Errors -LeftValues $sessionPaths -LeftLabel 'session path' -RightValues $credentials -RightLabel 'credential path'
}

# Schema-v2 (accountOverlay): account mechanism with its required fields,
# concurrency declaration, per-platform state roots, and full separation
# between credential, shared, session, and unsafe path lists.
function Test-AdapterV2 {
    param([System.Collections.Generic.List[string]]$Errors, $Adapter)
    $isolation = Get-ObjectProperty -Object $Adapter -Name 'isolation'
    if ((Get-ObjectProperty -Object $isolation -Name 'strategy') -ne 'accountOverlay') {
        Add-AdapterValidationError -Errors $Errors -Message "isolation.strategy must be 'accountOverlay' for schema-v2"
    }
    if (@('foreground', 'detached') -notcontains (Get-ObjectProperty -Object $isolation -Name 'mode')) {
        Add-AdapterValidationError -Errors $Errors -Message "isolation.mode must be 'foreground' or 'detached'"
    }

    $account = Get-ObjectProperty -Object $Adapter -Name 'account'
    $mechanism = Get-ObjectProperty -Object $account -Name 'mechanism'
    switch ($mechanism) {
        'fileOverlay' {
            $credentialFiles = @(Get-ObjectProperty -Object $account -Name 'credentialFiles')
            if ($credentialFiles.Count -eq 0 -or ($credentialFiles.Count -eq 1 -and $null -eq $credentialFiles[0])) {
                Add-AdapterValidationError -Errors $Errors -Message 'account.credentialFiles must not be empty for fileOverlay'
            }
        }
        'processSecret' {
            $secret = Get-ObjectProperty -Object $account -Name 'secret'
            if (-not (Get-ObjectProperty -Object $secret -Name 'environmentVariable')) {
                Add-AdapterValidationError -Errors $Errors -Message 'account.secret.environmentVariable is required for processSecret'
            }
        }
        'osUserCredentialStore' { }
        'inseparable' {
            if (-not (Get-ObjectProperty -Object $account -Name 'reason')) {
                Add-AdapterValidationError -Errors $Errors -Message 'account.reason is required for inseparable state'
            }
        }
        default { Add-AdapterValidationError -Errors $Errors -Message "account.mechanism '$mechanism' is not supported" }
    }

    $normalState = Get-ObjectProperty -Object $Adapter -Name 'normalState'
    $root = Get-ObjectProperty -Object $normalState -Name 'root'
    foreach ($platform in @('windows', 'macos', 'linux')) {
        if (-not (Get-ObjectProperty -Object $root -Name $platform)) {
            Add-AdapterValidationError -Errors $Errors -Message "normalState.root.$platform is required"
        }
    }
    $stateSubdir = Get-ObjectProperty -Object $normalState -Name 'runtimeSubdir'
    if ($stateSubdir -and -not (Test-SafeAdapterPath -Path $stateSubdir)) {
        Add-AdapterValidationError -Errors $Errors -Message "normalState.runtimeSubdir '$stateSubdir' must be a safe relative path"
    }

    $credentials = Get-ObjectProperty -Object $account -Name 'credentialFiles'
    $sharedPaths = Get-ObjectProperty -Object $normalState -Name 'sharedPaths'
    $sessionPaths = Get-ObjectProperty -Object $normalState -Name 'sessionPaths'
    $runtimePaths = Get-ObjectProperty -Object $normalState -Name 'runtimePaths'
    $filePaths = Get-ObjectProperty -Object $normalState -Name 'filePaths'
    $directPaths = Get-ObjectProperty -Object $normalState -Name 'directPaths'
    $migrationPreservePaths = Get-ObjectProperty -Object $normalState -Name 'migrationPreservePaths'
    $unsafePaths = Get-ObjectProperty -Object $normalState -Name 'unsafePaths'
    Test-AdapterPathList -Errors $Errors -Values $credentials -Label 'credential path'
    Test-AdapterPathList -Errors $Errors -Values $sharedPaths -Label 'shared path'
    Test-AdapterPathList -Errors $Errors -Values $sessionPaths -Label 'session path'
    Test-AdapterPathList -Errors $Errors -Values $runtimePaths -Label 'runtime path'
    Test-AdapterPathList -Errors $Errors -Values $filePaths -Label 'file path'
    Test-AdapterPathList -Errors $Errors -Values $directPaths -Label 'direct path'
    Test-AdapterPathList -Errors $Errors -Values $migrationPreservePaths -Label 'migration preserve path'
    Test-AdapterPathList -Errors $Errors -Values $unsafePaths -Label 'unsafe path'
    Test-AdapterPathSeparation -Errors $Errors -LeftValues $credentials -LeftLabel 'credential path' -RightValues $sharedPaths -RightLabel 'shared path'
    Test-AdapterPathSeparation -Errors $Errors -LeftValues $credentials -LeftLabel 'credential path' -RightValues $sessionPaths -RightLabel 'session path'
    Test-AdapterPathSeparation -Errors $Errors -LeftValues $credentials -LeftLabel 'credential path' -RightValues $runtimePaths -RightLabel 'runtime path'
    Test-AdapterPathSeparation -Errors $Errors -LeftValues $credentials -LeftLabel 'credential path' -RightValues $unsafePaths -RightLabel 'unsafe path'
    Test-AdapterPathSeparation -Errors $Errors -LeftValues $sharedPaths -LeftLabel 'shared path' -RightValues $sessionPaths -RightLabel 'session path'
    Test-AdapterPathSeparation -Errors $Errors -LeftValues $sharedPaths -LeftLabel 'shared path' -RightValues $runtimePaths -RightLabel 'runtime path'
    Test-AdapterPathSeparation -Errors $Errors -LeftValues $sharedPaths -LeftLabel 'shared path' -RightValues $unsafePaths -RightLabel 'unsafe path'
    Test-AdapterPathSeparation -Errors $Errors -LeftValues $sessionPaths -LeftLabel 'session path' -RightValues $unsafePaths -RightLabel 'unsafe path'
    Test-AdapterPathSeparation -Errors $Errors -LeftValues $sessionPaths -LeftLabel 'session path' -RightValues $runtimePaths -RightLabel 'runtime path'
    Test-AdapterPathSeparation -Errors $Errors -LeftValues $runtimePaths -LeftLabel 'runtime path' -RightValues $unsafePaths -RightLabel 'unsafe path'
    Test-AdapterStatePathMembership -Errors $Errors -Paths $filePaths -Label 'file path' -SharedPaths $sharedPaths -SessionPaths $sessionPaths
    Test-AdapterStatePathMembership -Errors $Errors -Paths $directPaths -Label 'direct path' -SharedPaths $sharedPaths -SessionPaths $sessionPaths
    Test-AdapterStatePathMembership -Errors $Errors -Paths $migrationPreservePaths -Label 'migration preserve path' -SharedPaths $sharedPaths -SessionPaths $sessionPaths
    Test-AdapterSharedCredentialState -Errors $Errors -Adapter $Adapter

    $concurrency = Get-ObjectProperty -Object $Adapter -Name 'concurrency'
    if (@('multiWriter', 'singleWriter', 'unsupported') -notcontains (Get-ObjectProperty -Object $concurrency -Name 'level')) {
        Add-AdapterValidationError -Errors $Errors -Message 'concurrency.level is invalid'
    }
    if (-not (Get-ObjectProperty -Object $concurrency -Name 'singletonScope')) {
        Add-AdapterValidationError -Errors $Errors -Message 'concurrency.singletonScope is required'
    }
    Test-AdapterSupport -Errors $Errors -Support (Get-ObjectProperty -Object $Adapter -Name 'support')
}

# Validate one manifest against the directory it lives in; returns every
# problem found (empty array = fully compliant).
function Test-AdapterManifest {
    param([string]$ManifestPath, [string]$ExpectedId)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $json = Get-Content -LiteralPath $ManifestPath -Raw
    try {
        $adapter = $json | ConvertFrom-Json
    } catch {
        Add-AdapterValidationError -Errors $errors -Message 'invalid JSON'
        return $errors.ToArray()
    }

    $id = Get-ObjectProperty -Object $adapter -Name 'id'
    if (-not $id -or $id -notmatch '^[a-z0-9][a-z0-9-]*$') {
        Add-AdapterValidationError -Errors $errors -Message 'id must match ^[a-z0-9][a-z0-9-]*$'
    }
    if ($id -ne $ExpectedId) {
        Add-AdapterValidationError -Errors $errors -Message "directory '$ExpectedId' does not match id '$id'"
    }
    foreach ($required in @('displayName', 'kind', 'binary', 'isolation')) {
        if ($null -eq (Get-ObjectProperty -Object $adapter -Name $required)) {
            Add-AdapterValidationError -Errors $errors -Message "$required is required"
        }
    }

    $schemaVersion = Get-ObjectProperty -Object $adapter -Name 'schemaVersion'
    if ($null -eq $schemaVersion) { $schemaVersion = 1 }
    if ($schemaVersion -isnot [int] -and $schemaVersion -isnot [long]) {
        Add-AdapterValidationError -Errors $errors -Message "schemaVersion '$schemaVersion' is not an integer"
        return $errors.ToArray()
    }
    switch ([int]$schemaVersion) {
        1 { Test-AdapterV1 -Errors $errors -Adapter $adapter }
        2 { Test-AdapterV2 -Errors $errors -Adapter $adapter }
        default {
            Add-AdapterValidationError -Errors $errors -Message "schemaVersion '$schemaVersion' is not supported"
            return $errors.ToArray()
        }
    }
    Test-AdapterFields -Errors $errors -Adapter $adapter -SchemaVersion ([int]$schemaVersion)
    Test-AdapterBinary -Errors $errors -Adapter $adapter -SchemaVersion ([int]$schemaVersion)
    Test-AdapterPlaceholders -Errors $errors -Json $json
    return $errors.ToArray()
}

Export-ModuleMember -Function Test-AdapterManifest
