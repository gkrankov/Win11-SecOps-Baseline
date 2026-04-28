#Requires -Version 5.1
<##
.SYNOPSIS
    RunContext.ps1

.DESCRIPTION
    Provides per-run context creation and shared run identifier access across modules.

.NOTES
    Gap addressed: Gap 3 - Run Identifier Scope
    Date created: 2026-04-28
    #Requires -Version 5.1
##>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-SecOpsRunContext {
    [CmdletBinding()]
    param()

    $runId = ([System.Guid]::NewGuid().ToString('N').Substring(0, 8)).ToUpperInvariant()
    $env:SECOPS_RUN_ID = $runId

    return @{
        RunId = $runId
        StartTime = Get-Date
        Hostname = $env:COMPUTERNAME
        Username = $env:USERNAME
        PSVersion = $PSVersionTable.PSVersion.ToString()
        RunBy = 'SecOps-Baseline'
    }
}

function Get-SecOpsRunId {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($env:SECOPS_RUN_ID)) {
        return 'UNTRACKED'
    }

    return $env:SECOPS_RUN_ID
}

function Clear-SecOpsRunContext {
    [CmdletBinding()]
    param()

    Remove-Item -Path Env:SECOPS_RUN_ID -ErrorAction SilentlyContinue
}
