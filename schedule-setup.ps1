#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch] $Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TaskPath = '\Win11-SecOps-Baseline\'
$script:TaskNames = @(
    'Weekly-Hardening-Check',
    'Daily-Posture-Scan',
    'Drift-Detection-4Hourly',
    'Monthly-Full-Report'
)

function Write-Status {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string] $Level = 'INFO'
    )

    switch ($Level) {
        'SUCCESS' { Write-Host $Message -ForegroundColor Green }
        'WARNING' { Write-Host $Message -ForegroundColor Yellow }
        'ERROR'   { Write-Host $Message -ForegroundColor Red }
        default   { Write-Host $Message }
    }
}

function Get-ProjectRoot {
    return (Resolve-Path -Path $PSScriptRoot -ErrorAction Stop).Path
}

function Get-RequiredScriptPath {
    param([Parameter(Mandatory)] [string] $RelativePath)

    $fullPath = Join-Path (Get-ProjectRoot) $RelativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Required script was not found: $fullPath"
    }

    return (Resolve-Path -LiteralPath $fullPath -ErrorAction Stop).Path
}

function New-FileAction {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [string[]] $AdditionalArguments = @()
    )

    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $ScriptPath)
    ) + $AdditionalArguments

    $argumentLine = (
        $arguments | ForEach-Object {
            if ($_ -match '\s' -and $_ -notmatch '^".*"$') {
                '"{0}"' -f $_
            } else {
                $_
            }
        }
    ) -join ' '

    return New-ScheduledTaskAction -Execute $powerShellExe -Argument $argumentLine
}

function New-CommandAction {
    param([Parameter(Mandatory)] [string] $CommandText)

    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-Command', ('"{0}"' -f $CommandText)
    ) -join ' '

    return New-ScheduledTaskAction -Execute $powerShellExe -Argument $arguments
}

function Remove-Win11SecOpsTasks {
    foreach ($name in $script:TaskNames) {
        $existing = Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $name -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $name -Confirm:$false -ErrorAction Stop
            Write-Status ("Removed task: {0}{1}" -f $script:TaskPath, $name) -Level SUCCESS
        } else {
            Write-Status ("Task not found (already removed): {0}{1}" -f $script:TaskPath, $name) -Level INFO
        }
    }
}

function Register-OrReplaceTask {
    param(
        [Parameter(Mandatory)] [string] $TaskName,
        [Parameter(Mandatory)] [Microsoft.Management.Infrastructure.CimInstance] $Action,
        [Parameter(Mandatory)] [Microsoft.Management.Infrastructure.CimInstance] $Trigger,
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [Microsoft.Management.Infrastructure.CimInstance] $Principal,
        [Parameter(Mandatory)] [Microsoft.Management.Infrastructure.CimInstance] $Settings
    )

    $existing = Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    }

    Register-ScheduledTask \
        -TaskPath $script:TaskPath \
        -TaskName $TaskName \
        -Description $Description \
        -Action $Action \
        -Trigger $Trigger \
        -Principal $Principal \
        -Settings $Settings \
        -ErrorAction Stop | Out-Null

    Write-Status ("Registered task: {0}{1}" -f $script:TaskPath, $TaskName) -Level SUCCESS
}

$hardeningScript = Get-RequiredScriptPath -RelativePath 'Invoke-SecBaseline.ps1'
$postureScript = Get-RequiredScriptPath -RelativePath '02-posture-check.ps1'
$driftScript = Get-RequiredScriptPath -RelativePath '03-drift-detector.ps1'
$dashboardScript = Get-RequiredScriptPath -RelativePath '05-dashboard-export.ps1'
$checkpointScript = Get-RequiredScriptPath -RelativePath 'Get-SecurityCheckpoint.ps1'

if ($Uninstall) {
    Remove-Win11SecOpsTasks
    Write-Status 'Uninstall completed. All Win11-SecOps-Baseline scheduled tasks were removed.' -Level SUCCESS
    return
}

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet \
    -StartWhenAvailable \
    -AllowStartIfOnBatteries \
    -DontStopIfGoingOnBatteries \
    -MultipleInstances IgnoreNew \
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)

$weeklyHardeningAction = New-FileAction -ScriptPath $hardeningScript -AdditionalArguments @('-WhatIf')
$weeklyHardeningTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 9:00AM
Register-OrReplaceTask \
    -TaskName 'Weekly-Hardening-Check' \
    -Action $weeklyHardeningAction \
    -Trigger $weeklyHardeningTrigger \
    -Description 'Weekly hardening check for Win11-SecOps-Baseline (Sunday 9:00 AM).' \
    -Principal $principal \
    -Settings $settings

$dailyPostureAction = New-FileAction -ScriptPath $postureScript
$dailyPostureTrigger = New-ScheduledTaskTrigger -Daily -At 8:00AM
Register-OrReplaceTask \
    -TaskName 'Daily-Posture-Scan' \
    -Action $dailyPostureAction \
    -Trigger $dailyPostureTrigger \
    -Description 'Daily posture scan for Win11-SecOps-Baseline (8:00 AM).' \
    -Principal $principal \
    -Settings $settings

$driftAction = New-FileAction -ScriptPath $driftScript
$driftTrigger = New-ScheduledTaskTrigger -Daily -At 12:00AM
$driftTrigger.Repetition.Interval = 'PT4H'
$driftTrigger.Repetition.Duration = 'P1D'
Register-OrReplaceTask \
    -TaskName 'Drift-Detection-4Hourly' \
    -Action $driftAction \
    -Trigger $driftTrigger \
    -Description 'Real-time drift detection every 4 hours.' \
    -Principal $principal \
    -Settings $settings

$monthlyCommand = @(
    "& '$postureScript'",
    "& '$driftScript'",
    "& '$dashboardScript' -NoOpen",
    "& '$checkpointScript'"
) -join '; '
$monthlyAction = New-CommandAction -CommandText $monthlyCommand
$monthlyTrigger = New-ScheduledTaskTrigger -Monthly -DaysOfMonth 1 -At 7:00AM
Register-OrReplaceTask \
    -TaskName 'Monthly-Full-Report' \
    -Action $monthlyAction \
    -Trigger $monthlyTrigger \
    -Description 'Monthly full report generation on day 1 of each month at 7:00 AM.' \
    -Principal $principal \
    -Settings $settings

Write-Status 'Schedule setup completed successfully.' -Level SUCCESS
