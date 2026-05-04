#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Win11-SecOps-Baseline — main entry point.

.DESCRIPTION
    Applies Windows 11 security hardening modules defined in config\baseline.json.
    Each module is idempotent and writes timestamped results to reports\.

.PARAMETER Modules
    Comma-separated list of modules to run. Defaults to all modules.
    Valid values: AuditPolicies, Firewall, UserAccounts, WindowsDefender, NetworkHardening

.PARAMETER ReportOnly
    Load and display the most recent report without running any modules.

.EXAMPLE
    .\Invoke-SecBaseline.ps1
    .\Invoke-SecBaseline.ps1 -Modules Firewall, WindowsDefender
    .\Invoke-SecBaseline.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [ValidateSet('AuditPolicies', 'Firewall', 'UserAccounts', 'WindowsDefender', 'NetworkHardening')]
    [string[]] $Modules = @('AuditPolicies', 'Firewall', 'UserAccounts', 'WindowsDefender', 'NetworkHardening'),

    [switch] $ReportOnly,

    [switch] $SkipIntegrityCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'src\core\RunContext.ps1')
. (Join-Path $PSScriptRoot 'src\core\IntegrityVerification.ps1')

$RunContext = New-SecOpsRunContext

try {

$script:RootPath   = $PSScriptRoot
$script:ConfigPath = Join-Path $RootPath 'config\baseline.json'
$script:ReportDir  = Join-Path $RootPath 'reports'
$script:ModuleDir  = Join-Path $RootPath 'modules'
$script:AllowedModules = @('AuditPolicies', 'Firewall', 'UserAccounts', 'WindowsDefender', 'NetworkHardening')

# Explicit script filename map — handles modules whose file name differs from the module name
$script:ModuleScriptMap = @{
    'AuditPolicies'    = 'Set-AuditPolicies.ps1'
    'Firewall'         = 'Set-FirewallBaseline.ps1'
    'UserAccounts'     = 'Set-UserAccounts.ps1'
    'WindowsDefender'  = 'Set-DefenderBaseline.ps1'
    'NetworkHardening' = 'Set-NetworkHardening.ps1'
}

# ── Load config ──────────────────────────────────────────────────────────────
$config = Get-Content -Raw $script:ConfigPath | ConvertFrom-Json

# ── Ensure report directory exists ───────────────────────────────────────────
if (-not (Test-Path $script:ReportDir)) {
    New-Item -ItemType Directory -Path $script:ReportDir | Out-Null
}

# ── ReportOnly shortcut ───────────────────────────────────────────────────────
if ($ReportOnly) {
    $latest = Get-ChildItem $script:ReportDir -Filter '*.json' |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 1
    if ($latest) {
        Get-Content $latest.FullName | ConvertFrom-Json | Format-List
    } else {
        Write-Warning "No reports found in $script:ReportDir"
    }
    return
}

$manifestPath = Join-Path $script:RootPath 'config\module-hashes.json'
if (-not $SkipIntegrityCheck) {
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Invoke-IntegrityGate -ManifestPath $manifestPath -ProjectRoot $script:RootPath | Out-Null
    } else {
        Write-Warning "Integrity manifest not found at $manifestPath. Continuing without integrity check."
    }
}

# ── Run selected modules ──────────────────────────────────────────────────────
$results   = [System.Collections.Generic.List[PSCustomObject]]::new()
$timestamp = Get-Date -Format 'yyyy-MM-ddTHH-mm-ss'

foreach ($moduleName in $Modules) {
    if ($moduleName -notin $script:AllowedModules) {
        Write-Warning "Invalid module requested: $moduleName"
        $results.Add([PSCustomObject]@{ Module = $moduleName; Status = 'Skipped'; Message = 'Invalid module name' })
        continue
    }

    $scriptFile = $script:ModuleScriptMap[$moduleName]
    $scriptPath = Join-Path $script:ModuleDir "$moduleName\$scriptFile"

    if (-not (Test-Path $scriptPath)) {
        Write-Warning "Module script not found: $scriptPath"
        $results.Add([PSCustomObject]@{ Module = $moduleName; Status = 'Skipped'; Message = 'Script not found' })
        continue
    }

    $resolvedModuleRoot = (Resolve-Path -Path $script:ModuleDir -ErrorAction Stop).Path
    $resolvedScriptPath = (Resolve-Path -Path $scriptPath -ErrorAction Stop).Path
    if (-not $resolvedScriptPath.StartsWith($resolvedModuleRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "Module path escaped module root: $resolvedScriptPath"
        $results.Add([PSCustomObject]@{ Module = $moduleName; Status = 'Skipped'; Message = 'Unsafe module path' })
        continue
    }

    Write-Host "▶ Running module: $moduleName" -ForegroundColor Cyan
    try {
        $moduleResult = & $resolvedScriptPath -Config $config -WhatIf:$WhatIfPreference
        $results.Add([PSCustomObject]@{ Module = $moduleName; Status = 'Pass'; Detail = $moduleResult })
    } catch {
        Write-Warning "Module $moduleName failed: $_"
        $results.Add([PSCustomObject]@{ Module = $moduleName; Status = 'Fail'; Message = $_.Exception.Message })
    }
}

# ── Write report ──────────────────────────────────────────────────────────────
$reportPath = Join-Path $script:ReportDir "baseline-report-$timestamp.json"
$report = [PSCustomObject]@{
    GeneratedAt  = (Get-Date -Format 'o')
    ComputerName = $env:COMPUTERNAME
    RunBy        = $env:USERNAME
    WhatIf       = [bool]$WhatIfPreference
    Results      = $results
}
$report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding UTF8

Write-Host "`nOK Baseline run complete. Report: $reportPath" -ForegroundColor Green
$results | Format-Table -AutoSize

} finally {
    Clear-SecOpsRunContext
}
