#Requires -Version 5.1
<##
.SYNOPSIS
    IntegrityVerification.ps1

.DESCRIPTION
    Provides hash manifest generation and integrity gate checks for module/script tampering detection.

.NOTES
    Gap addressed: Gap 2 - Module Integrity Verification
    Date created: 2026-04-28
    #Requires -Version 5.1
##>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-ModuleHashManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [Parameter(Mandatory)] [string] $OutputPath
    )

    $resolvedRoot = (Resolve-Path -Path $ProjectRoot -ErrorAction Stop).Path
    $scanTargets = @(
        (Join-Path $resolvedRoot 'src'),
        (Join-Path $resolvedRoot 'modules')
    )

    $hashMap = [ordered]@{}

    foreach ($target in $scanTargets) {
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            continue
        }

        $files = Get-ChildItem -LiteralPath $target -Recurse -File -Filter '*.ps1' | Sort-Object FullName
        foreach ($file in $files) {
            $relativePath = $file.FullName.Substring($resolvedRoot.Length).TrimStart('\') -replace '\\', '/'
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            $hashMap[$relativePath] = $hash
        }
    }

    $manifest = [ordered]@{
        generated = (Get-Date).ToString('o')
        generatedBy = [Environment]::UserName
        hashes = $hashMap
    }

    $outputDir = Split-Path -Path $OutputPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDir -Force -ErrorAction Stop | Out-Null
    }

    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8 -ErrorAction Stop
    return $manifest
}

function Test-ModuleIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManifestPath,
        [Parameter(Mandatory)] [string] $ProjectRoot
    )

    $violations = New-Object System.Collections.Generic.List[string]
    $checkedCount = 0

    try {
        $resolvedRoot = (Resolve-Path -Path $ProjectRoot -ErrorAction Stop).Path
    } catch {
        $violations.Add('Project root not found.')
        return [PSCustomObject]@{
            Passed = $false
            Violations = @($violations)
            CheckedCount = 0
            Timestamp = (Get-Date).ToString('o')
        }
    }

    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        $violations.Add('Manifest could not be loaded or parsed.')
        return [PSCustomObject]@{
            Passed = $false
            Violations = @($violations)
            CheckedCount = 0
            Timestamp = (Get-Date).ToString('o')
        }
    }

    if (-not $manifest.hashes) {
        $violations.Add('Manifest does not contain a hashes object.')
        return [PSCustomObject]@{
            Passed = $false
            Violations = @($violations)
            CheckedCount = 0
            Timestamp = (Get-Date).ToString('o')
        }
    }

    foreach ($property in $manifest.hashes.PSObject.Properties) {
        $relativePath = $property.Name
        $expectedHash = [string]$property.Value
        $fullPath = Join-Path $resolvedRoot ($relativePath -replace '/', '\\')
        $checkedCount++

        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            $violations.Add($relativePath)
            continue
        }

        $actualHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($actualHash -ne $expectedHash) {
            $violations.Add($relativePath)
        }
    }

    return [PSCustomObject]@{
        Passed = ($violations.Count -eq 0)
        Violations = @($violations)
        CheckedCount = $checkedCount
        Timestamp = (Get-Date).ToString('o')
    }
}

function Invoke-IntegrityGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ManifestPath,
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [switch] $WhatIf
    )

    $result = Test-ModuleIntegrity -ManifestPath $ManifestPath -ProjectRoot $ProjectRoot

    if ($WhatIf) {
        Write-Host ("[WHATIF] Integrity check would verify {0} file(s) using manifest '{1}'." -f $result.CheckedCount, $ManifestPath)
        if (-not $result.Passed) {
            Write-Host ("[WHATIF] Potential violations: {0}" -f ($result.Violations -join ', '))
        }
        return $result
    }

    if (-not $result.Passed) {
        foreach ($violation in $result.Violations) {
            Write-Host ("Integrity violation: {0}" -f $violation) -ForegroundColor Red
        }

        if (Get-Command -Name Write-SecOpsLog -ErrorAction SilentlyContinue) {
            Write-SecOpsLog -Message ("Integrity gate failed with {0} violation(s)." -f $result.Violations.Count) -Level ERROR
        }

        throw ("Integrity gate failed. Violations detected: {0}" -f $result.Violations.Count)
    }

    if (Get-Command -Name Write-SecOpsLog -ErrorAction SilentlyContinue) {
        Write-SecOpsLog -Message ("Integrity gate passed. Checked files: {0}." -f $result.CheckedCount) -Level SUCCESS
    }

    return $result
}
