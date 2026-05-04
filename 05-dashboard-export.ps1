#Requires -Version 5.1
<#
.SYNOPSIS
    Generates a professional dark-theme SOC HTML dashboard from the latest posture report.

.DESCRIPTION
    Reads the latest posture-check markdown report, extracts score, trend, timestamp,
    checks, and top failed controls, then renders an HTML dashboard and opens it
    in the default browser.

.PARAMETER ReportPath
    Optional explicit posture report markdown path.

.PARAMETER ReportDir
    Optional report directory. Defaults to settings.json reporting.outputPath.

.PARAMETER OutputPath
    Optional output HTML path. Defaults to <ReportDir>\security-dashboard.html.

.PARAMETER NoOpen
    Do not auto-open the generated dashboard in browser.
#>
[CmdletBinding()]
param(
    [string] $ReportPath,
    [string] $ReportDir,
    [string] $OutputPath,
    [switch] $NoOpen
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

function Write-Status {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string] $Level = 'INFO'
    )

    switch ($Level) {
        'SUCCESS' { Write-Host $Message -ForegroundColor Green }
        'WARNING' { Write-Host $Message -ForegroundColor Yellow }
        'ERROR'   { Write-Host $Message -ForegroundColor Red }
        default   { Write-Host $Message -ForegroundColor Gray }
    }
}

function Get-ConfiguredReportDirectory {
    param([Parameter(Mandatory)] [string] $SettingsPath)

  $resolvedSettingsPath = Resolve-LocalPath -Path $SettingsPath -PathType File -RequiredExtension '.json'
  $settings = Get-Content -LiteralPath $resolvedSettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json
    return $settings.reporting.outputPath
}

function Get-LatestPostureReport {
    param([Parameter(Mandatory)] [string] $Directory)

    $report = Get-ChildItem -Path $Directory -Filter 'posture-report-*.md' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $report) {
        throw "No posture report was found in '$Directory'. Run 02-posture-check.ps1 first."
    }

    return $report.FullName
}

function ConvertTo-StatusClass {
    param([string] $Status)

    switch (($Status | ForEach-Object { $_.ToUpperInvariant() })) {
        'PASS'    { return 'status-pass' }
        'FAIL'    { return 'status-fail' }
        'WARNING' { return 'status-warning' }
        default   { return 'status-unknown' }
    }
}

function ConvertTo-EscapedHtml {
  param([AllowNull()] $Value)

  if ($null -eq $Value) {
    return 'N/A'
  }

  return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Get-TrendMetadata {
    param(
        [string] $Trend,
        [string] $DeltaText
    )

    $normalizedTrend = ''
    if ($Trend) {
        $normalizedTrend = $Trend.Trim().ToLowerInvariant()
    }

    switch ($normalizedTrend) {
        'improved' {
            return [PSCustomObject]@{ Arrow = '---'; CssClass = 'trend-up'; Label = 'Improved'; Delta = $DeltaText }
        }
        'degraded' {
            return [PSCustomObject]@{ Arrow = '---'; CssClass = 'trend-down'; Label = 'Degraded'; Delta = $DeltaText }
        }
        'no change' {
            return [PSCustomObject]@{ Arrow = '---'; CssClass = 'trend-flat'; Label = 'No change'; Delta = $DeltaText }
        }
        default {
            return [PSCustomObject]@{ Arrow = '---'; CssClass = 'trend-flat'; Label = 'First scan'; Delta = 'N/A' }
        }
    }
}

function ConvertFrom-PostureMarkdown {
    param([Parameter(Mandatory)] [string] $Content)

    $lines = $Content -split "`r?`n"
    $fieldMap = @{}
    $checks = New-Object System.Collections.Generic.List[object]

    $inSummaryChecks = $false
    foreach ($rawLine in $lines) {
        $line = $rawLine.Trim()
        if (-not $line) { continue }

        if ($line -eq '## Summary Checks') {
            $inSummaryChecks = $true
            continue
        }

        if ($line -match '^##\s+' -and $line -ne '## Summary Checks') {
            $inSummaryChecks = $false
        }

        if ($line -match '^\|\s*Field\s*\|\s*Value\s*\|') { continue }
        if ($line -match '^\|\s*---') { continue }

        if ($inSummaryChecks -and $line -match '^\|') {
            $parts = $line.Split('|')
            if ($parts.Count -ge 6) {
                $checkName = $parts[1].Trim()
                $status = $parts[2].Trim()
                $points = $parts[3].Trim()
                $detail = $parts[4].Trim()

                if ($checkName -and $checkName -ne 'Check') {
                    $checks.Add([PSCustomObject]@{
                        Check  = $checkName
                        Status = $status
                        Points = $points
                        Detail = $detail
                    })
                }
            }
            continue
        }

        if ($line -match '^\|\s*(?<field>[^|]+?)\s*\|\s*(?<value>[^|]+?)\s*\|$') {
            $field = $matches.field.Trim()
            $value = $matches.value.Trim()
            if ($field -ne 'Field' -and $value -ne 'Value') {
                $fieldMap[$field] = $value
            }
        }
    }

    if (-not $fieldMap.ContainsKey('Score')) {
        throw 'Could not parse score from posture report.'
    }

    $scoreMatch = [regex]::Match($fieldMap['Score'], '(\d+)\s*/\s*100')
    if (-not $scoreMatch.Success) {
        throw 'Could not parse numeric score from posture report.'
    }

    $score = [int] $scoreMatch.Groups[1].Value
    $generated = if ($fieldMap.ContainsKey('Generated')) { $fieldMap['Generated'] } else { 'Unknown' }
    $trend = if ($fieldMap.ContainsKey('Trend')) { $fieldMap['Trend'] } else { 'First scan' }
    $delta = if ($fieldMap.ContainsKey('Delta')) { $fieldMap['Delta'] } else { 'N/A' }

    return [PSCustomObject]@{
        Score     = $score
        Generated = $generated
        Trend     = $trend
        Delta     = $delta
        Checks    = $checks
    }
}

function New-DashboardHtml {
    param([Parameter(Mandatory)] $Data)

    $trendMeta = Get-TrendMetadata -Trend $Data.Trend -DeltaText $Data.Delta
    $progressWidth = [Math]::Min([Math]::Max($Data.Score, 0), 100)

    $checkRows = New-Object System.Collections.Generic.List[string]
    foreach ($check in $Data.Checks) {
        $statusClass = ConvertTo-StatusClass -Status $check.Status
        $safeCheck = ConvertTo-EscapedHtml -Value $check.Check
        $safeStatus = ConvertTo-EscapedHtml -Value $check.Status
        $safePoints = ConvertTo-EscapedHtml -Value ([string]$check.Points)
        $safeDetail = ConvertTo-EscapedHtml -Value $check.Detail
        $checkRows.Add(@"
        <tr>
          <td>$safeCheck</td>
          <td><span class="status-pill $statusClass">$safeStatus</span></td>
          <td>$safePoints</td>
          <td>$safeDetail</td>
        </tr>
"@)
    }

    $topRisks = $Data.Checks | Where-Object { $_.Status -eq 'FAIL' } | Select-Object -First 3
    $riskItems = New-Object System.Collections.Generic.List[string]
    if (($topRisks | Measure-Object).Count -eq 0) {
        $riskItems.Add('<li>No failed checks in latest scan.</li>')
    } else {
        foreach ($risk in $topRisks) {
        $safeRiskCheck = ConvertTo-EscapedHtml -Value $risk.Check
        $safeRiskDetail = ConvertTo-EscapedHtml -Value $risk.Detail
        $riskItems.Add("<li><strong>$safeRiskCheck</strong> - $safeRiskDetail</li>")
        }
    }

    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
    $safeGenerated = ConvertTo-EscapedHtml -Value ([string]$Data.Generated)
    $safeScore = ConvertTo-EscapedHtml -Value ([string]$Data.Score)
    $safeTrendLabel = ConvertTo-EscapedHtml -Value $trendMeta.Label
    $safeTrendDelta = ConvertTo-EscapedHtml -Value ([string]$trendMeta.Delta)
    $safeGeneratedAt = ConvertTo-EscapedHtml -Value $generatedAt
@"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Win11-SecOps Dashboard</title>
  <style>
    :root {
      --bg: #0d1117;
      --panel: #161b22;
      --panel-2: #1f2631;
      --text: #e6edf3;
      --muted: #9da7b3;
      --accent: #2f81f7;
      --success: #3fb950;
      --warning: #d29922;
      --danger: #f85149;
      --border: #30363d;
      --shadow: 0 8px 24px rgba(1, 4, 9, 0.5);
    }

    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif;
      background: radial-gradient(1200px 600px at 20% -20%, #1f2a3f 0%, var(--bg) 55%);
      color: var(--text);
    }

    .container {
      max-width: 1200px;
      margin: 0 auto;
      padding: 28px 22px 40px;
    }

    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 18px;
      margin-bottom: 20px;
    }

    .title {
      margin: 0;
      font-size: 28px;
      font-weight: 700;
      letter-spacing: 0.4px;
    }

    .subtle {
      color: var(--muted);
      font-size: 13px;
    }

    .grid {
      display: grid;
      grid-template-columns: repeat(12, 1fr);
      gap: 16px;
    }

    .card {
      background: linear-gradient(180deg, var(--panel), var(--panel-2));
      border: 1px solid var(--border);
      border-radius: 12px;
      box-shadow: var(--shadow);
      padding: 18px;
    }

    .kpi { grid-column: span 8; }
    .trend { grid-column: span 4; }
    .risks { grid-column: span 4; }
    .checks { grid-column: span 8; }

    .label {
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 1px;
    }

    .score {
      font-size: 42px;
      font-weight: 800;
      margin-top: 8px;
    }

    .progress {
      margin-top: 14px;
      height: 16px;
      border-radius: 999px;
      overflow: hidden;
      background: #0f141c;
      border: 1px solid var(--border);
    }

    .progress-bar {
      height: 100%;
      width: $progressWidth%;
      background: linear-gradient(90deg, #1f6feb, #2ea043);
    }

    .trend-arrow {
      font-size: 36px;
      font-weight: 800;
      line-height: 1;
      margin: 10px 0 8px;
    }

    .trend-up { color: var(--success); }
    .trend-down { color: var(--danger); }
    .trend-flat { color: var(--warning); }

    .status-pill {
      padding: 4px 10px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 700;
      display: inline-block;
      letter-spacing: 0.3px;
    }

    .status-pass { background: rgba(63,185,80,0.2); color: #7ee787; border: 1px solid rgba(63,185,80,0.4); }
    .status-fail { background: rgba(248,81,73,0.2); color: #ff938b; border: 1px solid rgba(248,81,73,0.45); }
    .status-warning { background: rgba(210,153,34,0.2); color: #f2cc60; border: 1px solid rgba(210,153,34,0.45); }
    .status-unknown { background: rgba(157,167,179,0.2); color: #c9d1d9; border: 1px solid rgba(157,167,179,0.45); }

    ul.risk-list {
      margin: 12px 0 0;
      padding-left: 18px;
      line-height: 1.6;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 10px;
      font-size: 14px;
    }

    th, td {
      text-align: left;
      border-bottom: 1px solid var(--border);
      padding: 10px 8px;
      vertical-align: top;
    }

    th {
      color: #c9d1d9;
      font-weight: 700;
      background: rgba(255,255,255,0.02);
    }

    .footer {
      margin-top: 18px;
      color: var(--muted);
      font-size: 12px;
    }

    @media (max-width: 980px) {
      .kpi, .trend, .risks, .checks { grid-column: span 12; }
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div>
        <h1 class="title">Win11-SecOps Security Dashboard</h1>
        <div class="subtle">Professional SOC View --- Last scan: $safeGenerated</div>
      </div>
      <div class="subtle">Generated: $safeGeneratedAt</div>
    </div>

    <div class="grid">
      <section class="card kpi">
        <div class="label">Overall Security Score</div>
        <div class="score">$safeScore<span class="subtle">/100</span></div>
        <div class="progress"><div class="progress-bar"></div></div>
      </section>

      <section class="card trend">
        <div class="label">Trend Since Last Scan</div>
        <div class="trend-arrow $($trendMeta.CssClass)">$($trendMeta.Arrow)</div>
        <div><strong>$safeTrendLabel</strong></div>
        <div class="subtle">Delta: $safeTrendDelta</div>
      </section>

      <section class="card checks">
        <div class="label">Security Checks</div>
        <table>
          <thead>
            <tr>
              <th>Check</th>
              <th>Status</th>
              <th>Points</th>
              <th>Detail</th>
            </tr>
          </thead>
          <tbody>
$($checkRows -join [Environment]::NewLine)
          </tbody>
        </table>
      </section>

      <section class="card risks">
        <div class="label">Top 3 Risks</div>
        <ul class="risk-list">
$($riskItems -join [Environment]::NewLine)
        </ul>
      </section>
    </div>

    <div class="footer">Source: Posture report markdown exported by 02-posture-check.ps1</div>
  </div>
</body>
</html>
"@
}

$settingsPath = Join-Path $PSScriptRoot 'config\settings.json'
$resolvedReportDir = $ReportDir
if ([string]::IsNullOrWhiteSpace($resolvedReportDir)) {
    $resolvedReportDir = Get-ConfiguredReportDirectory -SettingsPath $settingsPath
}

$resolvedReportDir = Resolve-LocalPath -Path $resolvedReportDir -PathType Directory

$resolvedReportPath = $ReportPath
if ([string]::IsNullOrWhiteSpace($resolvedReportPath)) {
    $resolvedReportPath = Get-LatestPostureReport -Directory $resolvedReportDir
}

$resolvedReportPath = Resolve-LocalPath -Path $resolvedReportPath -PathType File -RequiredExtension '.md'

$resolvedOutputPath = $OutputPath
if ([string]::IsNullOrWhiteSpace($resolvedOutputPath)) {
    $resolvedOutputPath = Join-Path $resolvedReportDir 'security-dashboard.html'
}

$resolvedOutputPath = Resolve-LocalPath -Path $resolvedOutputPath -PathType Any -RequiredExtension '.html'
$outputParentDir = Split-Path -Path $resolvedOutputPath -Parent
if (-not (Test-Path -LiteralPath $outputParentDir -PathType Container)) {
  New-Item -ItemType Directory -Path $outputParentDir -Force -ErrorAction Stop | Out-Null
}

$reportContent = Get-Content -LiteralPath $resolvedReportPath -Raw -ErrorAction Stop
$parsed = ConvertFrom-PostureMarkdown -Content $reportContent
$html = New-DashboardHtml -Data $parsed

Set-Content -LiteralPath $resolvedOutputPath -Value $html -Encoding UTF8 -ErrorAction Stop
Write-Status "Dashboard generated: $resolvedOutputPath" -Level SUCCESS
Write-Status "Source report: $resolvedReportPath" -Level INFO

if (-not $NoOpen) {
  Start-Process -FilePath $resolvedOutputPath -ErrorAction Stop
    Write-Status 'Dashboard opened in default browser.' -Level SUCCESS
}


