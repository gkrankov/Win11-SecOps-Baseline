#Requires -Version 5.1
<#
.SYNOPSIS
    Hardens a Windows 11 machine by applying a curated set of security controls.

.DESCRIPTION
    Applies the following controls in order:
      1.  Administrator check
      2.  System Restore Point
      3.  Disable SMB1
      4.  Enforce NTLMv2-only authentication
      5.  Enable SMB signing (client + server)
      6.  Disable PowerShell 2.0
      7.  Enable Windows Defender real-time protection
      8.  Enable Attack Surface Reduction (ASR) rules
      9.  Disable NetBIOS over TCP/IP on all adapters
      10. Write timestamped log to hardening.log

    Every action is logged to hardening.log in the same directory as this script.
    Console output uses green (success), red (failure), yellow (warning/info),
    and magenta (dry-run preview).

.PARAMETER LogPath
    Path to the log file. Defaults to .\hardening.log

.PARAMETER DryRun
    Preview every change that WOULD be made without applying anything.
    Read-only queries still run so current state is reported accurately.
    The log file is still written (entries tagged [DRYRUN]).

.EXAMPLE
    .\01-hardening.ps1
    .\01-hardening.ps1 -LogPath C:\Logs\hardening.log
    .\01-hardening.ps1 -DryRun
    .\01-hardening.ps1 -DryRun -LogPath C:\Logs\dryrun.log
#>
[CmdletBinding()]
param (
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) { throw 'LogPath cannot be empty.' }
        $fullPath = [System.IO.Path]::GetFullPath($_)
        if ($fullPath.StartsWith('\\')) { throw 'UNC/network LogPath is not allowed.' }
        if ([System.IO.Path]::GetExtension($fullPath).ToLowerInvariant() -ne '.log') { throw 'LogPath must have .log extension.' }
        $true
    })]
    [string] $LogPath = (Join-Path $PSScriptRoot 'hardening.log'),
    [switch] $DryRun
)

Set-StrictMode -Version Latest

# -- Logging helper -----------------------------------------------------------
function Write-Log {
    param (
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR', 'DRYRUN')]
        [string] $Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry     = "[$timestamp] [$Level] $Message"

    Add-Content -Path $LogPath -Value $entry -Encoding UTF8

    switch ($Level) {
        'SUCCESS' { Write-Host $entry -ForegroundColor Green   }
        'ERROR'   { Write-Host $entry -ForegroundColor Red     }
        'WARNING' { Write-Host $entry -ForegroundColor Yellow  }
        'DRYRUN'  { Write-Host $entry -ForegroundColor Magenta }
        default   { Write-Host $entry -ForegroundColor Gray    }
    }
}

# -- Step header --------------------------------------------------------------
function Write-Step {
    param ([string] $Title)
    $line = ('-' * 70)
    Write-Host "`n$line" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "$line" -ForegroundColor Cyan
    Write-Log "=== $Title ===" -Level INFO
}

# -----------------------------------------------------------------------------
# STEP 0 - Administrator check
# -----------------------------------------------------------------------------
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host '[WARNING] This script must be run as Administrator. Exiting.' -ForegroundColor Yellow
    exit 1
}

Write-Log "Hardening session started by $env:USERNAME on $env:COMPUTERNAME" -Level INFO
Write-Log "Log file: $LogPath" -Level INFO

if ($DryRun) {
    Write-Host "`n*** DRY-RUN MODE - no changes will be made ***`n" -ForegroundColor Magenta
    Write-Log 'DRY-RUN MODE active. No system changes will be applied.' -Level DRYRUN
}

# -----------------------------------------------------------------------------
# STEP 1 - System Restore Point
# -----------------------------------------------------------------------------
Write-Step 'Create System Restore Point'
try {
    if ($DryRun) {
        Write-Log '[DRY RUN] Would enable ComputerRestore on system drive and create restore point "Pre-SecOps-Hardening".' -Level DRYRUN
    } else {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description 'Pre-SecOps-Hardening' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Log 'System Restore Point "Pre-SecOps-Hardening" created successfully.' -Level SUCCESS
    }
} catch {
    Write-Log "Failed to create System Restore Point: $($_.Exception.Message)" -Level WARNING
}

# -----------------------------------------------------------------------------
# STEP 2 - Disable SMB1
# -----------------------------------------------------------------------------
Write-Step 'Disable SMB1 Protocol'
try {
    $smb1 = Get-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -ErrorAction Stop

    if ($DryRun) {
        Write-Log "[DRY RUN] SMB1Protocol feature current state: $($smb1.State). Would disable if not already disabled." -Level DRYRUN
        Write-Log '[DRY RUN] Would set SmbServerConfiguration EnableSMB1Protocol = $false.' -Level DRYRUN
    } else {
        if ($smb1.State -ne 'Disabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -NoRestart -ErrorAction Stop
            Write-Log 'SMB1 Windows feature disabled.' -Level SUCCESS
        } else {
            Write-Log 'SMB1 Windows feature was already disabled.' -Level SUCCESS
        }

        Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
        Write-Log 'SMB1 server configuration set to disabled.' -Level SUCCESS
    }
} catch {
    Write-Log "Failed to disable SMB1: $($_.Exception.Message)" -Level ERROR
}

# -----------------------------------------------------------------------------
# STEP 3 - Enforce NTLMv2 only
# -----------------------------------------------------------------------------
Write-Step 'Enforce NTLMv2-Only Authentication'
try {
    $lmPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'

    if ($DryRun) {
        $curLm   = (Get-ItemProperty -Path $lmPath -Name 'LmCompatibilityLevel' -ErrorAction SilentlyContinue).LmCompatibilityLevel
        $curNoLM = (Get-ItemProperty -Path $lmPath -Name 'NoLMHash'             -ErrorAction SilentlyContinue).NoLMHash
        Write-Log "[DRY RUN] LmCompatibilityLevel current value: $curLm. Would set to 5 (NTLMv2 only)." -Level DRYRUN
        Write-Log "[DRY RUN] NoLMHash current value: $curNoLM. Would set to 1 (disable LM hash storage)." -Level DRYRUN
    } else {
        # LmCompatibilityLevel = 5 --- Send NTLMv2 response only; refuse LM & NTLM
        Set-ItemProperty -Path $lmPath -Name 'LmCompatibilityLevel' -Value 5 -Type DWord -Force -ErrorAction Stop
        Write-Log 'LmCompatibilityLevel set to 5 (NTLMv2 only).' -Level SUCCESS

        # NoLMHash = 1 --- Do not store LAN Manager hash
        Set-ItemProperty -Path $lmPath -Name 'NoLMHash' -Value 1 -Type DWord -Force -ErrorAction Stop
        Write-Log 'NoLMHash set to 1 (LM hash storage disabled).' -Level SUCCESS
    }
} catch {
    Write-Log "Failed to enforce NTLMv2: $($_.Exception.Message)" -Level ERROR
}

# -----------------------------------------------------------------------------
# STEP 4 - Enable SMB signing
# -----------------------------------------------------------------------------
Write-Step 'Enable SMB Signing (Client + Server)'
try {
    if ($DryRun) {
        $smbSrv = Get-SmbServerConfiguration -ErrorAction Stop
        $smbCli = Get-SmbClientConfiguration -ErrorAction Stop
        Write-Log "[DRY RUN] SMB server RequireSecuritySignature: $($smbSrv.RequireSecuritySignature). Would set to True." -Level DRYRUN
        Write-Log "[DRY RUN] SMB server EnableSecuritySignature:  $($smbSrv.EnableSecuritySignature). Would set to True."  -Level DRYRUN
        Write-Log "[DRY RUN] SMB client RequireSecuritySignature: $($smbCli.RequireSecuritySignature). Would set to True." -Level DRYRUN
    } else {
        Set-SmbServerConfiguration -RequireSecuritySignature $true  -Force -ErrorAction Stop
        Set-SmbServerConfiguration -EnableSecuritySignature  $true  -Force -ErrorAction Stop
        Write-Log 'SMB server signing enabled and required.' -Level SUCCESS

        Set-SmbClientConfiguration -RequireSecuritySignature $true  -Force -ErrorAction Stop
        Write-Log 'SMB client signing required.' -Level SUCCESS
    }
} catch {
    Write-Log "Failed to enable SMB signing: $($_.Exception.Message)" -Level ERROR
}

# -----------------------------------------------------------------------------
# STEP 5 - Disable PowerShell 2.0
# -----------------------------------------------------------------------------
Write-Step 'Disable PowerShell 2.0 Engine'
try {
    $ps2 = Get-WindowsOptionalFeature -Online -FeatureName 'MicrosoftWindowsPowerShellV2Root' -ErrorAction Stop

    if ($DryRun) {
        Write-Log "[DRY RUN] MicrosoftWindowsPowerShellV2Root current state: $($ps2.State). Would disable if not already disabled." -Level DRYRUN
    } else {
        if ($ps2.State -ne 'Disabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName 'MicrosoftWindowsPowerShellV2Root' -NoRestart -ErrorAction Stop
            Write-Log 'PowerShell 2.0 feature disabled.' -Level SUCCESS
        } else {
            Write-Log 'PowerShell 2.0 feature was already disabled.' -Level SUCCESS
        }
    }
} catch {
    Write-Log "Failed to disable PowerShell 2.0: $($_.Exception.Message)" -Level ERROR
}

# -----------------------------------------------------------------------------
# STEP 6 - Enable Windows Defender real-time protection
# -----------------------------------------------------------------------------
Write-Step 'Enable Windows Defender Real-Time Protection'
try {
    if ($DryRun) {
        $mpPref = Get-MpPreference -ErrorAction Stop
        Write-Log "[DRY RUN] DisableRealtimeMonitoring: $($mpPref.DisableRealtimeMonitoring). Would set to False." -Level DRYRUN
        Write-Log "[DRY RUN] DisableBehaviorMonitoring: $($mpPref.DisableBehaviorMonitoring). Would set to False." -Level DRYRUN
        Write-Log "[DRY RUN] DisableIOAVProtection:     $($mpPref.DisableIOAVProtection). Would set to False."     -Level DRYRUN
        Write-Log "[DRY RUN] DisableScriptScanning:     $($mpPref.DisableScriptScanning). Would set to False."     -Level DRYRUN
    } else {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Write-Log 'Windows Defender real-time monitoring enabled.' -Level SUCCESS

        Set-MpPreference -DisableBehaviorMonitoring $false -ErrorAction Stop
        Write-Log 'Windows Defender behavior monitoring enabled.' -Level SUCCESS

        Set-MpPreference -DisableIOAVProtection $false -ErrorAction Stop
        Write-Log 'Windows Defender IOAV (download/attachment) protection enabled.' -Level SUCCESS

        Set-MpPreference -DisableScriptScanning $false -ErrorAction Stop
        Write-Log 'Windows Defender script scanning enabled.' -Level SUCCESS
    }
} catch {
    Write-Log "Failed to configure Windows Defender: $($_.Exception.Message)" -Level ERROR
}

# -----------------------------------------------------------------------------
# STEP 7 - Enable Attack Surface Reduction (ASR) rules
# -----------------------------------------------------------------------------
Write-Step 'Enable Attack Surface Reduction (ASR) Rules'

# Rule GUIDs and friendly names - mode 1 = Block
$asrRules = [ordered]@{
    'BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550' = 'Block executable content from email/webmail'
    '3B576869-A4EC-4529-8536-B80A7769E899' = 'Block Office apps from creating executable content'
    '75668C1F-73B5-4CF0-BB93-3ECF5CB7CC84' = 'Block Office apps from injecting code into other processes'
    'D4F940AB-401B-4EFC-AADC-AD5F3C50688A' = 'Block Office apps from creating child processes'
    '26190899-1602-49E8-8B27-EB1D0A1CE869' = 'Block Office communication apps from creating child processes'
    '7674BA52-37EB-4A4F-A9A1-F0F9A1619A2C' = 'Block Adobe Reader from creating child processes'
    'D3E037E1-3EB8-44C8-A917-57927947596D' = 'Block JS/VBS from launching downloaded executable content'
    '5BEB7EFE-FD9A-4556-801D-275E5FFC04CC' = 'Block execution of potentially obfuscated scripts'
    '92E97FA1-2EDF-4476-BDD6-9DD0B4DDDC7B' = 'Block Win32 API calls from Office macros'
    '01443614-CD74-433A-B99E-2ECDC07BFC25' = 'Block executable files unless they meet prevalence criteria'
    'C1DB55AB-C21A-4637-BB3F-A12568109D35' = 'Use advanced protection against ransomware'
    '9E6C4E1F-7D60-472F-BA1A-A39EF669E4B2' = 'Block credential stealing from LSASS'
    'D1E49AAC-8F56-4280-B9BA-993A6D77406C' = 'Block process creations originating from PSExec and WMI commands'
    'B2B3F03D-6A65-4F7B-A9C7-1C7EF74A9BA4' = 'Block untrusted and unsigned processes from USB'
    'E6DB77E5-3DF2-4CF1-B95A-636979351E5B' = 'Block persistence through WMI event subscription'
}

$existingRules = (Get-MpPreference -ErrorAction SilentlyContinue).AttackSurfaceReductionRules_Ids

foreach ($ruleId in $asrRules.Keys) {
    try {
        if ($DryRun) {
            $alreadySet = $existingRules -contains $ruleId
            $status     = if ($alreadySet) { 'already enabled' } else { 'NOT currently enabled' }
            Write-Log "[DRY RUN] ASR rule ($status): $($asrRules[$ruleId]) [$ruleId] - Would set to Enabled." -Level DRYRUN
        } else {
            Add-MpPreference -AttackSurfaceReductionRules_Ids $ruleId `
                             -AttackSurfaceReductionRules_Actions Enabled `
                             -ErrorAction Stop
            Write-Log "ASR rule enabled: $($asrRules[$ruleId]) [$ruleId]" -Level SUCCESS
        }
    } catch {
        Write-Log "Failed to enable ASR rule [$ruleId] $($asrRules[$ruleId]): $($_.Exception.Message)" -Level ERROR
    }
}

# -----------------------------------------------------------------------------
# STEP 8 - Disable NetBIOS over TCP/IP
# -----------------------------------------------------------------------------
Write-Step 'Disable NetBIOS over TCP/IP'
try {
    # NetbiosOptions: 0=Default(DHCP), 1=Enable, 2=Disable
    $adapters    = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' -ErrorAction Stop
    $wmiAdapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -ErrorAction Stop

    if ($DryRun) {
        foreach ($adapter in $adapters) {
            $cur = (Get-ItemProperty -Path $adapter.PSPath -Name 'NetbiosOptions' -ErrorAction SilentlyContinue).NetbiosOptions
            Write-Log "[DRY RUN] Adapter $($adapter.PSChildName): NetbiosOptions = $cur. Would set to 2 (Disabled)." -Level DRYRUN
        }
        foreach ($nic in $wmiAdapters) {
            Write-Log "[DRY RUN] Would call SetTcpipNetbios(2) via WMI on: $($nic.Description)" -Level DRYRUN
        }
    } else {
        $disabled = 0
        $failed   = 0

        foreach ($adapter in $adapters) {
            try {
                Set-ItemProperty -Path $adapter.PSPath -Name 'NetbiosOptions' -Value 2 -Type DWord -Force -ErrorAction Stop
                $disabled++
            } catch {
                Write-Log "NetBIOS: could not update adapter $($adapter.PSChildName): $($_.Exception.Message)" -Level WARNING
                $failed++
            }
        }

        Write-Log "NetBIOS over TCP/IP disabled on $disabled adapter(s); $failed failed." -Level $(if ($failed -gt 0) { 'WARNING' } else { 'SUCCESS' })

        foreach ($nic in $wmiAdapters) {
            try {
                $nic | Invoke-CimMethod -MethodName 'SetTcpipNetbios' -Arguments @{ TcpipNetbiosOptions = [uint32]2 } -ErrorAction Stop | Out-Null
                Write-Log "NetBIOS disabled via WMI on: $($nic.Description)" -Level SUCCESS
            } catch {
                Write-Log "WMI NetBIOS disable failed for $($nic.Description): $($_.Exception.Message)" -Level WARNING
            }
        }
    }
} catch {
    Write-Log "Failed to disable NetBIOS over TCP/IP: $($_.Exception.Message)" -Level ERROR
}

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------
$completionMsg = if ($DryRun) {
    'Dry-run complete. No changes were made. Review the log to see what WOULD be changed.'
} else {
    'Hardening complete. Review the log for any warnings or errors.'
}

Write-Host "`n$('=' * 70)" -ForegroundColor Cyan
Write-Host "  $completionMsg" -ForegroundColor Cyan
Write-Host "  Log: $LogPath" -ForegroundColor Cyan
Write-Host "$('=' * 70)`n" -ForegroundColor Cyan
Write-Log $completionMsg -Level $(if ($DryRun) { 'DRYRUN' } else { 'SUCCESS' })


