. (Join-Path $PSScriptRoot 'SessionContinuation.Helper.ps1')

$script:JsonMutationRepoRoot = Split-Path -Parent $PSScriptRoot

function Convert-MutationLauncherJson {
    param($Result)
    if ($Result.StdErr.Trim()) { throw "JSON launcher wrote to stderr: $($Result.StdErr.Trim())" }
    return ($Result.StdOut | ConvertFrom-Json)
}

function Assert-MutationEnvelope {
    param($Envelope, [string]$Command)
    $Envelope.schemaVersion | Should Be 1
    $Envelope.command | Should Be $Command
    ($Envelope.ok -is [bool]) | Should Be $true
    ($Envelope.PSObject.Properties.Name -contains 'data') | Should Be $true
    ($Envelope.PSObject.Properties.Name -contains 'error') | Should Be $true
}

function Assert-NoPrivateMutationData {
    param([string]$Json, $Scratch)
    $Json | Should Not Match ([regex]::Escape($Scratch.Root))
    $Json | Should Not Match 'profileId'
    $Json | Should Not Match 'auth\.json'
}

Describe 'stable JSON profile mutations v1' {
    $scratch = $null

    BeforeEach {
        $scratch = New-Scratch
        Copy-Item -LiteralPath (Join-Path $script:JsonMutationRepoRoot 'ai-tools\codex\adapter.json') `
            -Destination (Join-Path $scratch.Tools 'codex\adapter.json') -Force
    }

    AfterEach { Remove-Scratch $scratch }

    It 'creates a schema-v2 profile and returns only its public summary' {
        $result = Invoke-Launcher -Scratch $scratch -Arguments @('new', 'codex/work', '--no-seed', '--json')
        $result.ExitCode | Should Be 0
        $json = Convert-MutationLauncherJson $result
        Assert-MutationEnvelope $json 'new'
        $json.ok | Should Be $true
        $json.data.state | Should Be 'applied'
        $json.data.profile.tool | Should Be 'codex'
        $json.data.profile.name | Should Be 'work'
        $json.data.profile.type | Should Be 'full'
        $json.data.profile.schemaVersion | Should Be 2
        (Test-Path -LiteralPath (Join-Path $scratch.MultiCliHome 'codex\work\.profile.json')) | Should Be $true
        Assert-NoPrivateMutationData $result.StdOut $scratch
    }

    It 'accepts prefix JSON form and preserves isolated profile type' {
        $result = Invoke-Launcher -Scratch $scratch -Arguments @('--json', 'new', 'codex/private', '--isolated', '--cli', '--no-seed')
        $result.ExitCode | Should Be 0
        $json = Convert-MutationLauncherJson $result
        $json.data.profile.type | Should Be 'isolated'
        $json.data.profile.schemaVersion | Should Be 2
        Assert-NoPrivateMutationData $result.StdOut $scratch
    }

    It 'rejects invalid addresses and occupied destinations before writing' {
        $invalid = Invoke-Launcher -Scratch $scratch -Arguments @('new', '../outside', '--no-seed', '--json')
        $invalid.ExitCode | Should Be 2
        $invalidJson = Convert-MutationLauncherJson $invalid
        $invalidJson.error.code | Should Be 'invalid_identifier'
        $invalidJson.error.details.state | Should Be 'not_applied'

        $first = Invoke-Launcher -Scratch $scratch -Arguments @('new', 'codex/work', '--no-seed', '--json')
        $first.ExitCode | Should Be 0
        $duplicate = Invoke-Launcher -Scratch $scratch -Arguments @('new', 'codex/work', '--no-seed', '--json')
        $duplicate.ExitCode | Should Be 2
        $duplicateJson = Convert-MutationLauncherJson $duplicate
        $duplicateJson.error.code | Should Be 'profile_exists'
        $duplicateJson.error.details.state | Should Be 'not_applied'
        Assert-NoPrivateMutationData $duplicate.StdOut $scratch
    }

    It 'reports partial application when alias creation fails' {
        Set-Content -LiteralPath (Join-Path $scratch.MultiCliHome 'bin') -Encoding ASCII -Value 'blocked'
        $result = Invoke-Launcher -Scratch $scratch -Arguments @('new', 'codex/work', '--no-seed', '--json')
        $result.ExitCode | Should Be 6
        $json = Convert-MutationLauncherJson $result
        $json.error.code | Should Be 'operation_failed'
        $json.error.details.state | Should Be 'partially_applied'
        (Test-Path -LiteralPath (Join-Path $scratch.MultiCliHome 'codex\work') -PathType Container) | Should Be $true
        Assert-NoPrivateMutationData $result.StdOut $scratch
    }

    It 'renames while preserving the profile identity and public address contract' {
        $created = Invoke-Launcher -Scratch $scratch -Arguments @('new', 'codex/old', '--no-seed', '--json')
        $created.ExitCode | Should Be 0
        $oldMetadata = Get-Content -LiteralPath (Join-Path $scratch.MultiCliHome 'codex\old\.profile.json') -Raw | ConvertFrom-Json

        $result = Invoke-Launcher -Scratch $scratch -Arguments @('rename', 'codex/old', 'codex/new', '--json')
        $result.ExitCode | Should Be 0
        $json = Convert-MutationLauncherJson $result
        Assert-MutationEnvelope $json 'rename'
        $json.data.state | Should Be 'applied'
        $json.data.from.tool | Should Be 'codex'
        $json.data.from.name | Should Be 'old'
        $json.data.profile.name | Should Be 'new'
        $newMetadata = Get-Content -LiteralPath (Join-Path $scratch.MultiCliHome 'codex\new\.profile.json') -Raw | ConvertFrom-Json
        $newMetadata.profileId | Should Be $oldMetadata.profileId
        Assert-NoPrivateMutationData $result.StdOut $scratch
    }

    It 'rejects missing, occupied, and cross-tool destinations' {
        $missing = Invoke-Launcher -Scratch $scratch -Arguments @('rename', 'codex/missing', 'codex/new', '--json')
        $missing.ExitCode | Should Be 2
        (Convert-MutationLauncherJson $missing).error.code | Should Be 'profile_not_found'

        (Invoke-Launcher -Scratch $scratch -Arguments @('new', 'codex/old', '--no-seed', '--json')).ExitCode | Should Be 0
        (Invoke-Launcher -Scratch $scratch -Arguments @('new', 'codex/new', '--no-seed', '--json')).ExitCode | Should Be 0
        $occupied = Invoke-Launcher -Scratch $scratch -Arguments @('rename', 'codex/old', 'codex/new', '--json')
        $occupied.ExitCode | Should Be 2
        (Convert-MutationLauncherJson $occupied).error.code | Should Be 'profile_exists'

        $crossTool = Invoke-Launcher -Scratch $scratch -Arguments @('rename', 'codex/old', 'cursor/old', '--json')
        $crossTool.ExitCode | Should Be 2
        (Convert-MutationLauncherJson $crossTool).error.code | Should Be 'cross_tool_rename'
        Assert-NoPrivateMutationData $crossTool.StdOut $scratch
    }

    It 'reports partial application when alias recreation fails' {
        (Invoke-Launcher -Scratch $scratch -Arguments @('new', 'codex/old', '--no-seed', '--json')).ExitCode | Should Be 0
        Remove-Item -LiteralPath (Join-Path $scratch.MultiCliHome 'bin') -Recurse -Force
        Set-Content -LiteralPath (Join-Path $scratch.MultiCliHome 'bin') -Encoding ASCII -Value 'blocked'

        $result = Invoke-Launcher -Scratch $scratch -Arguments @('rename', 'codex/old', 'codex/new', '--json')
        $result.ExitCode | Should Be 6
        $json = Convert-MutationLauncherJson $result
        $json.error.code | Should Be 'operation_failed'
        $json.error.details.state | Should Be 'partially_applied'
        (Test-Path -LiteralPath (Join-Path $scratch.MultiCliHome 'codex\old')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $scratch.MultiCliHome 'codex\new') -PathType Container) | Should Be $true
        Assert-NoPrivateMutationData $result.StdOut $scratch
    }
}
