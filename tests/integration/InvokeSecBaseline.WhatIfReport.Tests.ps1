# InvokeSecBaseline.WhatIfReport.Tests.ps1
# Regression: WhatIf must not attempt report file writes in orchestrator
# Pester 3.4 compatible

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent (Split-Path -Parent $here)

Describe "Invoke-SecBaseline WhatIf report behavior" {

    It "does not call Set-Content in WhatIf mode" {
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))

        try {
            $coreDir = Join-Path $tempRoot 'src\core'
            $configDir = Join-Path $tempRoot 'config'
            $modulesDir = Join-Path $tempRoot 'modules'

            New-Item -ItemType Directory -Path $coreDir -Force | Out-Null
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
            New-Item -ItemType Directory -Path $modulesDir -Force | Out-Null

            Copy-Item (Join-Path $root 'src\core\RunContext.ps1') (Join-Path $coreDir 'RunContext.ps1') -Force
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

            $moduleFileMap = @{
                'AuditPolicies' = 'Set-AuditPolicies.ps1'
                'Firewall' = 'Set-FirewallBaseline.ps1'
                'UserAccounts' = 'Set-UserAccounts.ps1'
                'WindowsDefender' = 'Set-DefenderBaseline.ps1'
                'NetworkHardening' = 'Set-NetworkHardening.ps1'
            }

            foreach ($moduleName in $moduleFileMap.Keys) {
                $targetModuleDir = Join-Path $modulesDir $moduleName
                New-Item -ItemType Directory -Path $targetModuleDir -Force | Out-Null
                $targetModuleScript = Join-Path $targetModuleDir $moduleFileMap[$moduleName]
                Set-Content -Path $targetModuleScript -Value "param([object]`$Config, [switch]`$WhatIf) return @{ Module = '$moduleName'; Ok = `$true }" -Encoding UTF8
            }

            $orchestratorContent = Get-Content (Join-Path $root 'Invoke-SecBaseline.ps1') -Raw
            $orchestratorContent = $orchestratorContent -replace '(?m)^#Requires -RunAsAdministrator\r?\n', ''
            $orchestratorPath = Join-Path $tempRoot 'Invoke-SecBaseline.ps1'
            Set-Content -Path $orchestratorPath -Value $orchestratorContent -Encoding UTF8

            Mock Set-Content {}

            { & $orchestratorPath -WhatIf -SkipIntegrityCheck -ErrorAction Stop } | Should Not Throw
            Assert-MockCalled Set-Content -Times 0 -Exactly
        }
        finally {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
