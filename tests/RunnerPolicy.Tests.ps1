. (Join-Path $PSScriptRoot 'helpers\pester-policy.ps1')

Describe 'test runner result policy' {
    It 'accepts only passing runs and the documented platform skips: <Label>' -TestCases @(
        @{ Label = 'passed'; Status = 'Passed'; Name = 'ordinary'; Accepted = $true },
        @{ Label = 'documented skip'; Status = 'Skipped'; Name = 'fails precisely BEFORE creating anything when not elevated'; Accepted = $true },
        @{ Label = 'unexpected skip'; Status = 'Skipped'; Name = 'ordinary'; Accepted = $false },
        @{ Label = 'pending'; Status = 'Pending'; Name = 'ordinary'; Accepted = $false },
        @{ Label = 'inconclusive'; Status = 'Inconclusive'; Name = 'ordinary'; Accepted = $false },
        @{ Label = 'failed platform test'; Status = 'Failed'; Name = 'fails precisely BEFORE creating anything when not elevated'; Accepted = $false }
    ) {
        param($Label, $Status, $Name, $Accepted)
        $result = [pscustomobject]@{
            TotalCount = 2; PassedCount = 1; FailedCount = [int]($Status -eq 'Failed')
            TestResult = @([pscustomobject]@{ Name = $Name; Result = $Status })
        }
        (Get-PesterRunPolicy -Result $result).passed | Should Be $Accepted
    }

    It 'rejects a run without any executed passing test' {
        $result = [pscustomobject]@{ TotalCount = 0; PassedCount = 0; FailedCount = 0; TestResult = @() }
        (Get-PesterRunPolicy -Result $result).passed | Should Be $false
        $result.TotalCount = 1
        $result.TestResult = @([pscustomobject]@{
            Name = 'fails precisely BEFORE creating anything when not elevated'; Result = 'Skipped'
        })
        (Get-PesterRunPolicy -Result $result).passed | Should Be $false
    }
}
