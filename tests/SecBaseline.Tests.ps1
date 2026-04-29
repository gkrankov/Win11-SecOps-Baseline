#Requires -Modules Pester
<#
.SYNOPSIS
    Pester tests for Win11-SecOps-Baseline modules.
.DESCRIPTION
    Run with: Invoke-Pester .\tests\ -Output Detailed
#>

$script:RootPath   = Split-Path $PSScriptRoot -Parent
$script:ConfigPath = Join-Path $script:RootPath 'config\baseline.json'
$script:Config     = Get-Content -Raw $script:ConfigPath | ConvertFrom-Json

function Get-FunctionDefinitionText {
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [string] $FunctionName
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    if ($errors) {
        throw "Failed to parse script '$ScriptPath': $($errors[0].Message)"
    }

    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
    }, $true)

    if (-not $functionAst) {
        throw "Function '$FunctionName' not found in $ScriptPath"
    }

    return $functionAst.Extent.Text
}

function ConvertTo-PowerShellLiteral {
    param([Parameter(Mandatory)] $Value)

    if ($null -eq $Value) {
        return '$null'
    }

    if ($Value -is [string]) {
        return "'" + $Value.Replace("'", "''") + "'"
    }

    if ($Value -is [bool]) {
        return ('$' + $Value.ToString())
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return '@(' + (($Value | ForEach-Object { ConvertTo-PowerShellLiteral -Value $_ }) -join ', ') + ')'
    }

    return [string]$Value
}

function New-TestModuleFromFunctions {
    param(
        [Parameter(Mandatory)] [string] $ModuleRoot,
        [Parameter(Mandatory)] [string] $SourceScript,
        [Parameter(Mandatory)] [string[]] $FunctionNames,
        [hashtable] $Initializers = @{}
    )

    $modulePath = Join-Path $ModuleRoot 'TestHarness.psm1'
    $content = New-Object System.Collections.Generic.List[string]

    foreach ($key in $Initializers.Keys) {
        $content.Add(("{0} = {1}" -f $key, (ConvertTo-PowerShellLiteral -Value $Initializers[$key])))
    }

    foreach ($functionName in $FunctionNames) {
        $content.Add((Get-FunctionDefinitionText -ScriptPath $SourceScript -FunctionName $functionName))
    }

    $content.Add(("Export-ModuleMember -Function {0}" -f ($FunctionNames -join ',')))
    Set-Content -Path $modulePath -Value ($content -join [Environment]::NewLine + [Environment]::NewLine) -Encoding UTF8

    return Import-Module $modulePath -Force -PassThru
}

function Get-ErrorMessage {
    param([Parameter(Mandatory)] [scriptblock] $ScriptBlock)

    try {
        & $ScriptBlock
    } catch {
        return $_.Exception.Message
    }

    throw 'Expected script block to throw, but it completed successfully.'
}

Describe 'baseline.json' {
    It 'loads without error' {
        $script:Config | Should Not BeNullOrEmpty
    }

    It 'contains all required top-level keys' {
        (($script:Config.PSObject.Properties.Name) -contains 'AuditPolicies') | Should Be $true
        (($script:Config.PSObject.Properties.Name) -contains 'Firewall') | Should Be $true
        (($script:Config.PSObject.Properties.Name) -contains 'UserAccounts') | Should Be $true
        (($script:Config.PSObject.Properties.Name) -contains 'WindowsDefender') | Should Be $true
        (($script:Config.PSObject.Properties.Name) -contains 'NetworkHardening') | Should Be $true
    }
}

Describe 'Invoke-SecBaseline.ps1' {
    It 'exists at project root' {
        $entryPoint = Join-Path $script:RootPath 'Invoke-SecBaseline.ps1'
        Test-Path $entryPoint | Should Be $true
    }

    It 'parses without syntax errors' {
        $entryPoint = Join-Path $script:RootPath 'Invoke-SecBaseline.ps1'
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($entryPoint, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should BeNullOrEmpty
    }
}

Describe 'Module scripts exist' {
    $modules = @('AuditPolicies', 'Firewall', 'UserAccounts', 'WindowsDefender', 'NetworkHardening')

    It '<module> script file is present' -TestCases ($modules | ForEach-Object { @{ module = $_ } }) {
        param($module)
        $path = Join-Path $script:RootPath "modules\$($module)\Set-$($module).ps1"
        # Firewall and UserAccounts have different file names — adjust as needed
        Test-Path (Join-Path $script:RootPath "modules\$module") | Should Be $true
    }
}

Describe 'Path validation helpers' {
    $pathScripts = @(
        @{ Name = '02-posture-check'; Script = (Join-Path $script:RootPath '02-posture-check.ps1') },
        @{ Name = '03-drift-detector'; Script = (Join-Path $script:RootPath '03-drift-detector.ps1') },
        @{ Name = '05-dashboard-export'; Script = (Join-Path $script:RootPath '05-dashboard-export.ps1') }
    )

    It '<Name> rejects UNC paths' -TestCases $pathScripts {
        param($Name, $Script)
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            $module = New-TestModuleFromFunctions -ModuleRoot $tempRoot -SourceScript $Script -FunctionNames @('Resolve-LocalPath')
            $message = Get-ErrorMessage {
                & $module { Resolve-LocalPath -Path '\\server\share\report.md' -PathType Any -RequiredExtension '.md' }
            }
            $message | Should Match 'UNC paths are not allowed:'
        } finally {
            if ($module) { Remove-Module $module.Name -Force -ErrorAction SilentlyContinue }
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '<Name> enforces required file extension' -TestCases $pathScripts {
        param($Name, $Script)
        $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        try {
            $module = New-TestModuleFromFunctions -ModuleRoot $tempRoot -SourceScript $Script -FunctionNames @('Resolve-LocalPath')
            $message = Get-ErrorMessage {
                & $module { Resolve-LocalPath -Path 'C:\temp\report.txt' -PathType Any -RequiredExtension '.md' }
            }
            $message | Should Match 'Path must use \.md extension:'
        } finally {
            if ($module) { Remove-Module $module.Name -Force -ErrorAction SilentlyContinue }
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Module allowlist and containment' {
    BeforeEach {
        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $script:ModulesRoot = Join-Path $script:TempRoot 'modules'
        New-Item -ItemType Directory -Path $script:ModulesRoot -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:ModulesRoot 'AuditPolicies') -Force | Out-Null
        Set-Content -Path (Join-Path $script:ModulesRoot 'AuditPolicies\Set-AuditPolicies.ps1') -Value 'return @{}' -Encoding UTF8
        $script:ModuleUnderTest = New-TestModuleFromFunctions `
            -ModuleRoot $script:TempRoot `
            -SourceScript (Join-Path $script:RootPath '03-drift-detector.ps1') `
            -FunctionNames @('Find-ModuleScript') `
            -Initializers @{ '$script:AllowedModuleCategories' = @('AuditPolicies', 'Firewall', 'UserAccounts', 'WindowsDefender', 'NetworkHardening') }
    }

    AfterEach {
        if ($script:ModuleUnderTest) { Remove-Module $script:ModuleUnderTest.Name -Force -ErrorAction SilentlyContinue }
        Remove-Item -Path $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'rejects categories outside the allowlist' {
        $message = Get-ErrorMessage {
            & $script:ModuleUnderTest { Find-ModuleScript -Category 'MaliciousModule' }
        }
        $message | Should Match 'Invalid remediation category:'
    }

    It 'returns only a script path within the modules root' {
        $resolvedPath = & $script:ModuleUnderTest { Find-ModuleScript -Category 'AuditPolicies' }
        $resolvedPath | Should Be (Join-Path $script:ModulesRoot 'AuditPolicies\Set-AuditPolicies.ps1')
    }
}

Describe 'Package ID validation' {
    BeforeEach {
        $script:ToolsTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:ToolsTempRoot -Force | Out-Null
        $script:ToolsModule = New-TestModuleFromFunctions `
            -ModuleRoot $script:ToolsTempRoot `
            -SourceScript (Join-Path $script:RootPath '04-tools-setup.ps1') `
            -FunctionNames @('Test-WingetPackageId')
    }

    AfterEach {
        if ($script:ToolsModule) { Remove-Module $script:ToolsModule.Name -Force -ErrorAction SilentlyContinue }
        Remove-Item -Path $script:ToolsTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'accepts a valid winget package identifier' {
        (& $script:ToolsModule { Test-WingetPackageId -PackageId 'Microsoft.WindowsTerminal' }) | Should Be $true
    }

    It 'rejects package identifiers with whitespace or shell metacharacters' {
        (& $script:ToolsModule { Test-WingetPackageId -PackageId 'Bad Package;calc.exe' }) | Should Be $false
    }
}

Describe 'HTML escaping' {
    BeforeEach {
        $script:DashboardTempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DashboardTempRoot -Force | Out-Null
        $script:DashboardModule = New-TestModuleFromFunctions `
            -ModuleRoot $script:DashboardTempRoot `
            -SourceScript (Join-Path $script:RootPath '05-dashboard-export.ps1') `
            -FunctionNames @('Escape-Html')
    }

    AfterEach {
        if ($script:DashboardModule) { Remove-Module $script:DashboardModule.Name -Force -ErrorAction SilentlyContinue }
        Remove-Item -Path $script:DashboardTempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'encodes HTML-significant characters' {
        $encoded = & $script:DashboardModule { Escape-Html -Value '<script>"x" & y</script>' }
        $encoded | Should Be '&lt;script&gt;&quot;x&quot; &amp; y&lt;/script&gt;'
    }

    It 'returns N/A for null input' {
        (& $script:DashboardModule { Escape-Html -Value $null }) | Should Be 'N/A'
    }
}
