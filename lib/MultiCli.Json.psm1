Set-StrictMode -Version Latest

function ConvertTo-NiniJsonEnvelope {
    param(
        [string]$Command,
        [bool]$Succeeded,
        $Data,
        [string]$ErrorCode,
        [string]$ErrorMessage,
        $ErrorDetails
    )
    $errorObject = $null
    if (-not $Succeeded) {
        $errorObject = [ordered]@{
            code = $ErrorCode
            message = $ErrorMessage
        }
        if ($null -ne $ErrorDetails) { $errorObject['details'] = $ErrorDetails }
    }
    return ([ordered]@{
        schemaVersion = 1
        command = $Command
        ok = $Succeeded
        data = $(if ($Succeeded) { $Data } else { $null })
        error = $errorObject
    } | ConvertTo-Json -Compress -Depth 12)
}

function ConvertTo-NiniJsonSuccess {
    param([string]$Command, $Data)
    ConvertTo-NiniJsonEnvelope -Command $Command -Succeeded $true -Data $Data
}

function ConvertTo-NiniJsonError {
    param([string]$Command, [string]$Code, [string]$Message, $Details)
    ConvertTo-NiniJsonEnvelope -Command $Command -Succeeded $false -ErrorCode $Code -ErrorMessage $Message -ErrorDetails $Details
}

function ConvertTo-NiniMoveJson {
    param($Result)
    $details = [ordered]@{
        state = [string]$Result.State
        format = [string]$Result.Format
    }
    if ([bool]$Result.Succeeded) {
        return ConvertTo-NiniJsonSuccess -Command 'move' -Data ([ordered]@{
            code = [string]$Result.Code
            state = $details.state
            format = $details.format
        })
    }
    return ConvertTo-NiniJsonError -Command 'move' -Code ([string]$Result.Code) `
        -Message 'The profile movement did not complete.' -Details $details
}

Export-ModuleMember -Function ConvertTo-NiniJsonEnvelope, ConvertTo-NiniJsonSuccess, ConvertTo-NiniJsonError, ConvertTo-NiniMoveJson
