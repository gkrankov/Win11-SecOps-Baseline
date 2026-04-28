<#
.SYNOPSIS
    Hardens local user accounts and password policy per CIS Benchmark for Windows 11.
.PARAMETER Config
    The parsed baseline.json configuration object.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)] [PSCustomObject] $Config
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$settings = $Config.UserAccounts
$results  = @{}

function ConvertTo-ValidatedInt {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)] [int] $Min,
        [Parameter(Mandatory)] [int] $Max
    )

    $parsed = 0
    if (-not [int]::TryParse([string]$Value, [ref]$parsed)) {
        throw "$Name must be an integer. Value: '$Value'."
    }

    if ($parsed -lt $Min -or $parsed -gt $Max) {
        throw "$Name must be between $Min and $Max. Value: $parsed."
    }

    return $parsed
}

# Password and lockout policy via net accounts
if ($PSCmdlet.ShouldProcess('Password Policy', 'Apply net accounts settings')) {
    try {
        $maxPasswordAge = ConvertTo-ValidatedInt -Name 'MaxPasswordAge' -Value $settings.MaxPasswordAge -Min 1 -Max 999
        $minPasswordLength = ConvertTo-ValidatedInt -Name 'MinPasswordLength' -Value $settings.MinPasswordLength -Min 1 -Max 128
        $lockoutThreshold = ConvertTo-ValidatedInt -Name 'LockoutThreshold' -Value $settings.LockoutThreshold -Min 0 -Max 999
        $lockoutDuration = ConvertTo-ValidatedInt -Name 'LockoutDuration' -Value $settings.LockoutDuration -Min 0 -Max 99999
        $lockoutWindow = ConvertTo-ValidatedInt -Name 'LockoutObservationWindow' -Value $settings.LockoutObservationWindow -Min 0 -Max 99999

        $netOutput = & net.exe accounts /maxpwage:$maxPasswordAge `
                                     /minpwlen:$minPasswordLength `
                                     /lockoutthreshold:$lockoutThreshold `
                                     /lockoutduration:$lockoutDuration `
                                     /lockoutwindow:$lockoutWindow 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "net accounts failed with exit code $LASTEXITCODE. Output: $($netOutput -join ' ')"
        }

        $results['PasswordPolicy'] = 'Applied'
    } catch {
        $results['PasswordPolicy'] = "Failed: $($_.Exception.Message)"
        throw
    }
}

# Disable built-in Administrator
if ($settings.DisableBuiltInAdministrator) {
    $adminAccount = Get-LocalUser | Where-Object { $_.SID -like 'S-1-5-*-500' }
    if ($adminAccount -and $adminAccount.Enabled) {
        if ($PSCmdlet.ShouldProcess($adminAccount.Name, 'Disable built-in Administrator')) {
            try {
                Disable-LocalUser -Name $adminAccount.Name -ErrorAction Stop
                $results['BuiltInAdministrator'] = 'Disabled'
            } catch {
                $results['BuiltInAdministrator'] = "Failed: $($_.Exception.Message)"
                throw
            }
        }
    } else {
        $results['BuiltInAdministrator'] = 'Already disabled'
    }
}

# Disable built-in Guest
if ($settings.DisableBuiltInGuest) {
    $guestAccount = Get-LocalUser | Where-Object { $_.SID -like 'S-1-5-*-501' }
    if ($guestAccount -and $guestAccount.Enabled) {
        if ($PSCmdlet.ShouldProcess($guestAccount.Name, 'Disable built-in Guest')) {
            try {
                Disable-LocalUser -Name $guestAccount.Name -ErrorAction Stop
                $results['BuiltInGuest'] = 'Disabled'
            } catch {
                $results['BuiltInGuest'] = "Failed: $($_.Exception.Message)"
                throw
            }
        }
    } else {
        $results['BuiltInGuest'] = 'Already disabled'
    }
}

return $results
