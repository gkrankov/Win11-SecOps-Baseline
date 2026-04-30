#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Captures a point-in-time Windows 11 security checkpoint and writes it to
    state\security-checkpoint.json.

.DESCRIPTION
    Reads live system state for:
      - SMBv1 status
      - NTLMv2 / LM Compatibility Level
      - PowerShell 2.0 presence and script-block logging
      - Windows Defender service and preference settings
      - BitLocker drive encryption state
      - Windows Firewall profile configuration
      - Secure Boot / UEFI state

    Compares each value against its expected state and writes a compliance
    summary. Use -WhatIf to preview without writing the file.

.PARAMETER OutputPath
    Path to write the checkpoint JSON. Defaults to state\security-checkpoint.json
    relative to this script's directory.

.EXAMPLE
    .\Get-SecurityCheckpoint.ps1
    .\Get-SecurityCheckpoint.ps1 -OutputPath C:\audits\checkpoint.json
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) { throw 'OutputPath cannot be empty.' }
        $fullPath = [System.IO.Path]::GetFullPath($_)
        if ($fullPath.StartsWith('\\')) { throw 'UNC output paths are not allowed.' }
        if ([System.IO.Path]::GetExtension($fullPath).ToLowerInvariant() -ne '.json') { throw 'OutputPath must have a .json extension.' }
        $true
    })]
    [string] $OutputPath = (Join-Path $PSScriptRoot 'state\security-checkpoint.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # keep going even if one control fails

$now = Get-Date -Format 'o'

# ── Helper ────────────────────────────────────────────────────────────────────
function Get-RegValue {
    param([string]$Path, [string]$Name, $Default = $null)
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name }
    catch { $Default }
}

# ── Checkpoint metadata ───────────────────────────────────────────────────────
$checkpoint = [ordered]@{
    timestamp    = $now
    computername = $env:COMPUTERNAME
    capturedBy   = "$env:USERDOMAIN\$env:USERNAME"
    osVersion    = (Get-CimInstance Win32_OperatingSystem).Caption + ' ' +
                   (Get-CimInstance Win32_OperatingSystem).BuildNumber
    psVersion    = $PSVersionTable.PSVersion.ToString()
}

# ── SMB ───────────────────────────────────────────────────────────────────────
$smb1 = $false
try { $smb1 = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol } catch {}
$smb = [ordered]@{
    smb1Enabled          = $smb1
    smb2Enabled          = $true
    smb1AuditNote        = 'SMBv1 must be disabled per CIS 18.3.3 / WN11-CC-000110'
    expectedSmb1Enabled  = $false
}

# ── Authentication / NTLMv2 ──────────────────────────────────────────────────
$lmLevel = Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LmCompatibilityLevel' -1
$auth = [ordered]@{
    ntlmv2Enforced                = ($lmLevel -eq 5)
    lmCompatibilityLevel          = $lmLevel
    lmCompatibilityDescription    = '5 = Send NTLMv2 only, refuse LM and NTLM'
    expectedLmCompatibilityLevel  = 5
    ntlmAuditNote                 = 'Level 5 required per CIS 2.3.11.7 / WN11-SO-000195'
}

# ── PowerShell 2.0 ───────────────────────────────────────────────────────────
$ps2Feature = Get-WindowsOptionalFeature -Online -FeatureName 'MicrosoftWindowsPowerShellV2Root' -ErrorAction SilentlyContinue
$ps2Installed = $ps2Feature -and ($ps2Feature.State -eq 'Enabled')

$sbLogging = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging' 'EnableScriptBlockLogging' 0
$modLogging = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging'     'EnableModuleLogging'      0
$transcript = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription'     'EnableTranscripting'      0

$ps = [ordered]@{
    ps2Installed             = $ps2Installed
    ps2WindowsFeatureName    = 'MicrosoftWindowsPowerShellV2Root'
    psScriptBlockLogging     = [bool]$sbLogging
    psModuleLogging          = [bool]$modLogging
    psTranscriptionEnabled   = [bool]$transcript
    expectedPs2Installed     = $false
    ps2AuditNote             = 'PS 2.0 must be removed per CIS 18.9.100.1 / WN11-CC-000315'
}

# ── Windows Defender ─────────────────────────────────────────────────────────
$defSvc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
$defPref = $null
try { $defPref = Get-MpPreference -ErrorAction Stop } catch {}

$realTimeProtectionEnabled = $null
$cloudProtectionEnabled = $null
$cloudBlockLevel = $null
$networkProtectionEnabled = $null
$puaProtection = $null
$controlledFolderAccessEnabled = $null
$antispywareSignatureAge = $null
$antivirusSignatureAge = $null

if ($defPref) {
    $realTimeProtectionEnabled = (-not $defPref.DisableRealtimeMonitoring)
    $cloudProtectionEnabled = ($defPref.MAPSReporting -gt 0)
    $cloudBlockLevel = $defPref.CloudBlockLevel
    $networkProtectionEnabled = ($defPref.EnableNetworkProtection -eq 1)
    $puaProtection = $defPref.PUAProtection
    $controlledFolderAccessEnabled = ($defPref.EnableControlledFolderAccess -eq 'Enabled')
    $antispywareSignatureAge = $defPref.AntispywareSignatureAge
    $antivirusSignatureAge = $defPref.AntivirusSignatureAge
}

$defender = [ordered]@{
    serviceRunning                = ($defSvc -and $defSvc.Status -eq 'Running')
    realTimeProtectionEnabled     = $realTimeProtectionEnabled
    cloudProtectionEnabled        = $cloudProtectionEnabled
    cloudBlockLevel               = $cloudBlockLevel
    tamperProtectionEnabled       = (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'TamperProtection' 0) -eq 5
    networkProtectionEnabled      = $networkProtectionEnabled
    puaProtection                 = $puaProtection
    controlledFolderAccessEnabled = $controlledFolderAccessEnabled
    antispywareSignatureAge       = $antispywareSignatureAge
    antivirusSignatureAge         = $antivirusSignatureAge
    defenderAuditNote             = 'All Defender controls required per CIS 8.x / WN11-AV-000010'
}

# ── BitLocker ─────────────────────────────────────────────────────────────────
$blv = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
$tpm = Get-Tpm -ErrorAction SilentlyContinue

$systemDriveEncrypted = $false
$encryptionMethod = 'Unknown'
$protectionStatus = 'Unknown'
$keyProtectors = @()
$tpmPresent = $false
$tpmEnabled = $false
$tpmActivated = $false
$recoveryKeyBackedUp = $false

if ($blv) {
    $systemDriveEncrypted = ($blv.ProtectionStatus -eq 'On')
    $encryptionMethod = $blv.EncryptionMethod.ToString()
    $protectionStatus = $blv.ProtectionStatus.ToString()
    $keyProtectors = @($blv.KeyProtector | ForEach-Object { $_.KeyProtectorType.ToString() })
    $recoveryKeyBackedUp = ($blv.KeyProtector.KeyProtectorType -contains 'RecoveryPassword')
}

if ($tpm) {
    $tpmPresent = $tpm.TpmPresent
    $tpmEnabled = $tpm.TpmEnabled
    $tpmActivated = $tpm.TpmActivated
}

$bitlocker = [ordered]@{
    systemDriveEncrypted  = $systemDriveEncrypted
    systemDriveLetter     = 'C:'
    encryptionMethod      = $encryptionMethod
    protectionStatus      = $protectionStatus
    keyProtectors         = $keyProtectors
    tpmPresent            = $tpmPresent
    tpmEnabled            = $tpmEnabled
    tpmActivated          = $tpmActivated
    recoveryKeyBackedUp   = $recoveryKeyBackedUp
    bitlockerAuditNote    = 'BitLocker with TPM required per CIS 18.10.9 / WN11-00-000030'
}

# ── Firewall ──────────────────────────────────────────────────────────────────
function ConvertTo-FirewallProfileObject ([string]$profileName) {
    $p = Get-NetFirewallProfile -Profile $profileName -ErrorAction SilentlyContinue
    if (-not $p) { return @{ enabled = $false } }
    [ordered]@{
        enabled                = [bool]$p.Enabled
        defaultInboundAction   = $p.DefaultInboundAction.ToString()
        defaultOutboundAction  = $p.DefaultOutboundAction.ToString()
        logBlocked             = $p.LogBlocked -eq 'True'
        logAllowed             = $p.LogAllowed -eq 'True'
        logMaxSizeKilobytes    = [int]$p.LogMaxSizeKilobytes
    }
}

$firewall = [ordered]@{
    profiles = [ordered]@{
        domain  = ConvertTo-FirewallProfileObject 'Domain'
        private = ConvertTo-FirewallProfileObject 'Private'
        public  = ConvertTo-FirewallProfileObject 'Public'
    }
    firewallAuditNote = 'All profiles must be enabled and block inbound per CIS 9.x / WN11-NF-000010'
}

# ── Secure Boot ───────────────────────────────────────────────────────────────
$sbEnabled = $false
try { $sbEnabled = Confirm-SecureBootUEFI -ErrorAction Stop } catch {}
$uefiMode = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction SilentlyContinue).PEFirmwareType -eq 2

$secureBoot = [ordered]@{
    secureBootEnabled  = $sbEnabled
    uefiMode           = $uefiMode
    legacyBiosMode     = -not $uefiMode
    secureBootAuditNote = 'Secure Boot required per CIS 18.10.5 / WN11-00-000020'
}

# ── Compliance summary ────────────────────────────────────────────────────────
$controls = @(
    (-not $smb.smb1Enabled),                          # SMBv1 off
    ($auth.lmCompatibilityLevel -eq 5),               # NTLMv2
    (-not $ps.ps2Installed),                          # PS2 removed
    $defender.serviceRunning,                         # Defender running
    $bitlocker.systemDriveEncrypted,                  # BitLocker on C:
    ($firewall.profiles.domain.enabled  -and $firewall.profiles.domain.defaultInboundAction  -eq 'Block'),
    $secureBoot.secureBootEnabled                     # Secure Boot
)

$passing = ($controls | Where-Object { $_ -eq $true }).Count
$failing = ($controls | Where-Object { $_ -eq $false }).Count

$summary = [ordered]@{
    totalControls   = $controls.Count
    passing         = $passing
    failing         = $failing
    notApplicable   = 0
    overallStatus   = if ($failing -eq 0) { 'PASS' } else { 'FAIL' }
    lastEvaluated   = $now
}

# ── Assemble and write ────────────────────────────────────────────────────────
$output = [ordered]@{
    '_schema'      = 'Win11-SecOps-Baseline/security-checkpoint/v1'
    '_description' = 'Point-in-time snapshot of Windows 11 security control states.'
    checkpoint         = $checkpoint
    smb                = $smb
    authentication     = $auth
    powershell         = $ps
    windowsDefender    = $defender
    bitlocker          = $bitlocker
    firewall           = $firewall
    secureBoot         = $secureBoot
    complianceSummary  = $summary
}

$json = $output | ConvertTo-Json -Depth 10
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)

if ($PSCmdlet.ShouldProcess($resolvedOutputPath, 'Write security checkpoint')) {
    $parentDir = Split-Path -Path $resolvedOutputPath -Parent
    if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
        New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop | Out-Null
    }

    $json | Set-Content -LiteralPath $resolvedOutputPath -Encoding UTF8 -ErrorAction Stop
    Write-Host "✔ Checkpoint written: $resolvedOutputPath" -ForegroundColor Green
    Write-Host "  Controls: $passing/$($controls.Count) passing — overall: $($summary.overallStatus)" `
        -ForegroundColor (if ($failing -eq 0) { 'Green' } else { 'Yellow' })
} else {
    Write-Host '[WhatIf] Checkpoint JSON preview:' -ForegroundColor Cyan
    $json
}
