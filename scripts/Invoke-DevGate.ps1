#Requires -Version 5.1
<##
.SYNOPSIS
    Invoke-DevGate.ps1

.DESCRIPTION
    Runs local developer quality gates for parse validation, tests, and optional integrity checking.

.NOTES
    Gap addressed: Gap 5 - Rollback Strategy and Phase Gates
    Date created: 2026-04-28
    #Requires -Version 5.1
##>

[CmdletBinding()]
param(
    [switch] $SkipTests,
    [switch] $SkipIntegrity,
    [string] $TestPath = 'tests'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$integrityScript = Join-Path $projectRoot 'src\core\IntegrityVerification.ps1'
if (Test-Path -LiteralPath $integrityScript -PathType Leaf) {
    . $integrityScript
}

$parseStatus = 'SKIPPED'
$parseCount = 0
$testStatus = 'SKIPPED'
$testsPassed = 0
$testsFailed = 0
$integrityStatus = 'SKIPPED'
$integritySummary = 'SKIPPED'

$exitCode = 0

function Show-Summary {
    Write-Host ''
    Write-Host 'Development Gate Summary'
    Write-Host ("[{0}] Parse Check      - {1} files checked" -f $parseStatus, $parseCount)
    Write-Host ("[{0}] Test Suite       - {1} passed, {2} failed" -f $testStatus, $testsPassed, $testsFailed)
    Write-Host ("[{0}] Integrity Check  - {1}" -f $integrityStatus, $integritySummary)

    if ($exitCode -eq 0) {
        Write-Host 'Overall: GATE PASSED'
    } else {
        Write-Host 'Overall: GATE FAILED'
    }
}

function Get-TestCountValue {
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)] [string[]] $CandidateProperties,
        [Parameter(Mandatory)] [scriptblock] $FallbackCalculator
    )

    foreach ($name in $CandidateProperties) {
        if ($Result.PSObject.Properties.Match($name).Count -gt 0) {
            return [int]$Result.$name
        }
    }

    return [int](& $FallbackCalculator $Result)
}

if (Get-Command -Name git -ErrorAction SilentlyContinue) {
    Push-Location $projectRoot
    try {
        $gitStatus = & git status --porcelain
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($gitStatus | Out-String))) {
            Write-Warning 'Uncommitted changes detected. Continuing with gate checks.'
        }
    } finally {
        Pop-Location
    }
} else {
    Write-Warning 'Git is not available. Skipping git status visibility check.'
}

$psFiles = Get-ChildItem -Path $projectRoot -Recurse -File -Filter '*.ps1'
$parseCount = $psFiles.Count
$parseErrors = New-Object System.Collections.Generic.List[string]
foreach ($file in $psFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) {
        foreach ($errorRecord in $errors) {
            $parseErrors.Add(("{0}:{1}:{2} {3}" -f $file.FullName, $errorRecord.Extent.StartLineNumber, $errorRecord.Extent.StartColumnNumber, $errorRecord.Message))
        }
    }
}

if ($parseErrors.Count -gt 0) {
    $parseStatus = 'FAIL'
    $exitCode = 1
    $parseErrors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Show-Summary
    [Environment]::Exit($exitCode)
}

$parseStatus = 'PASS'

if (-not $SkipTests) {
    $resolvedTestPath = Resolve-Path -Path (Join-Path $projectRoot $TestPath) -ErrorAction SilentlyContinue
    if (-not $resolvedTestPath) {
        $testStatus = 'FAIL'
        $exitCode = 2
        Write-Host ("Test path not found: {0}" -f (Join-Path $projectRoot $TestPath)) -ForegroundColor Red
        Show-Summary
        [Environment]::Exit($exitCode)
    }

    $pesterModule = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -eq [version]'3.4.0' } | Select-Object -First 1
    if (-not $pesterModule) {
        throw 'Required Pester version 3.4.0 was not found. Install it with: Install-Module Pester -RequiredVersion 3.4.0 -Scope CurrentUser -Force -SkipPublisherCheck'
    }

    # Unload any currently loaded Pester (including Pester 5 which the runner may have auto-loaded)
    # then import 3.4.0 by its explicit manifest path to bypass module-path version-priority issues.
    Remove-Module Pester -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $pesterModule.ModuleBase 'Pester.psd1') -Force -ErrorAction Stop
    $testResult = Invoke-Pester -Path $resolvedTestPath.Path -PassThru
    if ($null -eq $testResult) {
        throw 'Pester did not return a test result object. Ensure Pester is installed correctly.'
    }

    $testsPassed = Get-TestCountValue -Result $testResult -CandidateProperties @('PassedCount', 'Passed') -FallbackCalculator {
        param($result)
        if ($result.PSObject.Properties.Match('TestResult').Count -gt 0 -and $null -ne $result.TestResult) {
            return @($result.TestResult | Where-Object { $_.Result -eq 'Passed' }).Count
        }

        return 0
    }

    $testsFailed = Get-TestCountValue -Result $testResult -CandidateProperties @('FailedCount', 'Failed') -FallbackCalculator {
        param($result)
        if ($result.PSObject.Properties.Match('TestResult').Count -gt 0 -and $null -ne $result.TestResult) {
            return @($result.TestResult | Where-Object { $_.Result -eq 'Failed' }).Count
        }

        return 0
    }

    if ($testsFailed -gt 0) {
        $testStatus = 'FAIL'
        $exitCode = 2
        Show-Summary
        [Environment]::Exit($exitCode)
    }

    $testStatus = 'PASS'
} else {
    $testStatus = 'SKIPPED'
}

if (-not $SkipIntegrity) {
    $manifestPath = Join-Path $projectRoot 'config\module-hashes.json'
    if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and (Get-Command -Name Test-ModuleIntegrity -ErrorAction SilentlyContinue)) {
        $integrityResult = Test-ModuleIntegrity -ManifestPath $manifestPath -ProjectRoot $projectRoot
        if ($integrityResult.Passed) {
            $integrityStatus = 'PASS'
            $integritySummary = ("{0} files verified" -f $integrityResult.CheckedCount)
        } else {
            $integrityStatus = 'FAIL'
            $integritySummary = ("{0} files verified, violations: {1}" -f $integrityResult.CheckedCount, ($integrityResult.Violations -join ', '))
            $exitCode = 3
            Show-Summary
            [Environment]::Exit($exitCode)
        }
    } else {
        $integrityStatus = 'SKIPPED'
        $integritySummary = 'SKIPPED'
    }
} else {
    $integrityStatus = 'SKIPPED'
    $integritySummary = 'SKIPPED'
}

Show-Summary
[Environment]::Exit($exitCode)
