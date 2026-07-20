$script:CredentialStoreModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\MultiCli.CredentialStore.psm1'
Import-Module $script:CredentialStoreModule -Force

Describe 'Windows profile credential storage' {
    It 'round-trips and removes a profile secret without writing a plaintext file' {
        $target = 'multi-cli/tests/' + [guid]::NewGuid().ToString('N')
        $secret = 'mcli-test-secret-' + [guid]::NewGuid().ToString('N')
        try {
            Set-MultiCliCredential -Target $target -Secret $secret
            (Test-MultiCliCredential -Target $target) | Should Be $true
            (Get-MultiCliCredential -Target $target) | Should Be $secret
            $probeFile = Join-Path $env:TEMP ("mcli-credential-probe-" + [guid]::NewGuid().ToString('N') + '.txt')
            Set-Content -LiteralPath $probeFile -Value 'non-secret-marker' -Encoding ASCII
            try {
                (Select-String -LiteralPath $probeFile -SimpleMatch $secret -Quiet) | Should Be $false
            } finally {
                Remove-Item -LiteralPath $probeFile -Force -ErrorAction SilentlyContinue
            }
        } finally {
            Remove-MultiCliCredential -Target $target | Out-Null
        }
        (Test-MultiCliCredential -Target $target) | Should Be $false
    }

    It 'rejects empty secrets' {
        { Set-MultiCliCredential -Target ('multi-cli/tests/' + [guid]::NewGuid().ToString('N')) -Secret '' } | Should Throw
    }
}
