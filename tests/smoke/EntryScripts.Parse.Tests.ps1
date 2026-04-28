#Requires -Version 5.1
<##
.SYNOPSIS
    EntryScripts.Parse.Tests.ps1

.DESCRIPTION
    Smoke tests for root entry scripts: existence, parse validity, version requirement, and Write-Host hygiene.

.NOTES
    Gap addressed: Gap 5 - Rollback Strategy and Phase Gates
    Date created: 2026-04-28
    #Requires -Version 5.1
##>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path $PSScriptRoot -Parent) '..\src\core\RunContext.ps1')

$projectRoot = (Resolve-Path (Join-Path (Split-Path $PSScriptRoot -Parent) '..')).Path
$entryScripts = @(
    '01-hardening.ps1',
    '02-posture-check.ps1',
    '03-drift-detector.ps1',
    '04-tools-setup.ps1',
    '05-dashboard-export.ps1',
    'Invoke-SecBaseline.ps1',
    'Get-SecurityCheckpoint.ps1'
)

Describe 'Entry script parse and hygiene' {
    It 'all required entry scripts exist' {
        foreach ($scriptName in $entryScripts) {
            $scriptPath = Join-Path $projectRoot $scriptName
            (Test-Path -LiteralPath $scriptPath -PathType Leaf) | Should Be $true
        }
    }

    It 'all required entry scripts parse without syntax errors' {
        foreach ($scriptName in $entryScripts) {
            $scriptPath = Join-Path $projectRoot $scriptName
            $tokens = $null
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
            $errors.Count | Should Be 0
        }
    }

    It 'all required entry scripts include #Requires -Version 5.1' {
        foreach ($scriptName in $entryScripts) {
            $scriptPath = Join-Path $projectRoot $scriptName
            $content = Get-Content -LiteralPath $scriptPath -Raw
            ($content -match '#Requires\s+-Version\s+5\.1') | Should Be $true
        }
    }

    It 'all required entry scripts avoid raw Write-Host without ForegroundColor' {
        foreach ($scriptName in $entryScripts) {
            $scriptPath = Join-Path $projectRoot $scriptName
            $lines = Get-Content -LiteralPath $scriptPath
            $offending = @()

            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -match '(^|\s)Write-Host(\s|$)') {
                    $hasForegroundColor = ($line -match '-ForegroundColor\s+\S+')

                    if (-not $hasForegroundColor -and $line.TrimEnd().EndsWith('`') -and ($i + 1) -lt $lines.Count) {
                        $hasForegroundColor = ($lines[$i + 1] -match '-ForegroundColor\s+\S+')
                    }

                    if (-not $hasForegroundColor) {
                        $offending += ("{0}:{1}" -f $scriptName, ($i + 1))
                    }
                }
            }

            if ($offending.Count -gt 0) {
                throw ("Raw Write-Host calls without -ForegroundColor found: {0}" -f ($offending -join ', '))
            }
        }

        $true | Should Be $true
    }
}
