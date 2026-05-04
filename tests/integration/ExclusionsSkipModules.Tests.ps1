# ExclusionsSkipModules.Tests.ps1
# Integration test: modules listed in exclusions.json SkipModules must not be invoked
# Pester 3.4 compatible

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $here)

Describe "Orchestrator exclusions.json SkipModules" {

    It "does not invoke a module script that is listed in SkipModules" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
        $sentinel  = Join-Path $tempRoot 'AuditPolicies-was-invoked.txt'

        try {
            $coreDir    = Join-Path $tempRoot 'src\core'
            $configDir  = Join-Path $tempRoot 'config'
            $modulesDir = Join-Path $tempRoot 'modules'

            New-Item -ItemType Directory -Path $coreDir    -Force | Out-Null
            New-Item -ItemType Directory -Path $configDir  -Force | Out-Null
            New-Item -ItemType Directory -Path $modulesDir -Force | Out-Null

            Copy-Item (Join-Path $root 'src\core\RunContext.ps1')           (Join-Path $coreDir 'RunContext.ps1')           -Force
            Copy-Item (Join-Path $root 'src\core\IntegrityVerification.ps1') (Join-Path $coreDir 'IntegrityVerification.ps1') -Force

            $baselineJson = @'
{
  "AuditPolicies": {},
  "Firewall": {},
  "UserAccounts": {},
  "WindowsDefender": {},
  "NetworkHardening": {}
}
'@
            Set-Content -Path (Join-Path $configDir 'baseline.json') -Value $baselineJson -Encoding UTF8

            # exclusions.json: AuditPolicies listed in SkipModules
            $exclusionsJson = @'
{
  "Hosts": [],
  "SkipModules": ["AuditPolicies"],
  "SkipSettings": [],
  "Exclusions": []
}
'@
            Set-Content -Path (Join-Path $configDir 'exclusions.json') -Value $exclusionsJson -Encoding UTF8

            # Stub module scripts; AuditPolicies writes a sentinel file if invoked
            $moduleFileMap = @{
                'AuditPolicies'    = 'Set-AuditPolicies.ps1'
                'Firewall'         = 'Set-FirewallBaseline.ps1'
                'UserAccounts'     = 'Set-UserAccounts.ps1'
                'WindowsDefender'  = 'Set-DefenderBaseline.ps1'
                'NetworkHardening' = 'Set-NetworkHardening.ps1'
            }

            foreach ($moduleName in $moduleFileMap.Keys) {
                $targetModuleDir = Join-Path $modulesDir $moduleName
                New-Item -ItemType Directory -Path $targetModuleDir -Force | Out-Null
                $targetModuleScript = Join-Path $targetModuleDir $moduleFileMap[$moduleName]

                if ($moduleName -eq 'AuditPolicies') {
                    # Writes a sentinel so we can assert it was NOT called
                    Set-Content -Path $targetModuleScript `
                        -Value "param([object]`$Config, [switch]`$WhatIf) Set-Content -Path '$sentinel' -Value 'invoked' -Encoding UTF8" `
                        -Encoding UTF8
                } else {
                    Set-Content -Path $targetModuleScript `
                        -Value "param([object]`$Config, [switch]`$WhatIf) return @{ Module = '$moduleName'; Ok = `$true }" `
                        -Encoding UTF8
                }
            }

            # Copy orchestrator, stripping the elevation requirement for test execution
            $orchestratorContent = Get-Content (Join-Path $root 'Invoke-SecBaseline.ps1') -Raw
            $orchestratorContent = $orchestratorContent -replace '(?m)^#Requires -RunAsAdministrator\r?\n', ''
            $orchestratorPath = Join-Path $tempRoot 'Invoke-SecBaseline.ps1'
            Set-Content -Path $orchestratorPath -Value $orchestratorContent -Encoding UTF8

            { & $orchestratorPath -SkipIntegrityCheck -ErrorAction Stop } | Should Not Throw

            # Sentinel must not exist: AuditPolicies script must not have been invoked
            Test-Path $sentinel | Should Be $false
        }
        finally {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
