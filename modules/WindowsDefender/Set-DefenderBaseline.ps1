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

if ($PSCmdlet.ShouldProcess('Windows Defender', 'Apply Defender baseline')) {
    try {
        Set-MpPreference @defenderArgs -ErrorAction Stop
        $results['DefenderPreferences'] = 'Applied'
    } catch {
        $results['DefenderPreferences'] = "Failed: $($_.Exception.Message)"
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
