<#
.SYNOPSIS
    Configures Windows Defender / Microsoft Defender Antivirus baseline for Windows 11.
.PARAMETER Config
    The parsed baseline.json configuration object.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)] [PSCustomObject] $Config
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$settings = $Config.WindowsDefender
$results  = @{}

function Get-DefenderServiceState {
    param([Parameter(Mandatory)] [string[]] $Names)

    $state = [ordered]@{}
    foreach ($name in $Names) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        $state[$name] = if ($svc) { $svc.Status.ToString() } else { 'NotFound' }
    }

    return $state
}

function Start-DefenderServicesIfNeeded {
    $serviceNames = @('WinDefend', 'WdNisSvc')

    foreach ($serviceName in $serviceNames) {
        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            continue
        }

        if ($svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
            try {
                Start-Service -Name $serviceName -ErrorAction Stop
            } catch {
                Write-Verbose "Failed to start service '$serviceName': $($_.Exception.Message)"
            }
        }
    }

    return (Get-DefenderServiceState -Names $serviceNames)
}

function Get-ActiveThirdPartyAvServices {
    $servicePatterns = @(
        'Sophos',
        'CrowdStrike',
        'Sentinel',
        'Trend Micro',
        'Symantec',
        'McAfee',
        'Kaspersky',
        'Bitdefender',
        'ESET',
        'Avast',
        'AVG'
    )

    $regexPattern = ($servicePatterns | ForEach-Object { [Regex]::Escape($_) }) -join '|'
    return @(Get-Service -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running -and
            ($_.Name -match $regexPattern -or $_.DisplayName -match $regexPattern)
        } |
        Select-Object -Property Name, DisplayName, Status)
}

$allowedCloudLevels = @('Default', 'Moderate', 'High', 'HighPlus', 'ZeroTolerance', 0, 1, 2, 4, 6)
if ($settings.CloudBlockLevel -notin $allowedCloudLevels) {
    throw "Unsupported CloudBlockLevel value: '$($settings.CloudBlockLevel)'"
}

$puaProtection = [int]$settings.PUAProtection
if ($puaProtection -notin @(0, 1, 2)) {
    throw "Unsupported PUAProtection value: '$puaProtection'"
}

$mapsReportingValue = 0
if ([bool] $settings.EnableCloudProtection) {
    $mapsReportingValue = 2
}

$networkProtectionValue = 0
if ([bool] $settings.EnableNetworkProtection) {
    $networkProtectionValue = 1
}

$controlledFolderAccessValue = 'Disabled'
if ([bool] $settings.EnableControlledFolderAccess) {
    $controlledFolderAccessValue = 'Enabled'
}

$defenderArgs = @{
    DisableRealtimeMonitoring          = -not [bool]$settings.EnableRealTimeMonitoring
    MAPSReporting                      = $mapsReportingValue
    CloudBlockLevel                    = $settings.CloudBlockLevel
    EnableNetworkProtection            = $networkProtectionValue
    PUAProtection                      = $puaProtection
    EnableControlledFolderAccess       = $controlledFolderAccessValue
}

$activeThirdPartyAv = Get-ActiveThirdPartyAvServices
if ($activeThirdPartyAv.Count -gt 0) {
    $serviceSummary = $activeThirdPartyAv | ForEach-Object { $_.DisplayName }
    $results['ThirdPartyAV'] = $serviceSummary
    $results['DefenderPreferences'] = 'Skipped'
    $results['TamperProtection'] = 'Skipped'
    $results['Message'] = 'Third-party AV is active; skipping Defender policy changes to avoid passive-mode failures.'
    return $results
}

if ($PSCmdlet.ShouldProcess('Windows Defender', 'Apply Defender baseline')) {
    $serviceState = Start-DefenderServicesIfNeeded
    $results['DefenderServices'] = $serviceState

    try {
        Set-MpPreference @defenderArgs -ErrorAction Stop
        $results['DefenderPreferences'] = 'Applied'
    } catch {
        $msg = $_.Exception.Message
        $results['DefenderPreferences'] = "Failed: $msg"
        if ($msg -match '0x800106ba') {
            $serviceStateText = ($serviceState.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join '; '
            throw "Set-MpPreference failed (0x800106ba). Defender service is unavailable or running in passive mode. Service state: $serviceStateText. If a third-party AV is installed, remove it or disable passive mode; then rerun baseline as Administrator."
        }

        throw
    }
} else {
    $results['DefenderPreferences'] = 'WhatIf'
}

# Tamper Protection requires registry (cannot be set via Set-MpPreference in all contexts)
if ($settings.EnableTamperProtection) {
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features'
    if ($PSCmdlet.ShouldProcess($regPath, 'Enable TamperProtection')) {
        try {
            if (-not (Test-Path -LiteralPath $regPath)) {
                throw "Registry path not found: $regPath"
            }

            Set-ItemProperty -Path $regPath -Name 'TamperProtection' -Value 5 -Type DWord -Force -ErrorAction Stop
            $results['TamperProtection'] = 'Enabled'
        } catch {
            $results['TamperProtection'] = "Failed: $($_.Exception.Message)"
            throw
        }
    } else {
        $results['TamperProtection'] = 'WhatIf'
    }
}

return $results
