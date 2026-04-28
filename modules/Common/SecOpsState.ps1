#Requires -Version 5.1

Set-StrictMode -Version Latest

$script:SecEditPolicyCache = $null

function Get-SecOpsRegValue {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )

    try {
        return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name
    } catch {
        return $Default
    }
}

function Get-SecOpsAuditPolicySubcategoryMap {
    return [ordered]@{
        AuditLogonEvents       = 'Logon'
        AuditAccountLogon      = 'Credential Validation'
        AuditPrivilegeUse      = 'Sensitive Privilege Use'
        AuditPolicyChange      = 'Audit Policy Change'
        AuditObjectAccess      = 'File System'
        AuditProcessTracking   = 'Process Creation'
        AuditSystemEvents      = 'Security State Change'
        AuditAccountManagement = 'User Account Management'
    }
}

function ConvertFrom-SecOpsAuditPolicyText {
    param([string] $Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return 'Unknown'
    }

    if ($Text -match 'Success\s+and\s+Failure') {
        return 'Success,Failure'
    }

    if ($Text -match 'No\s+Auditing') {
        return 'None'
    }

    $hasSuccess = $Text -match '(^|\W)Success($|\W)'
    $hasFailure = $Text -match '(^|\W)Failure($|\W)'

    if ($hasSuccess -and $hasFailure) {
        return 'Success,Failure'
    }

    if ($hasSuccess) {
        return 'Success'
    }

    if ($hasFailure) {
        return 'Failure'
    }

    return 'Unknown'
}

function Get-SecOpsAuditPolicySetting {
    param([Parameter(Mandatory)] [string] $Subcategory)

    $output = & auditpol.exe /get /subcategory:"$Subcategory" 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "auditpol.exe failed for subcategory '$Subcategory'."
    }

    $text = ($output -join [Environment]::NewLine)
    return (ConvertFrom-SecOpsAuditPolicyText -Text $text)
}

function Get-SecOpsAuditPoliciesState {
    $state = [ordered]@{}
    $map = Get-SecOpsAuditPolicySubcategoryMap

    foreach ($property in $map.Keys) {
        $state[$property] = Get-SecOpsAuditPolicySetting -Subcategory $map[$property]
    }

    return $state
}

function Get-SecOpsFirewallProfileState {
    param([Parameter(Mandatory)] [string] $ProfileName)

    $profile = Get-NetFirewallProfile -Profile $ProfileName -ErrorAction Stop

    return [ordered]@{
        Enabled               = [bool] $profile.Enabled
        DefaultInboundAction  = $profile.DefaultInboundAction.ToString()
        DefaultOutboundAction = $profile.DefaultOutboundAction.ToString()
        NotifyOnBlock         = [bool] $profile.NotifyOnListen
        LogAllowed            = [bool] ($profile.LogAllowed -eq 'True')
        LogBlocked            = [bool] ($profile.LogBlocked -eq 'True')
        LogMaxSizeKilobytes   = [int] $profile.LogMaxSizeKilobytes
    }
}

function Get-SecOpsFirewallStates {
    param([string[]] $Profiles = @('Domain', 'Private', 'Public'))

    $state = [ordered]@{}

    foreach ($profileName in $Profiles) {
        $state[$profileName] = Get-SecOpsFirewallProfileState -ProfileName $profileName
    }

    return $state
}

function ConvertTo-SecOpsFirewallBaseline {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $FirewallStates,
        [string[]] $Profiles = @('Domain', 'Private', 'Public')
    )

    $referenceProfile = $null
    foreach ($profileName in $Profiles) {
        if ($FirewallStates.Contains($profileName)) {
            $referenceProfile = $profileName
            break
        }
    }

    if (-not $referenceProfile) {
        throw 'No firewall profiles were available to build the baseline snapshot.'
    }

    $referenceState = $FirewallStates[$referenceProfile]

    return [ordered]@{
        Profiles              = @($Profiles)
        DefaultInboundAction  = $referenceState.DefaultInboundAction
        DefaultOutboundAction = $referenceState.DefaultOutboundAction
        NotifyOnBlock         = [bool] $referenceState.NotifyOnBlock
        LogAllowed            = [bool] $referenceState.LogAllowed
        LogBlocked            = [bool] $referenceState.LogBlocked
        LogMaxSizeKilobytes   = [int] $referenceState.LogMaxSizeKilobytes
    }
}

function Get-SecOpsSecurityPolicyMap {
    if ($null -ne $script:SecEditPolicyCache) {
        return $script:SecEditPolicyCache
    }

    do {
        $tempName = [System.IO.Path]::GetRandomFileName().Replace('.', '')
        $tempPath = Join-Path $env:TEMP ("secedit-export-{0}.cfg" -f $tempName)
        $reserved = New-Item -Path $tempPath -ItemType File -ErrorAction SilentlyContinue
    } until ($reserved)

    try {
        & secedit.exe /export /cfg $tempPath /quiet | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tempPath)) {
            throw 'secedit.exe export failed.'
        }

        $policyMap = @{}
        foreach ($line in (Get-Content -Path $tempPath -ErrorAction Stop)) {
            if ($line -match '^\s*([^=]+?)\s*=\s*(.*?)\s*$') {
                $policyMap[$matches[1].Trim()] = $matches[2].Trim()
            }
        }

        $script:SecEditPolicyCache = $policyMap
        return $script:SecEditPolicyCache
    } finally {
        if (Test-Path $tempPath) {
            Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-SecOpsBuiltInAccountDisabled {
    param([Parameter(Mandatory)] [string] $SidSuffix)

    $account = Get-LocalUser | Where-Object { $_.SID.Value -like "*-$SidSuffix" } | Select-Object -First 1
    if (-not $account) {
        return $null
    }

    return (-not [bool] $account.Enabled)
}

function Get-SecOpsUserAccountsState {
    $policies = Get-SecOpsSecurityPolicyMap

    return [ordered]@{
        DisableBuiltInAdministrator = Get-SecOpsBuiltInAccountDisabled -SidSuffix '500'
        DisableBuiltInGuest         = Get-SecOpsBuiltInAccountDisabled -SidSuffix '501'
        MaxPasswordAge              = [int] $policies['MaximumPasswordAge']
        MinPasswordLength           = [int] $policies['MinimumPasswordLength']
        PasswordComplexity          = ([int] $policies['PasswordComplexity'] -eq 1)
        LockoutThreshold            = [int] $policies['LockoutBadCount']
        LockoutDuration             = [int] $policies['LockoutDuration']
        LockoutObservationWindow    = [int] $policies['ResetLockoutCount']
    }
}

function ConvertTo-SecOpsCloudBlockLevel {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    switch ($Value.ToString()) {
        '0'           { return 'Default' }
        '1'           { return 'Moderate' }
        '2'           { return 'High' }
        '4'           { return 'HighPlus' }
        '6'           { return 'ZeroTolerance' }
        'Default'     { return 'Default' }
        'Moderate'    { return 'Moderate' }
        'High'        { return 'High' }
        'HighPlus'    { return 'HighPlus' }
        'ZeroTolerance' { return 'ZeroTolerance' }
        default       { return $Value.ToString() }
    }
}

function Get-SecOpsWindowsDefenderState {
    $preference = $null
    try {
        $preference = Get-MpPreference -ErrorAction Stop
    } catch {
        return [ordered]@{
            EnableRealTimeMonitoring     = $null
            EnableCloudProtection        = $null
            CloudBlockLevel              = $null
            EnableTamperProtection       = $null
            EnableNetworkProtection      = $null
            PUAProtection                = $null
            EnableControlledFolderAccess = $null
        }
    }

    $controlledFolderValue = $preference.EnableControlledFolderAccess
    $controlledFolderEnabled = $false
    if ($null -ne $controlledFolderValue) {
        $controlledFolderEnabled = @('1', 'Enabled') -contains $controlledFolderValue.ToString()
    }

    return [ordered]@{
        EnableRealTimeMonitoring     = (-not [bool] $preference.DisableRealtimeMonitoring)
        EnableCloudProtection        = ($preference.MAPSReporting -gt 0)
        CloudBlockLevel              = ConvertTo-SecOpsCloudBlockLevel -Value $preference.CloudBlockLevel
        EnableTamperProtection       = ((Get-SecOpsRegValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' -Name 'TamperProtection' -Default 0) -eq 5)
        EnableNetworkProtection      = ($preference.EnableNetworkProtection.ToString() -eq '1')
        PUAProtection                = [int] $preference.PUAProtection
        EnableControlledFolderAccess = $controlledFolderEnabled
    }
}

function Test-SecOpsLegacyProtocolDisabled {
    param(
        [Parameter(Mandatory)] [string] $Protocol,
        [Parameter(Mandatory)] [string] $Role
    )

    $path = Join-Path "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$Protocol" $Role
    $enabled = Get-SecOpsRegValue -Path $path -Name 'Enabled' -Default $null
    $disabledByDefault = Get-SecOpsRegValue -Path $path -Name 'DisabledByDefault' -Default $null

    return (($enabled -eq 0) -and ($disabledByDefault -eq 1))
}

function Test-SecOpsAllNetBiosDisabled {
    $interfaces = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' -ErrorAction SilentlyContinue
    if (-not $interfaces) {
        return $false
    }

    foreach ($interface in $interfaces) {
        $value = Get-SecOpsRegValue -Path $interface.PSPath -Name 'NetbiosOptions' -Default $null
        if ($value -ne 2) {
            return $false
        }
    }

    return $true
}

function Get-SecOpsNetworkHardeningState {
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='WinHttpAutoProxySvc'" -ErrorAction SilentlyContinue
    $lmCompatibilityLevel = Get-SecOpsRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LmCompatibilityLevel' -Default 0

    $legacyProtocolsDisabled = $true
    foreach ($protocol in @('TLS 1.0', 'TLS 1.1', 'SSL 2.0', 'SSL 3.0')) {
        foreach ($role in @('Client', 'Server')) {
            if (-not (Test-SecOpsLegacyProtocolDisabled -Protocol $protocol -Role $role)) {
                $legacyProtocolsDisabled = $false
                break
            }
        }

        if (-not $legacyProtocolsDisabled) {
            break
        }
    }

    $rc4Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Ciphers\RC4 128/128'
    $rc4Enabled = Get-SecOpsRegValue -Path $rc4Path -Name 'Enabled' -Default $null
    $rc4DisabledByDefault = Get-SecOpsRegValue -Path $rc4Path -Name 'DisabledByDefault' -Default $null
    $minimumTlsVersion = 'LegacyEnabled'
    if ($legacyProtocolsDisabled) {
        $minimumTlsVersion = '1.2'
    }

    return [ordered]@{
        DisableSMBv1      = (-not ([bool] (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol))
        DisableLLMNR      = ((Get-SecOpsRegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast' -Default $null) -eq 0)
        DisableNetBIOS    = Test-SecOpsAllNetBiosDisabled
        DisableWPAD       = ($service -and $service.StartMode -eq 'Disabled')
        MinimumTLSVersion = $minimumTlsVersion
        DisableRC4        = (($rc4Enabled -eq 0) -and ($rc4DisabledByDefault -eq 1))
        DisableNTLMv1     = ([int] $lmCompatibilityLevel -ge 3)
    }
}

function Get-SecOpsBitLockerState {
    $volume = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
    $tpm = Get-Tpm -ErrorAction SilentlyContinue
    $tpmPresent = $false
    $tpmEnabled = $false

    if ($tpm) {
        $tpmPresent = [bool] $tpm.TpmPresent
        $tpmEnabled = [bool] $tpm.TpmEnabled
    }

    if (-not $volume) {
        return [ordered]@{
            SystemDriveEncrypted = $false
            EncryptionMethod     = 'Unknown'
            ProtectionStatus     = 'Unknown'
            TpmPresent           = $tpmPresent
            TpmEnabled           = $tpmEnabled
        }
    }

    return [ordered]@{
        SystemDriveEncrypted = ($volume.ProtectionStatus -eq 'On')
        EncryptionMethod     = $volume.EncryptionMethod.ToString()
        ProtectionStatus     = $volume.ProtectionStatus.ToString()
        TpmPresent           = $tpmPresent
        TpmEnabled           = $tpmEnabled
    }
}

function Get-SecOpsSecureBootState {
    $secureBootEnabled = $false
    try {
        $secureBootEnabled = Confirm-SecureBootUEFI -ErrorAction Stop
    } catch {
        $secureBootEnabled = $false
    }

    $firmwareType = Get-SecOpsRegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -Default 0

    return [ordered]@{
        SecureBootEnabled = [bool] $secureBootEnabled
        UefiMode          = ($firmwareType -eq 2)
    }
}

function Get-SecOpsWindowsUpdateState {
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='wuauserv'" -ErrorAction SilentlyContinue
    $latestHotFix = $null

    try {
        $latestHotFix = Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 1
    } catch {
        $latestHotFix = $null
    }

    $latestInstalledOn = $null
    if ($latestHotFix -and $latestHotFix.InstalledOn) {
        try {
            $latestInstalledOn = [datetime] $latestHotFix.InstalledOn
        } catch {
            $latestInstalledOn = $null
        }
    }

    $servicePresent = [bool] $service
    $startMode = 'Unknown'
    $state = 'Unknown'
    if ($service) {
        $startMode = $service.StartMode
        $state = $service.State
    }

    $updatesCurrent = $false
    if ($latestInstalledOn) {
        $updatesCurrent = ($latestInstalledOn -ge (Get-Date).AddDays(-35))
    }

    return [ordered]@{
        ServicePresent         = $servicePresent
        StartMode              = $startMode
        State                  = $state
        LatestInstalledUpdate  = $latestInstalledOn
        UpdatesCurrent         = $updatesCurrent
    }
}

function Get-SecOpsListeningPorts {
    $listeners = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') } |
        Sort-Object LocalPort -Unique

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($listener in $listeners) {
        $processName = 'Unknown'
        try {
            $processName = (Get-Process -Id $listener.OwningProcess -ErrorAction Stop).ProcessName
        } catch {
            $processName = 'Unknown'
        }

        $results.Add([PSCustomObject]@{
            LocalAddress  = $listener.LocalAddress
            LocalPort     = $listener.LocalPort
            OwningProcess = $listener.OwningProcess
            ProcessName   = $processName
        })
    }

    return $results
}

function Get-SecOpsBaselineSnapshot {
    param([Parameter(Mandatory)] [PSCustomObject] $Baseline)

    $firewallStates = Get-SecOpsFirewallStates -Profiles $Baseline.Firewall.Profiles

    return [ordered]@{
        AuditPolicies    = Get-SecOpsAuditPoliciesState
        Firewall         = ConvertTo-SecOpsFirewallBaseline -FirewallStates $firewallStates -Profiles $Baseline.Firewall.Profiles
        UserAccounts     = Get-SecOpsUserAccountsState
        WindowsDefender  = Get-SecOpsWindowsDefenderState
        NetworkHardening = Get-SecOpsNetworkHardeningState
    }
}
