#Requires -Version 5.1

[CmdletBinding()]
param(
    [string] $BaselinePath = (Join-Path $PSScriptRoot 'config\baseline.json'),
    [string] $SettingsPath = (Join-Path $PSScriptRoot 'config\settings.json'),
    [string] $ReportDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-LocalPath {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [ValidateSet('File', 'Directory', 'Any')]
        [string] $PathType = 'Any',
        [string] $RequiredExtension
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path cannot be empty.'
    }

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\')) {
        throw "UNC paths are not allowed: $fullPath"
    }

    if ($RequiredExtension -and ([System.IO.Path]::GetExtension($fullPath).ToLowerInvariant() -ne $RequiredExtension.ToLowerInvariant())) {
        throw "Path must use $RequiredExtension extension: $fullPath"
    }

    if ($PathType -eq 'File' -and -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Required file not found: $fullPath"
    }

    if ($PathType -eq 'Directory' -and -not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "Required directory not found: $fullPath"
    }

    return $fullPath
}

$commonPath = Join-Path $PSScriptRoot 'modules\Common\SecOpsState.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "Required script not found: $commonPath"
}

$resolvedRoot = (Resolve-Path -Path $PSScriptRoot -ErrorAction Stop).Path
$resolvedCommon = (Resolve-Path -Path $commonPath -ErrorAction Stop).Path
if (-not $resolvedCommon.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to source script outside project root: $resolvedCommon"
}

. $resolvedCommon

function ConvertTo-DisplayString {
    param($Value)

    if ($null -eq $Value) {
        return 'N/A'
    }

    if ($Value -is [datetime]) {
        return $Value.ToString('yyyy-MM-dd HH:mm:ss')
    }

    if ($Value -is [Array]) {
        return (($Value | ForEach-Object { ConvertTo-DisplayString -Value $_ }) -join ', ')
    }

    return $Value.ToString()
}

function Escape-Markdown {
    param([string] $Value)

    if ($null -eq $Value) {
        return 'N/A'
    }

    return ($Value -replace '\|', '\|' -replace "`r?`n", '<br>')
}

function Write-CheckResult {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('PASS', 'FAIL', 'WARNING')] [string] $Status,
        [Parameter(Mandatory)] [string] $Detail,
        [Parameter(Mandatory)] [int] $PointsEarned,
        [Parameter(Mandatory)] [int] $PointsPossible
    )

    $icon = '✅'
    $color = 'Green'
    switch ($Status) {
        'FAIL' {
            $icon = '❌'
            $color = 'Red'
        }
        'WARNING' {
            $icon = '⚠️'
            $color = 'Yellow'
        }
    }

    Write-Host ("{0} [{1}] {2} ({3}/{4}) - {5}" -f $icon, $Status, $Name, $PointsEarned, $PointsPossible, $Detail) -ForegroundColor $color
}

function Get-ScoreFromStatus {
    param(
        [Parameter(Mandatory)] [ValidateSet('PASS', 'FAIL', 'WARNING')] [string] $Status,
        [Parameter(Mandatory)] [int] $Weight
    )

    switch ($Status) {
        'PASS' { return $Weight }
        'WARNING' { return [int] [Math]::Floor($Weight / 2) }
        default { return 0 }
    }
}

function New-CheckResult {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ValidateSet('PASS', 'FAIL', 'WARNING')] [string] $Status,
        [Parameter(Mandatory)] [int] $Weight,
        [Parameter(Mandatory)] [string] $Detail
    )

    $pointsEarned = Get-ScoreFromStatus -Status $Status -Weight $Weight
    Write-CheckResult -Name $Name -Status $Status -Detail $Detail -PointsEarned $pointsEarned -PointsPossible $Weight

    return [PSCustomObject]@{
        Name           = $Name
        Status         = $Status
        PointsEarned   = $pointsEarned
        PointsPossible = $Weight
        Detail         = $Detail
    }
}

function Add-BaselineFindingIfNeeded {
    param(
        [Parameter(Mandatory)] [System.Collections.Generic.List[object]] $Findings,
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Setting,
        $ExpectedValue,
        $CurrentValue
    )

    $status = 'PASS'
    if ((ConvertTo-DisplayString -Value $ExpectedValue) -ne (ConvertTo-DisplayString -Value $CurrentValue)) {
        $status = 'FAIL'
    }

    $Findings.Add([PSCustomObject]@{
        Category = $Category
        Setting  = $Setting
        Status   = $status
        Expected = ConvertTo-DisplayString -Value $ExpectedValue
        Current  = ConvertTo-DisplayString -Value $CurrentValue
    })
}

function Get-PreviousPostureScore {
    param(
        [Parameter(Mandatory)] [string] $ReportDirectory
    )

    $latestReport = Get-ChildItem -Path $ReportDirectory -Filter 'posture-report-*.md' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latestReport) {
        return $null
    }

    $content = Get-Content -Path $latestReport.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) {
        return $null
    }

    $match = [regex]::Match($content, '\|\s*Score\s*\|\s*(\d+)\s*/\s*100\s*\|')
    if (-not $match.Success) {
        return $null
    }

    return [PSCustomObject]@{
        Score      = [int] $match.Groups[1].Value
        ReportPath = $latestReport.FullName
    }
}

function Get-PostureScoreComparison {
    param(
        [int] $CurrentScore,
        $PreviousScoreInfo
    )

    if ($null -eq $PreviousScoreInfo) {
        return [PSCustomObject]@{
            HasPrevious    = $false
            PreviousScore  = $null
            CurrentScore   = $CurrentScore
            Delta          = $null
            SignedDelta    = 'N/A'
            Trend          = 'First scan'
            PreviousReport = $null
        }
    }

    $delta = $CurrentScore - [int] $PreviousScoreInfo.Score
    $signedDelta = [string]::Format('{0:+#;-#;0}', $delta)

    $trend = 'No change'
    if ($delta -gt 0) {
        $trend = 'Improved'
    } elseif ($delta -lt 0) {
        $trend = 'Degraded'
    }

    return [PSCustomObject]@{
        HasPrevious    = $true
        PreviousScore  = [int] $PreviousScoreInfo.Score
        CurrentScore   = $CurrentScore
        Delta          = $delta
        SignedDelta    = $signedDelta
        Trend          = $trend
        PreviousReport = $PreviousScoreInfo.ReportPath
    }
}

function Write-ScoreComparison {
    param(
        [Parameter(Mandatory)] $Comparison
    )

    if (-not $Comparison.HasPrevious) {
        Write-Host 'Score trend: first scan (no previous score found).' -ForegroundColor Yellow
        return
    }

    $color = 'Yellow'
    if ($Comparison.Delta -gt 0) {
        $color = 'Green'
    } elseif ($Comparison.Delta -lt 0) {
        $color = 'Red'
    }

    Write-Host ("Score trend: {0} ({1} points since last scan)" -f $Comparison.Trend, $Comparison.SignedDelta) -ForegroundColor $color
}

function Export-PostureReport {
    param(
        [Parameter(Mandatory)] [System.Collections.Generic.List[object]] $Checks,
        [Parameter(Mandatory)] [System.Collections.Generic.List[object]] $BaselineFindings,
        [Parameter(Mandatory)] [System.Collections.Generic.List[object]] $ListeningPorts,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [int] $Score,
        [Parameter(Mandatory)] $ScoreComparison
    )

    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add('# Security Posture Assessment')
    $lines.Add('')
    $lines.Add("| Field | Value |")
    $lines.Add("| --- | --- |")
    $lines.Add("| Generated | $generatedAt |")
    $lines.Add("| Computer | $env:COMPUTERNAME |")
    $lines.Add("| Score | $Score / 100 |")
    if ($ScoreComparison.HasPrevious) {
        $lines.Add("| Previous Score | $($ScoreComparison.PreviousScore) / 100 |")
        $lines.Add("| Delta | $($ScoreComparison.SignedDelta) points |")
        $lines.Add("| Trend | $($ScoreComparison.Trend) |")
    } else {
        $lines.Add("| Previous Score | N/A |")
        $lines.Add("| Delta | N/A |")
        $lines.Add("| Trend | First scan |")
    }
    $lines.Add('')
    $lines.Add('## Summary Checks')
    $lines.Add('')
    $lines.Add('| Check | Status | Points | Detail |')
    $lines.Add('| --- | --- | --- | --- |')

    foreach ($check in $Checks) {
        $lines.Add("| $(Escape-Markdown $check.Name) | $(Escape-Markdown $check.Status) | $($check.PointsEarned)/$($check.PointsPossible) | $(Escape-Markdown $check.Detail) |")
    }

    $lines.Add('')
    $lines.Add('## Baseline Setting Results')
    $lines.Add('')
    $lines.Add('| Category | Setting | Status | Expected | Current |')
    $lines.Add('| --- | --- | --- | --- | --- |')

    foreach ($finding in $BaselineFindings) {
        $lines.Add("| $(Escape-Markdown $finding.Category) | $(Escape-Markdown $finding.Setting) | $(Escape-Markdown $finding.Status) | $(Escape-Markdown $finding.Expected) | $(Escape-Markdown $finding.Current) |")
    }

    $lines.Add('')
    $lines.Add('## Listening Ports')
    $lines.Add('')
    if ($ListeningPorts.Count -eq 0) {
        $lines.Add('No non-loopback TCP listening ports were detected.')
    } else {
        $lines.Add('| Address | Port | Process | PID |')
        $lines.Add('| --- | --- | --- | --- |')
        foreach ($port in $ListeningPorts) {
            $lines.Add("| $(Escape-Markdown $port.LocalAddress) | $($port.LocalPort) | $(Escape-Markdown $port.ProcessName) | $($port.OwningProcess) |")
        }
    }

    $resolvedOutputPath = Resolve-LocalPath -Path $OutputPath -PathType Any -RequiredExtension '.md'
    $parentDir = Split-Path -Path $resolvedOutputPath -Parent
    if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
        New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop | Out-Null
    }

    Set-Content -LiteralPath $resolvedOutputPath -Value $lines -Encoding UTF8 -ErrorAction Stop
}

$resolvedBaselinePath = Resolve-LocalPath -Path $BaselinePath -PathType File -RequiredExtension '.json'
$resolvedSettingsPath = Resolve-LocalPath -Path $SettingsPath -PathType File -RequiredExtension '.json'

$baseline = Get-Content -LiteralPath $resolvedBaselinePath -Raw -ErrorAction Stop | ConvertFrom-Json
$settings = Get-Content -LiteralPath $resolvedSettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json

$resolvedReportDir = $ReportDir
if ([string]::IsNullOrWhiteSpace($resolvedReportDir)) {
    $resolvedReportDir = $settings.reporting.outputPath
}

$resolvedReportDir = Resolve-LocalPath -Path $resolvedReportDir -PathType Any

if (-not (Test-Path -LiteralPath $resolvedReportDir)) {
    New-Item -ItemType Directory -Path $resolvedReportDir -Force -ErrorAction Stop | Out-Null
}

$currentAuditPolicies = Get-SecOpsAuditPoliciesState
$currentFirewallStates = Get-SecOpsFirewallStates -Profiles $baseline.Firewall.Profiles
$currentUserAccounts = Get-SecOpsUserAccountsState
$currentWindowsDefender = Get-SecOpsWindowsDefenderState
$currentNetworkHardening = Get-SecOpsNetworkHardeningState
$currentBitLocker = Get-SecOpsBitLockerState
$currentSecureBoot = Get-SecOpsSecureBootState
$currentWindowsUpdate = Get-SecOpsWindowsUpdateState
$currentListeningPorts = Get-SecOpsListeningPorts

$checks = New-Object System.Collections.Generic.List[object]

$smbStatus = if ($currentNetworkHardening.DisableSMBv1 -eq $baseline.NetworkHardening.DisableSMBv1) { 'PASS' } else { 'FAIL' }
$checks.Add((New-CheckResult -Name 'SMB1 Protocol' -Status $smbStatus -Weight 10 -Detail ("Expected SMB1 disabled = {0}; current = {1}" -f `
    $baseline.NetworkHardening.DisableSMBv1, $currentNetworkHardening.DisableSMBv1)))

$ntlmStatus = if ($currentNetworkHardening.DisableNTLMv1 -eq $baseline.NetworkHardening.DisableNTLMv1) { 'PASS' } else { 'FAIL' }
$checks.Add((New-CheckResult -Name 'NTLMv2 Enforcement' -Status $ntlmStatus -Weight 10 -Detail ("Expected NTLMv1 disabled = {0}; current = {1}" -f `
    $baseline.NetworkHardening.DisableNTLMv1, $currentNetworkHardening.DisableNTLMv1)))

$ps2Feature = Get-WindowsOptionalFeature -Online -FeatureName 'MicrosoftWindowsPowerShellV2Root' -ErrorAction SilentlyContinue
$ps2Installed = ($ps2Feature -and $ps2Feature.State -eq 'Enabled')
$ps2Status = if (-not $ps2Installed) { 'PASS' } else { 'FAIL' }
$checks.Add((New-CheckResult -Name 'PowerShell 2.0' -Status $ps2Status -Weight 10 -Detail ("PowerShell 2.0 installed = {0}" -f $ps2Installed)))

$defenderDrifts = New-Object System.Collections.Generic.List[string]
foreach ($property in $baseline.WindowsDefender.PSObject.Properties.Name) {
    if ((ConvertTo-DisplayString -Value $baseline.WindowsDefender.$property) -ne (ConvertTo-DisplayString -Value $currentWindowsDefender[$property])) {
        $defenderDrifts.Add($property)
    }
}

$defenderStatus = 'PASS'
if ($defenderDrifts.Count -gt 0) {
    if ($defenderDrifts -contains 'EnableRealTimeMonitoring' -or $defenderDrifts -contains 'EnableTamperProtection') {
        $defenderStatus = 'FAIL'
    } else {
        $defenderStatus = 'WARNING'
    }
}

$checks.Add((New-CheckResult -Name 'Windows Defender' -Status $defenderStatus -Weight 15 -Detail ("Drifted settings: {0}" -f `
    $(if ($defenderDrifts.Count -gt 0) { $defenderDrifts -join ', ' } else { 'None' }))))

$bitLockerStatus = 'FAIL'
if ($currentBitLocker.SystemDriveEncrypted -and $currentBitLocker.TpmPresent -and $currentBitLocker.TpmEnabled) {
    $bitLockerStatus = 'PASS'
} elseif ($currentBitLocker.SystemDriveEncrypted) {
    $bitLockerStatus = 'WARNING'
}

$checks.Add((New-CheckResult -Name 'BitLocker' -Status $bitLockerStatus -Weight 15 -Detail ("Encrypted={0}; TPM present={1}; TPM enabled={2}" -f `
    $currentBitLocker.SystemDriveEncrypted, $currentBitLocker.TpmPresent, $currentBitLocker.TpmEnabled)))

$firewallFailures = New-Object System.Collections.Generic.List[string]
foreach ($profileName in $baseline.Firewall.Profiles) {
    $profileState = $currentFirewallStates[$profileName]
    if (-not $profileState.Enabled) {
        $firewallFailures.Add("Enabled[$profileName]")
    }
    foreach ($property in @('DefaultInboundAction', 'DefaultOutboundAction', 'NotifyOnBlock', 'LogAllowed', 'LogBlocked', 'LogMaxSizeKilobytes')) {
        if ((ConvertTo-DisplayString -Value $baseline.Firewall.$property) -ne (ConvertTo-DisplayString -Value $profileState.$property)) {
            $firewallFailures.Add(('{0}[{1}]' -f $property, $profileName))
        }
    }
}

$firewallStatus = 'PASS'
if ($firewallFailures.Count -gt 0) {
    if (($firewallFailures | Where-Object { $_ -match '^Enabled\[' -or $_ -match '^DefaultInboundAction\[' }).Count -gt 0) {
        $firewallStatus = 'FAIL'
    } else {
        $firewallStatus = 'WARNING'
    }
}

$checks.Add((New-CheckResult -Name 'Firewall' -Status $firewallStatus -Weight 15 -Detail ("Drifted settings: {0}" -f `
    $(if ($firewallFailures.Count -gt 0) { $firewallFailures -join ', ' } else { 'None' }))))

$secureBootStatus = if ($currentSecureBoot.SecureBootEnabled -and $currentSecureBoot.UefiMode) { 'PASS' } else { 'FAIL' }
$checks.Add((New-CheckResult -Name 'Secure Boot' -Status $secureBootStatus -Weight 10 -Detail ("SecureBootEnabled={0}; UefiMode={1}" -f `
    $currentSecureBoot.SecureBootEnabled, $currentSecureBoot.UefiMode)))

$windowsUpdateStatus = 'WARNING'
if ($currentWindowsUpdate.StartMode -eq 'Disabled') {
    $windowsUpdateStatus = 'FAIL'
} elseif ($currentWindowsUpdate.UpdatesCurrent) {
    $windowsUpdateStatus = 'PASS'
}

$checks.Add((New-CheckResult -Name 'Windows Update' -Status $windowsUpdateStatus -Weight 10 -Detail ("Service start mode={0}; latest update={1}" -f `
    $currentWindowsUpdate.StartMode, (ConvertTo-DisplayString -Value $currentWindowsUpdate.LatestInstalledUpdate))))

$listeningPortStatus = 'PASS'
if ($currentListeningPorts.Count -gt 10) {
    $listeningPortStatus = 'FAIL'
} elseif ($currentListeningPorts.Count -gt 0) {
    $listeningPortStatus = 'WARNING'
}

$checks.Add((New-CheckResult -Name 'Open Listening Ports' -Status $listeningPortStatus -Weight 5 -Detail ("Non-loopback listeners detected: {0}" -f `
    $currentListeningPorts.Count)))

$baselineFindings = New-Object System.Collections.Generic.List[object]

foreach ($property in $baseline.AuditPolicies.PSObject.Properties.Name) {
    Add-BaselineFindingIfNeeded -Findings $baselineFindings -Category 'AuditPolicies' -Setting $property `
        -ExpectedValue $baseline.AuditPolicies.$property -CurrentValue $currentAuditPolicies[$property]
}

foreach ($profileName in $baseline.Firewall.Profiles) {
    $profileState = $currentFirewallStates[$profileName]
    Add-BaselineFindingIfNeeded -Findings $baselineFindings -Category 'Firewall' -Setting "Enabled[$profileName]" `
        -ExpectedValue $true -CurrentValue $profileState.Enabled

    foreach ($property in @('DefaultInboundAction', 'DefaultOutboundAction', 'NotifyOnBlock', 'LogAllowed', 'LogBlocked', 'LogMaxSizeKilobytes')) {
        Add-BaselineFindingIfNeeded -Findings $baselineFindings -Category 'Firewall' -Setting ("{0}[{1}]" -f $property, $profileName) `
            -ExpectedValue $baseline.Firewall.$property -CurrentValue $profileState.$property
    }
}

foreach ($property in $baseline.UserAccounts.PSObject.Properties.Name) {
    Add-BaselineFindingIfNeeded -Findings $baselineFindings -Category 'UserAccounts' -Setting $property `
        -ExpectedValue $baseline.UserAccounts.$property -CurrentValue $currentUserAccounts[$property]
}

foreach ($property in $baseline.WindowsDefender.PSObject.Properties.Name) {
    Add-BaselineFindingIfNeeded -Findings $baselineFindings -Category 'WindowsDefender' -Setting $property `
        -ExpectedValue $baseline.WindowsDefender.$property -CurrentValue $currentWindowsDefender[$property]
}

foreach ($property in $baseline.NetworkHardening.PSObject.Properties.Name) {
    Add-BaselineFindingIfNeeded -Findings $baselineFindings -Category 'NetworkHardening' -Setting $property `
        -ExpectedValue $baseline.NetworkHardening.$property -CurrentValue $currentNetworkHardening[$property]
}

$totalScore = ($checks | Measure-Object -Property PointsEarned -Sum).Sum
$previousScoreInfo = Get-PreviousPostureScore -ReportDirectory $resolvedReportDir
$scoreComparison = Get-PostureScoreComparison -CurrentScore $totalScore -PreviousScoreInfo $previousScoreInfo

$reportPath = Join-Path $resolvedReportDir ('posture-report-{0}.md' -f (Get-Date -Format 'yyyy-MM-dd-HH-mm-ss'))
Export-PostureReport -Checks $checks -BaselineFindings $baselineFindings -ListeningPorts $currentListeningPorts -OutputPath $reportPath -Score $totalScore -ScoreComparison $scoreComparison

Write-Host '' -ForegroundColor Gray
Write-Host ("Overall posture score: {0}/100" -f $totalScore) -ForegroundColor Cyan
Write-ScoreComparison -Comparison $scoreComparison
Write-Host ("Report written: {0}" -f $reportPath) -ForegroundColor Cyan
