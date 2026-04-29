#Requires -Version 5.1
<##
.SYNOPSIS
    InputSanitization.Tests.ps1

.DESCRIPTION
    Unit tests for configuration and path sanitization helpers.

.NOTES
    Gap addressed: Gap 1 - Input Sanitization Layer
    Date created: 2026-04-28
    #Requires -Version 5.1
##>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path $PSScriptRoot -Parent) '..\src\core\InputSanitization.ps1')

function Get-TestErrorMessage {
    param([Parameter(Mandatory)] [scriptblock] $ScriptBlock)

    try {
        & $ScriptBlock
    } catch {
        return $_.Exception.Message
    }

    throw 'Expected test scriptblock to throw, but it completed successfully.'
}

Describe 'Invoke-SanitizeConfigValue' {
    It 'valid value passes through unchanged' {
        $value = Invoke-SanitizeConfigValue -Value 'Valid_Value-01.log' -FieldName 'SampleField'
        $value | Should Be 'Valid_Value-01.log'
    }

    It 'value with injection characters throws expected error' {
        $message = Get-TestErrorMessage {
            Invoke-SanitizeConfigValue -Value 'bad;rm -rf' -FieldName 'DangerField' | Out-Null
        }

        $message | Should Match 'DangerField'
        $message | Should Match 'Invalid characters'
    }
}

Describe 'Invoke-SanitizeFilePath' {
    It 'path with traversal sequence throws expected error' {
        $message = Get-TestErrorMessage {
            Invoke-SanitizeFilePath -Path '..\temp\payload.txt' -FieldName 'ReportPath' | Out-Null
        }

        $message | Should Match 'ReportPath'
        $message | Should Match 'path traversal'
    }

    It 'path exceeding 260 chars throws expected error' {
        $longPath = ('C:\' + ('a' * 300) + '.txt')
        $message = Get-TestErrorMessage {
            Invoke-SanitizeFilePath -Path $longPath -FieldName 'OutputPath' | Out-Null
        }

        $message | Should Match 'OutputPath'
        $message | Should Match 'maximum supported length'
    }
}

Describe 'Invoke-SanitizeConfigObject' {
    It 'missing required key in config object throws expected error' {
        $config = @{ Name = 'endpoint-01' }

        $message = Get-TestErrorMessage {
            Invoke-SanitizeConfigObject -ConfigObject $config -RequiredKeys @('Name', 'ReportPath') | Out-Null
        }

        $message | Should Match 'ReportPath'
        $message | Should Match 'missing'
    }

    It 'all path keys are validated via Invoke-SanitizeFilePath' {
        $config = @{
            Name = 'node01'
            ReportPath = '..\bad\path.txt'
        }

        $message = Get-TestErrorMessage {
            Invoke-SanitizeConfigObject -ConfigObject $config -PathKeys @('ReportPath') | Out-Null
        }

        $message | Should Match 'ReportPath'
        $message | Should Match 'path traversal'
    }

    It 'non-path string keys are validated via Invoke-SanitizeConfigValue' {
        $config = @{
            Name = 'bad value with spaces'
            ReportPath = 'reports\baseline.md'
        }

        $message = Get-TestErrorMessage {
            Invoke-SanitizeConfigObject -ConfigObject $config -PathKeys @('ReportPath') | Out-Null
        }

        $message | Should Match 'Name'
        $message | Should Match 'Invalid characters'
    }
}
