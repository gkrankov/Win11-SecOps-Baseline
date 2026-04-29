<#
.SYNOPSIS
    Configures Windows Firewall baseline settings per CIS Benchmark for Windows 11.
.PARAMETER Config
    The parsed baseline.json configuration object.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)] [PSCustomObject] $Config
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$settings = $Config.Firewall
$results  = @{}

foreach ($profile in $settings.Profiles) {
    if ($profile -notin @('Domain', 'Private', 'Public')) {
        $results[$profile] = 'Skipped: Invalid firewall profile name'
        continue
    }

    if ($PSCmdlet.ShouldProcess($profile, 'Apply firewall baseline')) {
        $notifyOnListen = 'False'
        if ([bool] $settings.NotifyOnBlock) {
            $notifyOnListen = 'True'
        }

        $logAllowed = 'False'
        if ([bool] $settings.LogAllowed) {
            $logAllowed = 'True'
        }

        $logBlocked = 'False'
        if ([bool] $settings.LogBlocked) {
            $logBlocked = 'True'
        }

        try {
            Set-NetFirewallProfile -Profile $profile `
                -DefaultInboundAction  $settings.DefaultInboundAction `
                -DefaultOutboundAction $settings.DefaultOutboundAction `
                -NotifyOnListen        $notifyOnListen `
                -LogAllowed            $logAllowed `
                -LogBlocked            $logBlocked `
                -LogMaxSizeKilobytes   $settings.LogMaxSizeKilobytes `
                -ErrorAction Stop

            $results[$profile] = 'Applied'
        } catch {
            $results[$profile] = "Failed: $($_.Exception.Message)"
            throw
        }
    } else {
        $results[$profile] = 'WhatIf'
    }
}

return $results
