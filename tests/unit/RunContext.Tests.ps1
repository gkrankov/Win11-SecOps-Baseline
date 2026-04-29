#Requires -Version 5.1
<##
.SYNOPSIS
    RunContext.Tests.ps1

.DESCRIPTION
    Unit tests for run context generation and environment-scoped run identifier access.

.NOTES
    Gap addressed: Gap 3 - Run Identifier Scope
    Date created: 2026-04-28
    #Requires -Version 5.1
##>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) '..\src\core\RunContext.ps1')
}

Describe 'New-SecOpsRunContext' {
    It 'returns hashtable with all required keys' {
        Clear-SecOpsRunContext
        $context = New-SecOpsRunContext

        ($context.ContainsKey('RunId')) | Should Be $true
        ($context.ContainsKey('StartTime')) | Should Be $true
        ($context.ContainsKey('Hostname')) | Should Be $true
        ($context.ContainsKey('Username')) | Should Be $true
        ($context.ContainsKey('PSVersion')) | Should Be $true
        ($context.ContainsKey('RunBy')) | Should Be $true
    }

    It 'RunId is exactly 8 characters and uppercase alphanumeric' {
        Clear-SecOpsRunContext
        $context = New-SecOpsRunContext

        $context.RunId.Length | Should Be 8
        ($context.RunId -match '^[A-Z0-9]{8}$') | Should Be $true
    }

    It 'sets SECOPS_RUN_ID environment variable' {
        Clear-SecOpsRunContext
        $context = New-SecOpsRunContext

        $env:SECOPS_RUN_ID | Should Be $context.RunId
    }

    It 'two sequential calls produce different RunIds' {
        Clear-SecOpsRunContext
        $first = (New-SecOpsRunContext).RunId
        $second = (New-SecOpsRunContext).RunId

        ($first -ne $second) | Should Be $true
    }
}

Describe 'Get-SecOpsRunId' {
    It 'returns correct value when env var is set' {
        $env:SECOPS_RUN_ID = 'ABC12345'
        (Get-SecOpsRunId) | Should Be 'ABC12345'
    }

    It 'returns UNTRACKED when env var is missing' {
        Clear-SecOpsRunContext
        (Get-SecOpsRunId) | Should Be 'UNTRACKED'
    }
}

Describe 'Clear-SecOpsRunContext' {
    It 'removes SECOPS_RUN_ID environment variable' {
        $env:SECOPS_RUN_ID = 'ZZZZ9999'
        Clear-SecOpsRunContext
        [string]::IsNullOrWhiteSpace($env:SECOPS_RUN_ID) | Should Be $true
    }
}
