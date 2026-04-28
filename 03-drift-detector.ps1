#Requires -Version 5.1

[CmdletBinding()]
param(
    [string] $BaselinePath = (Join-Path $PSScriptRoot 'config\baseline.json'),
    [string] $SettingsPath = (Join-Path $PSScriptRoot 'config\settings.json'),
    [string] $ReportDir,
    [switch] $UpdateBaseline
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

$script:LogPath = $null
$script:AllowedModuleCategories = @('AuditPolicies', 'Firewall', 'UserAccounts', 'WindowsDefender', 'NetworkHardening')

function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string] $Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $Message"

    if ($script:LogPath) {
        Add-Content -Path $script:LogPath -Value $entry -Encoding UTF8
    }

    switch ($Level) {
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        'WARNING' { Write-Host $entry -ForegroundColor Yellow }
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        default   { Write-Host $entry -ForegroundColor Gray }
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-ComparableString {
    param($Value)

    if ($null -eq $Value) {
        return '<null>'
    }

    if ($Value -is [Array]) {
        return (($Value | ForEach-Object { ConvertTo-ComparableString -Value $_ }) -join ',')
    }

    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }

    return $Value.ToString()
}

function ConvertTo-DisplayString {
    param($Value)

    if ($null -eq $Value) {
        return 'N/A'
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

function Get-RiskLevel {
    param(
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Setting
    )

    $normalized = ($Setting -replace '\[.*\]$', '')

    switch ($Category) {
        'AuditPolicies' { return 'Low' }
        'Firewall' {
            if ($normalized -eq 'Enabled' -or $normalized -eq 'DefaultInboundAction') {
                return 'High'
            }

            if ($normalized -eq 'DefaultOutboundAction') {
                return 'Medium'
            }

            return 'Low'
        }
        'UserAccounts' {
            switch ($normalized) {
                'DisableBuiltInAdministrator' { return 'High' }
                'DisableBuiltInGuest' { return 'High' }
                'MinPasswordLength' { return 'Medium' }
                'PasswordComplexity' { return 'Medium' }
                'MaxPasswordAge' { return 'Low' }
                'LockoutThreshold' { return 'Low' }
                'LockoutDuration' { return 'Low' }
                'LockoutObservationWindow' { return 'Low' }
                default { return 'Low' }
            }
        }
        'WindowsDefender' {
            switch ($normalized) {
                'EnableRealTimeMonitoring' { return 'High' }
                'EnableTamperProtection' { return 'High' }
                'EnableCloudProtection' { return 'Medium' }
                'EnableNetworkProtection' { return 'Medium' }
                'EnableControlledFolderAccess' { return 'Medium' }
                'PUAProtection' { return 'Medium' }
                'CloudBlockLevel' { return 'Low' }
                default { return 'Low' }
            }
        }
        'NetworkHardening' {
            switch ($normalized) {
                'DisableSMBv1' { return 'High' }
                'DisableNTLMv1' { return 'High' }
                'DisableLLMNR' { return 'Medium' }
                'DisableNetBIOS' { return 'Medium' }
                'DisableWPAD' { return 'Medium' }
                'MinimumTLSVersion' { return 'Medium' }
                'DisableRC4' { return 'Medium' }
                default { return 'Low' }
            }
        }
        default { return 'Low' }
    }
}

function New-DriftItem {
    param(
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Setting,
        $ExpectedValue,
        $CurrentValue
    )

    return [PSCustomObject]@{
        Category      = $Category
        Setting       = $Setting
        ExpectedValue = ConvertTo-DisplayString -Value $ExpectedValue
        CurrentValue  = ConvertTo-DisplayString -Value $CurrentValue
        Timestamp     = Get-Date -Format 'o'
        RiskLevel     = Get-RiskLevel -Category $Category -Setting $Setting
    }
}

function Add-DriftIfNeeded {
    param(
        [Parameter(Mandatory)] [System.Collections.Generic.List[object]] $Collection,
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [string] $Setting,
        $ExpectedValue,
        $CurrentValue
    )

    if ((ConvertTo-ComparableString -Value $ExpectedValue) -ne (ConvertTo-ComparableString -Value $CurrentValue)) {
        $drift = New-DriftItem -Category $Category -Setting $Setting -ExpectedValue $ExpectedValue -CurrentValue $CurrentValue
        $Collection.Add($drift)
        Write-Log ("Drift detected: {0}/{1} | Expected={2} | Current={3} | Risk={4}" -f `
            $drift.Category, $drift.Setting, $drift.ExpectedValue, $drift.CurrentValue, $drift.RiskLevel) -Level WARNING
    }
}

function Find-ModuleScript {
    param([Parameter(Mandatory)] [string] $Category)

    if ($Category -notin $script:AllowedModuleCategories) {
        throw "Invalid remediation category: '$Category'."
    }

    $modulePath = Join-Path $PSScriptRoot "modules\$Category"
    $resolvedModulesRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot 'modules') -ErrorAction Stop).Path
    $resolvedModulePath = (Resolve-Path -Path $modulePath -ErrorAction Stop).Path

    if (-not $resolvedModulePath.StartsWith($resolvedModulesRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Module path escapes expected root: '$resolvedModulePath'."
    }

    $candidate = Get-ChildItem -LiteralPath $resolvedModulePath -Filter 'Set-*.ps1' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $candidate) {
        throw "No remediation script was found for module '$Category'."
    }

    $resolvedScriptPath = (Resolve-Path -Path $candidate.FullName -ErrorAction Stop).Path
    if (-not $resolvedScriptPath.StartsWith($resolvedModulesRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Resolved remediation script escapes expected root: '$resolvedScriptPath'."
    }

    return $resolvedScriptPath
}

function Invoke-Remediation {
    param(
        [Parameter(Mandatory)] [string[]] $Categories,
        [Parameter(Mandatory)] [PSCustomObject] $Baseline,
        [Parameter(Mandatory)] [PSCustomObject] $Settings
    )

    $results = New-Object System.Collections.Generic.List[object]

    if (-not $Settings.remediation.autoRemediationEnabled) {
        Write-Log 'Auto-remediation is disabled in settings.json.' -Level INFO
        return $results
    }

    foreach ($category in ($Categories | Sort-Object -Unique)) {
        $moduleSettings = $Settings.remediation.modules.$category
        if (-not $moduleSettings -or -not $moduleSettings.autoRemediate) {
            Write-Log "Auto-remediation skipped for $category because it is disabled for that module." -Level INFO
            $results.Add([PSCustomObject]@{
                Category = $category
                Status   = 'Skipped'
                Message  = 'Module auto-remediation disabled'
            })
            continue
        }

        try {
            $scriptPath = Find-ModuleScript -Category $category
            Write-Log ("Running remediation module for {0}: {1}" -f $category, $scriptPath) -Level INFO
            $moduleResult = & $scriptPath -Config $Baseline
            $results.Add([PSCustomObject]@{
                Category = $category
                Status   = 'Applied'
                Message  = (ConvertTo-Json -InputObject $moduleResult -Depth 6 -Compress)
            })
            Write-Log "Remediation applied for $category." -Level SUCCESS
        } catch {
            $results.Add([PSCustomObject]@{
                Category = $category
                Status   = 'Failed'
                Message  = $_.Exception.Message
            })
            Write-Log ("Remediation failed for {0}: {1}" -f $category, $_.Exception.Message) -Level ERROR
        }
    }

    return $results
}

function Export-DriftReport {
    param(
        [Parameter(Mandatory)] [System.Collections.Generic.List[object]] $Drifts,
        [Parameter(Mandatory)] [string] $OutputPath,
        [System.Collections.Generic.List[object]] $RemediationResults = $null
    )

    if ($null -eq $RemediationResults) {
        $RemediationResults = New-Object System.Collections.Generic.List[object]
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add('# Drift Detection Report')
    $lines.Add('')
    $lines.Add("| Field | Value |")
    $lines.Add("| --- | --- |")
    $lines.Add("| Generated | $timestamp |")
    $lines.Add(("| Computer | {0} |" -f $env:COMPUTERNAME))
    $lines.Add("| Drift Count | $($Drifts.Count) |")

    if ($Drifts.Count -eq 0) {
        $lines.Add('')
        $lines.Add('No security drift was detected.')
    } else {
        $lines.Add('')
        $lines.Add('| Category | Setting | Expected | Current | Risk | Timestamp |')
        $lines.Add('| --- | --- | --- | --- | --- | --- |')
        foreach ($drift in $Drifts) {
            $lines.Add("| $(Escape-Markdown $drift.Category) | $(Escape-Markdown $drift.Setting) | $(Escape-Markdown $drift.ExpectedValue) | $(Escape-Markdown $drift.CurrentValue) | $(Escape-Markdown $drift.RiskLevel) | $(Escape-Markdown $drift.Timestamp) |")
        }
    }

    if ($RemediationResults.Count -gt 0) {
        $lines.Add('')
        $lines.Add('## Remediation')
        $lines.Add('')
        $lines.Add('| Category | Status | Message |')
        $lines.Add('| --- | --- | --- |')
        foreach ($result in $RemediationResults) {
            $lines.Add("| $(Escape-Markdown $result.Category) | $(Escape-Markdown $result.Status) | $(Escape-Markdown $result.Message) |")
        }
    }

    $resolvedOutputPath = Resolve-LocalPath -Path $OutputPath -PathType Any -RequiredExtension '.md'
    $parentDir = Split-Path -Path $resolvedOutputPath -Parent
    if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
        New-Item -ItemType Directory -Path $parentDir -Force -ErrorAction Stop | Out-Null
    }

    Set-Content -LiteralPath $resolvedOutputPath -Value $lines -Encoding UTF8 -ErrorAction Stop
}

function Send-DriftToast {
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Message
    )

    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null

        $safeTitle = [System.Security.SecurityElement]::Escape($Title)
        $safeMessage = [System.Security.SecurityElement]::Escape($Message)
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$safeTitle</text><text>$safeMessage</text></binding></visual></toast>")

        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Win11-SecOps-Baseline')
        $notifier.Show($toast)
        Write-Log 'Desktop toast notification sent.' -Level SUCCESS
    } catch {
        Write-Log "Failed to send drift toast notification: $($_.Exception.Message)" -Level WARNING
    }
}

function Update-BaselineFile {
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Baseline,
        [Parameter(Mandatory)] [string] $Path
    )

    $snapshot = Get-SecOpsBaselineSnapshot -Baseline $Baseline
    $preview = $snapshot | ConvertTo-Json -Depth 10

    Write-Host '' -ForegroundColor Gray
    Write-Host 'Current system snapshot preview:' -ForegroundColor Cyan
    Write-Host $preview -ForegroundColor Gray
    Write-Host '' -ForegroundColor Gray

    $confirmation = Read-Host 'Type YES to overwrite baseline.json'
    if ($confirmation -cne 'YES') {
        Write-Log 'Baseline update cancelled by user.' -Level WARNING
        return
    }

    $resolvedBaselinePath = Resolve-LocalPath -Path $Path -PathType File -RequiredExtension '.json'

    if (Test-Path -LiteralPath $resolvedBaselinePath) {
        $backupPath = '{0}.bak.{1}' -f $Path, (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $resolvedBaselinePath -Destination $backupPath -Force
        Write-Log "Existing baseline backed up to $backupPath" -Level SUCCESS
    }

    $snapshot | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resolvedBaselinePath -Encoding UTF8 -ErrorAction Stop
    Write-Log "baseline.json updated with the current system snapshot: $resolvedBaselinePath" -Level SUCCESS
}

if (-not (Test-IsAdministrator)) {
    Write-Host '[WARNING] 03-drift-detector.ps1 must be run as Administrator. Exiting.' -ForegroundColor Yellow
    exit 1
}

$resolvedBaselinePath = Resolve-LocalPath -Path $BaselinePath -PathType File -RequiredExtension '.json'
$resolvedSettingsPath = Resolve-LocalPath -Path $SettingsPath -PathType File -RequiredExtension '.json'

$baseline = Get-Content -LiteralPath $resolvedBaselinePath -Raw -ErrorAction Stop | ConvertFrom-Json
$settings = Get-Content -LiteralPath $resolvedSettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json

$resolvedReportDir = $ReportDir
if ([string]::IsNullOrWhiteSpace($resolvedReportDir)) {
    $resolvedReportDir = $settings.reporting.outputPath
}

$resolvedLogDir = $settings.logging.logPath
$resolvedReportDir = Resolve-LocalPath -Path $resolvedReportDir -PathType Any
$resolvedLogDir = Resolve-LocalPath -Path $resolvedLogDir -PathType Any

if (-not (Test-Path -LiteralPath $resolvedReportDir)) {
    New-Item -ItemType Directory -Path $resolvedReportDir -Force -ErrorAction Stop | Out-Null
}

if (-not (Test-Path -LiteralPath $resolvedLogDir)) {
    New-Item -ItemType Directory -Path $resolvedLogDir -Force -ErrorAction Stop | Out-Null
}

$script:LogPath = Join-Path $resolvedLogDir 'drift-detector.log'
Write-Log ("Drift detection session started on {0} by {1}" -f $env:COMPUTERNAME, $env:USERNAME) -Level INFO

if ($UpdateBaseline) {
    Update-BaselineFile -Baseline $baseline -Path $resolvedBaselinePath
    return
}

$drifts = New-Object System.Collections.Generic.List[object]

$currentAuditPolicies = Get-SecOpsAuditPoliciesState
$currentFirewallStates = Get-SecOpsFirewallStates -Profiles $baseline.Firewall.Profiles
$currentUserAccounts = Get-SecOpsUserAccountsState
$currentWindowsDefender = Get-SecOpsWindowsDefenderState
$currentNetworkHardening = Get-SecOpsNetworkHardeningState

foreach ($property in $baseline.AuditPolicies.PSObject.Properties.Name) {
    Add-DriftIfNeeded -Collection $drifts -Category 'AuditPolicies' -Setting $property `
        -ExpectedValue $baseline.AuditPolicies.$property -CurrentValue $currentAuditPolicies[$property]
}

foreach ($profileName in $baseline.Firewall.Profiles) {
    $profileState = $currentFirewallStates[$profileName]
    Add-DriftIfNeeded -Collection $drifts -Category 'Firewall' -Setting "Enabled[$profileName]" `
        -ExpectedValue $true -CurrentValue $profileState.Enabled

    foreach ($property in @('DefaultInboundAction', 'DefaultOutboundAction', 'NotifyOnBlock', 'LogAllowed', 'LogBlocked', 'LogMaxSizeKilobytes')) {
        Add-DriftIfNeeded -Collection $drifts -Category 'Firewall' -Setting ("{0}[{1}]" -f $property, $profileName) `
            -ExpectedValue $baseline.Firewall.$property -CurrentValue $profileState.$property
    }
}

foreach ($property in $baseline.UserAccounts.PSObject.Properties.Name) {
    Add-DriftIfNeeded -Collection $drifts -Category 'UserAccounts' -Setting $property `
        -ExpectedValue $baseline.UserAccounts.$property -CurrentValue $currentUserAccounts[$property]
}

foreach ($property in $baseline.WindowsDefender.PSObject.Properties.Name) {
    Add-DriftIfNeeded -Collection $drifts -Category 'WindowsDefender' -Setting $property `
        -ExpectedValue $baseline.WindowsDefender.$property -CurrentValue $currentWindowsDefender[$property]
}

foreach ($property in $baseline.NetworkHardening.PSObject.Properties.Name) {
    Add-DriftIfNeeded -Collection $drifts -Category 'NetworkHardening' -Setting $property `
        -ExpectedValue $baseline.NetworkHardening.$property -CurrentValue $currentNetworkHardening[$property]
}

$remediationResults = New-Object System.Collections.Generic.List[object]
if ($drifts.Count -gt 0) {
    $remediationResults = Invoke-Remediation -Categories ($drifts | ForEach-Object { $_.Category }) -Baseline $baseline -Settings $settings
}

$reportPath = Join-Path $resolvedReportDir ('drift-report-{0}.md' -f (Get-Date -Format 'yyyy-MM-dd'))
Export-DriftReport -Drifts $drifts -OutputPath $reportPath -RemediationResults $remediationResults

if ($drifts.Count -gt 0) {
    Write-Log "Drift detected across $($drifts.Count) setting(s). Report: $reportPath" -Level WARNING
    if ($settings.notifications.desktop.enabled) {
        Send-DriftToast -Title $settings.notifications.desktop.toastTitle -Message "$($drifts.Count) security setting(s) drifted from baseline."
    }
} else {
    Write-Log "No drift detected. Report: $reportPath" -Level SUCCESS
}
