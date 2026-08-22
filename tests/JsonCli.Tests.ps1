. (Join-Path $PSScriptRoot 'SessionContinuation.Helper.ps1')

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:JsonModule = Join-Path $script:RepoRoot 'lib\MultiCli.Json.psm1'

function Convert-LauncherJson {
    param($Result)
    if ($Result.StdErr.Trim()) { throw "JSON launcher wrote to stderr: $($Result.StdErr.Trim())" }
    return ($Result.StdOut | ConvertFrom-Json)
}

function Assert-JsonEnvelope {
    param($Envelope, [string]$Command)
    $Envelope.schemaVersion | Should Be 1
    $Envelope.command | Should Be $Command
    ($Envelope.ok -is [bool]) | Should Be $true
    ($Envelope.PSObject.Properties.Name -contains 'data') | Should Be $true
    ($Envelope.PSObject.Properties.Name -contains 'error') | Should Be $true
}

function Assert-NoPrivateJsonData {
    param([string]$Json, $Scratch)
    $Json | Should Not Match ([regex]::Escape($Scratch.Root))
    $Json | Should Not Match 'profileId'
    $Json | Should Not Match 'fixtureOnly'
    $Json | Should Not Match 'auth\.json'
}

Describe 'stable JSON CLI v1' {
    $scratch = $null

    BeforeEach {
        $scratch = New-Scratch
        $codex = Join-Path $scratch.MultiCliHome 'codex\work'
        $cursor = Join-Path $scratch.MultiCliHome 'cursor\personal'
        New-Item -ItemType Directory -Force -Path (Join-Path $codex 'auth'), $cursor | Out-Null
        Set-Content -LiteralPath (Join-Path $codex '.profile.json') -Encoding UTF8 -Value '{"schemaVersion":2,"profileId":null,"adapterId":"codex","mode":"accountOverlay"}'
        Set-Content -LiteralPath (Join-Path $codex 'auth\auth.json') -Encoding UTF8 -Value '{"fixtureOnly":true}'
        Set-Content -LiteralPath (Join-Path $cursor 'state.txt') -Encoding UTF8 -Value 'ordinary-state'
        $template = Join-Path $scratch.MultiCliHome '.templates\plain'
        New-Item -ItemType Directory -Force -Path $template | Out-Null
        Set-Content -LiteralPath (Join-Path $template 'config.toml') -Encoding UTF8 -Value 'template-state'
    }

    AfterEach { Remove-Scratch $scratch }

    It 'emits version JSON in prefix and suffix forms' {
        $cases = @(
            [pscustomobject]@{ Arguments = @('--json', 'version') },
            [pscustomobject]@{ Arguments = @('version', '--json') }
        )
        foreach ($case in $cases) {
            $result = Invoke-Launcher -Scratch $scratch -Arguments $case.Arguments
            $result.ExitCode | Should Be 0
            $json = Convert-LauncherJson $result
            Assert-JsonEnvelope $json 'version'
            $json.ok | Should Be $true
            $json.data.product | Should Be 'nini-agents'
            $json.data.version | Should Be '1.0.0'
        }
    }

    It 'lists safe profile summaries and honors the status filter' {
        $result = Invoke-Launcher -Scratch $scratch -Arguments @('list', '--json')
        $result.ExitCode | Should Be 0
        $json = Convert-LauncherJson $result
        Assert-JsonEnvelope $json 'list'
        $json.data.count | Should Be 2
        @($json.data.profiles | Where-Object { $_.tool -eq 'codex' -and $_.name -eq 'work' -and $_.schemaVersion -eq 2 }).Count | Should Be 1
        Assert-NoPrivateJsonData $result.StdOut $scratch

        $result = Invoke-Launcher -Scratch $scratch -Arguments @('--json', 'status', 'codex')
        if ($result.ExitCode -ne 0) {
            throw "status JSON failed with exit $($result.ExitCode); stdout=$($result.StdOut.Trim()); stderr=$($result.StdErr.Trim())"
        }
        $json = Convert-LauncherJson $result
        Assert-JsonEnvelope $json 'status'
        $json.data.count | Should Be 1
        $json.data.profiles[0].tool | Should Be 'codex'
        Assert-NoPrivateJsonData $result.StdOut $scratch
    }

    It 'reports tools and doctor without paths' {
        foreach ($command in @('tools', 'doctor')) {
            $result = Invoke-Launcher -Scratch $scratch -Arguments @($command, '--json')
            $result.ExitCode | Should Be 0
            $json = Convert-LauncherJson $result
            Assert-JsonEnvelope $json $command
            @($json.data.tools).Count | Should Be 2
            Assert-NoPrivateJsonData $result.StdOut $scratch
        }
    }

    It 'reports numeric stats and template sizes' {
        $result = Invoke-Launcher -Scratch $scratch -Arguments @('stats', '--json')
        $json = Convert-LauncherJson $result
        Assert-JsonEnvelope $json 'stats'
        $json.data.count | Should Be 2
        ($json.data.totalBytes -is [long] -or $json.data.totalBytes -is [int]) | Should Be $true

        $result = Invoke-Launcher -Scratch $scratch -Arguments @('template', 'list', '--json')
        $json = Convert-LauncherJson $result
        Assert-JsonEnvelope $json 'template-list'
        $json.data.count | Should Be 1
        $json.data.templates[0].name | Should Be 'plain'
        Assert-NoPrivateJsonData $result.StdOut $scratch
    }

    It 'rejects mutation commands before changing a profile' {
        $result = Invoke-Launcher -Scratch $scratch -Arguments @('delete', 'codex/work', '--json')
        $result.ExitCode | Should Be 2
        $json = Convert-LauncherJson $result
        Assert-JsonEnvelope $json 'delete'
        $json.ok | Should Be $false
        $json.error.code | Should Be 'json_unsupported'
        (Test-Path -LiteralPath (Join-Path $scratch.MultiCliHome 'codex\work')) | Should Be $true
        Assert-NoPrivateJsonData $result.StdOut $scratch
    }
}

Describe 'transactional movement JSON serialization' {
    It 'contains only stable movement state codes' {
        Import-Module $script:JsonModule -Force
        $result = [pscustomobject]@{
            Succeeded = $false
            Code = 'destination_runtime_failed_rolled_back'
            State = 'source_restored'
            Format = 'v2'
            ProfileId = $null
            Path = $null
        }
        $jsonText = ConvertTo-NiniMoveJson -Result $result
        $json = $jsonText | ConvertFrom-Json
        Assert-JsonEnvelope $json 'move'
        $json.error.code | Should Be 'destination_runtime_failed_rolled_back'
        $json.error.details.state | Should Be 'source_restored'
        $json.error.details.format | Should Be 'v2'
        $jsonText | Should Not Match 'ProfileId|Path'
    }

    It 'serializes successful movement and direct success envelopes' {
        Import-Module $script:JsonModule -Force
        $move = [pscustomobject]@{ Succeeded = $true; Code = 'ok'; State = 'destination_active'; Format = 'legacy' }
        $json = (ConvertTo-NiniMoveJson -Result $move) | ConvertFrom-Json
        Assert-JsonEnvelope $json 'move'
        $json.ok | Should Be $true
        $json.data.code | Should Be 'ok'
        $json.data.state | Should Be 'destination_active'
        $json.data.format | Should Be 'legacy'

        $direct = (ConvertTo-NiniJsonSuccess -Command 'fixture' -Data ([ordered]@{ value = 7 })) | ConvertFrom-Json
        Assert-JsonEnvelope $direct 'fixture'
        $direct.data.value | Should Be 7
    }

    It 'serializes direct errors with and without details' {
        Import-Module $script:JsonModule -Force
        $without = (ConvertTo-NiniJsonError -Command 'fixture' -Code 'invalid_arguments' -Message 'Invalid.') | ConvertFrom-Json
        Assert-JsonEnvelope $without 'fixture'
        $without.ok | Should Be $false
        $without.error.code | Should Be 'invalid_arguments'
        ($without.error.PSObject.Properties.Name -contains 'details') | Should Be $false

        $with = (ConvertTo-NiniJsonEnvelope -Command 'fixture' -Succeeded $false -ErrorCode 'conflict' `
            -ErrorMessage 'Conflict.' -ErrorDetails ([ordered]@{ state = 'preserved' })) | ConvertFrom-Json
        $with.error.details.state | Should Be 'preserved'
    }
}
