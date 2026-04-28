<#
.SYNOPSIS
    Disables legacy network protocols and enforces modern TLS for Windows 11.
.PARAMETER Config
    The parsed baseline.json configuration object.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)] [PSCustomObject] $Config
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$settings = $Config.NetworkHardening
$results  = @{}

# Disable SMBv1
if ($settings.DisableSMBv1) {
    if ($PSCmdlet.ShouldProcess('SMBv1', 'Disable')) {
        try {
            Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
            $results['SMBv1'] = 'Disabled'
        } catch {
            $results['SMBv1'] = "Failed: $($_.Exception.Message)"
            throw
        }
    } else { $results['SMBv1'] = 'WhatIf' }
}

# Disable LLMNR via registry
if ($settings.DisableLLMNR) {
    $llmnrPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'
    if ($PSCmdlet.ShouldProcess('LLMNR', 'Disable')) {
        try {
            if (-not (Test-Path -LiteralPath $llmnrPath)) { New-Item -Path $llmnrPath -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $llmnrPath -Name 'EnableMulticast' -Value 0 -Type DWord -Force -ErrorAction Stop
            $results['LLMNR'] = 'Disabled'
        } catch {
            $results['LLMNR'] = "Failed: $($_.Exception.Message)"
            throw
        }
    } else { $results['LLMNR'] = 'WhatIf' }
}

# Disable NetBIOS over TCP/IP on all adapters
if ($settings.DisableNetBIOS) {
    if ($PSCmdlet.ShouldProcess('NetBIOS', 'Disable on all adapters')) {
        try {
            $adapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -ErrorAction Stop
            $failed = 0
            foreach ($adapter in $adapters) {
                $result = Invoke-CimMethod -InputObject $adapter -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = [uint32]2 } -ErrorAction Stop
                if ($result.ReturnValue -ne 0) {
                    $failed++
                }
            }

            if ($failed -gt 0) {
                $results['NetBIOS'] = "Partially applied ($failed adapter call(s) failed)"
            } else {
                $results['NetBIOS'] = 'Disabled'
            }
        } catch {
            $results['NetBIOS'] = "Failed: $($_.Exception.Message)"
            throw
        }
    } else { $results['NetBIOS'] = 'WhatIf' }
}

# Disable WPAD
if ($settings.DisableWPAD) {
    if ($PSCmdlet.ShouldProcess('WinHttpAutoProxySvc', 'Disable WPAD')) {
        try {
            Set-Service -Name WinHttpAutoProxySvc -StartupType Disabled -ErrorAction Stop
            $results['WPAD'] = 'Disabled'
        } catch {
            $results['WPAD'] = "Failed: $($_.Exception.Message)"
            throw
        }
    } else { $results['WPAD'] = 'WhatIf' }
}

# Enforce TLS 1.2+ (disable TLS 1.0 and 1.1)
if ($settings.MinimumTLSVersion -eq '1.2') {
    $tlsBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
    foreach ($version in @('TLS 1.0', 'TLS 1.1', 'SSL 2.0', 'SSL 3.0')) {
        foreach ($role in @('Client', 'Server')) {
            $path = "$tlsBase\$version\$role"
            if ($PSCmdlet.ShouldProcess("$version\$role", 'Disable legacy protocol')) {
                try {
                    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
                    Set-ItemProperty -Path $path -Name 'Enabled' -Value 0 -Type DWord -Force -ErrorAction Stop
                    Set-ItemProperty -Path $path -Name 'DisabledByDefault' -Value 1 -Type DWord -Force -ErrorAction Stop
                } catch {
                    $results["LegacyTLS-$version-$role"] = "Failed: $($_.Exception.Message)"
                    throw
                }
            }
        }
    }
    $results['LegacyTLS'] = if ($WhatIfPreference) { 'WhatIf' } else { 'Disabled' }
}

return $results
