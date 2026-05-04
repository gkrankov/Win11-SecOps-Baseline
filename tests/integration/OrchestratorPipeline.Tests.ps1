# OrchestratorPipeline.Tests.ps1
# Integration test: Invoke-SecBaseline.ps1 dry-run sequence
# Pester 3.4 compatible
# REQUIRES: WhatIf or -DryRun flag implemented in Invoke-SecBaseline.ps1

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $here)
$orchestrator = Join-Path $root "Invoke-SecBaseline.ps1"

Describe "Orchestrator Pipeline - Integration" {

    Context "Dry-run invocation" {
        It "Invoke-SecBaseline.ps1 exists at repo root" {
            Test-Path $orchestrator | Should Be $true
        }

        It "Script parses without syntax errors" {
            $tokens = $null
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $orchestrator, [ref]$tokens, [ref]$errors
            )
            $errors.Count | Should Be 0
        }

        It "WhatIf invocation completes without terminating error when elevated" {
            # Invoke-SecBaseline.ps1 requires elevation. In non-elevated CI
            # sessions we skip invocation and validate parsing only.
            $isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $isElevated) {
                Write-Host "Skipping WhatIf invocation test in non-elevated session." -ForegroundColor DarkYellow
                Set-TestInconclusive -Message "WhatIf invocation test requires an elevated session."
            }

            { & $orchestrator -WhatIf -SkipIntegrityCheck -ErrorAction Stop } | Should Not Throw
        }
    }
}
