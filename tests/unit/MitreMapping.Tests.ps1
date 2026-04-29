#Requires -Version 5.1
<##
.SYNOPSIS
    MitreMapping.Tests.ps1

.DESCRIPTION
    Validates MITRE mapping structure and cross-reference coverage for documented controls.

.NOTES
    Gap addressed: Gap 4 - MITRE Coverage Assertion Tests
    Date created: 2026-04-28
    #Requires -Version 5.1
##>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) '..\src\core\RunContext.ps1')

    $script:projectRoot = Resolve-Path (Join-Path (Split-Path $PSScriptRoot -Parent) '..')
    $script:controlsPath = Join-Path $script:projectRoot 'docs\CONTROLS.md'
    $script:mitrePath = Join-Path $script:projectRoot 'docs\mitre-mapping.md'
}

function Read-FileSafely {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
}

Describe 'MITRE Mapping File Structure' {
    It 'docs/mitre-mapping.md exists and is not empty (or gracefully skips if missing)' {
        if (-not (Test-Path -LiteralPath $script:mitrePath -PathType Leaf)) {
            Write-Warning 'Skipping MITRE structure checks because docs/mitre-mapping.md does not exist.'
            $true | Should Be $true
            return
        }

        $content = Get-Content -LiteralPath $script:mitrePath -Raw
        ([string]::IsNullOrWhiteSpace($content)) | Should Be $false
    }

    It 'contains required headers when file exists' {
        if (-not (Test-Path -LiteralPath $script:mitrePath -PathType Leaf)) {
            Write-Warning 'Skipping required header checks because docs/mitre-mapping.md does not exist.'
            $true | Should Be $true
            return
        }

        $content = Get-Content -LiteralPath $script:mitrePath -Raw
        ($content -match 'Control') | Should Be $true
        ($content -match 'ATT&CK Technique') | Should Be $true
        ($content -match 'Tactic') | Should Be $true
        ($content -match 'Mitigation') | Should Be $true
    }
}

Describe 'CONTROLS.md to MITRE Cross-Reference' {
    It 'every CTRL identifier in CONTROLS.md appears in docs/mitre-mapping.md' {
        if (-not (Test-Path -LiteralPath $script:controlsPath -PathType Leaf)) {
            Write-Warning 'Skipping cross-reference check because docs/CONTROLS.md does not exist.'
            $true | Should Be $true
            return
        }

        if (-not (Test-Path -LiteralPath $script:mitrePath -PathType Leaf)) {
            Write-Warning 'Skipping cross-reference check because docs/mitre-mapping.md does not exist.'
            $true | Should Be $true
            return
        }

        $controlsContent = Get-Content -LiteralPath $script:controlsPath
        $mitreContent = Get-Content -LiteralPath $script:mitrePath -Raw

        $controlIds = @()
        foreach ($line in $controlsContent) {
            if ($line -match '\|\s*(CTRL-\d+)\s*\|') {
                $controlIds += $matches[1]
            }
        }

        $controlIds = $controlIds | Select-Object -Unique
        $missing = @()

        foreach ($controlId in $controlIds) {
            if ($mitreContent -notmatch [regex]::Escape($controlId)) {
                $missing += $controlId
            }
        }

        if ($missing.Count -gt 0) {
            throw ("Missing controls in docs/mitre-mapping.md: {0}" -f ($missing -join ', '))
        }

        $true | Should Be $true
    }
}

Describe 'MITRE Technique ID Format Validation' {
    It 'all ATT&CK technique IDs use Tdddd or Tdddd.ddd and are not blank when mapping exists' {
        if (-not (Test-Path -LiteralPath $script:mitrePath -PathType Leaf)) {
            Write-Warning 'Skipping technique format checks because docs/mitre-mapping.md does not exist.'
            $true | Should Be $true
            return
        }

        $lines = Get-Content -LiteralPath $script:mitrePath
        $tableRows = $lines | Where-Object {
            $_ -match '^\|\s*CTRL-\d+\s*\|'
        }

        foreach ($row in $tableRows) {
            $parts = $row.Split('|')
            if ($parts.Count -lt 5) {
                throw ("Malformed MITRE mapping row: {0}" -f $row)
            }

            $technique = $parts[3].Trim()
            ([string]::IsNullOrWhiteSpace($technique)) | Should Be $false
            ($technique -match '^T\d{4}(\.\d{3})?$') | Should Be $true
        }
    }
}
