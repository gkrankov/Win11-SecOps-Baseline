#Requires -Version 5.1
<##
.SYNOPSIS
    IntegrityVerification.Tests.ps1

.DESCRIPTION
    Unit tests for module hash manifest generation and integrity gate behavior.

.NOTES
    Gap addressed: Gap 2 - Module Integrity Verification
    Date created: 2026-04-28
    #Requires -Version 5.1
##>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path (Split-Path $PSScriptRoot -Parent) '..\src\core\IntegrityVerification.ps1')

function New-TestProject {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    $srcCore = Join-Path $root 'src\core'
    $modulesA = Join-Path $root 'modules\Alpha'

    New-Item -ItemType Directory -Path $srcCore -Force | Out-Null
    New-Item -ItemType Directory -Path $modulesA -Force | Out-Null

    Set-Content -LiteralPath (Join-Path $srcCore 'One.ps1') -Value 'Write-Output "one"' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $modulesA 'Set-Alpha.ps1') -Value 'Write-Output "alpha"' -Encoding UTF8

    return $root
}

Describe 'New-ModuleHashManifest' {
    It 'creates valid JSON output' {
        $projectRoot = New-TestProject
        $manifestPath = Join-Path $projectRoot 'manifest.json'

        try {
            New-ModuleHashManifest -ProjectRoot $projectRoot -OutputPath $manifestPath | Out-Null
            (Test-Path -LiteralPath $manifestPath) | Should Be $true

            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            ($manifest.generated -ne $null) | Should Be $true
            ($manifest.generatedBy -ne $null) | Should Be $true
            ($manifest.hashes -ne $null) | Should Be $true
        } finally {
            Remove-Item -Path $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'includes all .ps1 files found under src and modules' {
        $projectRoot = New-TestProject
        $manifestPath = Join-Path $projectRoot 'manifest.json'

        try {
            New-ModuleHashManifest -ProjectRoot $projectRoot -OutputPath $manifestPath | Out-Null
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

            ($manifest.hashes.PSObject.Properties.Name -contains 'src/core/One.ps1') | Should Be $true
            ($manifest.hashes.PSObject.Properties.Name -contains 'modules/Alpha/Set-Alpha.ps1') | Should Be $true
        } finally {
            Remove-Item -Path $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Test-ModuleIntegrity' {
    It 'returns Passed true when hashes match' {
        $projectRoot = New-TestProject
        $manifestPath = Join-Path $projectRoot 'manifest.json'

        try {
            New-ModuleHashManifest -ProjectRoot $projectRoot -OutputPath $manifestPath | Out-Null
            $result = Test-ModuleIntegrity -ManifestPath $manifestPath -ProjectRoot $projectRoot

            $result.Passed | Should Be $true
            $result.Violations.Count | Should Be 0
            $result.CheckedCount | Should Be 2
        } finally {
            Remove-Item -Path $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'returns Passed false and lists violations when a file is modified' {
        $projectRoot = New-TestProject
        $manifestPath = Join-Path $projectRoot 'manifest.json'

        try {
            New-ModuleHashManifest -ProjectRoot $projectRoot -OutputPath $manifestPath | Out-Null
            Add-Content -LiteralPath (Join-Path $projectRoot 'modules\Alpha\Set-Alpha.ps1') -Value "`nWrite-Output 'changed'" -Encoding UTF8

            $result = Test-ModuleIntegrity -ManifestPath $manifestPath -ProjectRoot $projectRoot
            $result.Passed | Should Be $false
            ($result.Violations -contains 'modules/Alpha/Set-Alpha.ps1') | Should Be $true
        } finally {
            Remove-Item -Path $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-IntegrityGate' {
    It 'throws when violations exist' {
        $projectRoot = New-TestProject
        $manifestPath = Join-Path $projectRoot 'manifest.json'

        try {
            New-ModuleHashManifest -ProjectRoot $projectRoot -OutputPath $manifestPath | Out-Null
            Add-Content -LiteralPath (Join-Path $projectRoot 'src\core\One.ps1') -Value "`n# changed" -Encoding UTF8

            { Invoke-IntegrityGate -ManifestPath $manifestPath -ProjectRoot $projectRoot | Out-Null } | Should Throw
        } finally {
            Remove-Item -Path $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not throw in WhatIf mode' {
        $projectRoot = New-TestProject
        $manifestPath = Join-Path $projectRoot 'manifest.json'

        try {
            New-ModuleHashManifest -ProjectRoot $projectRoot -OutputPath $manifestPath | Out-Null
            Add-Content -LiteralPath (Join-Path $projectRoot 'src\core\One.ps1') -Value "`n# changed" -Encoding UTF8

            { Invoke-IntegrityGate -ManifestPath $manifestPath -ProjectRoot $projectRoot -WhatIf | Out-Null } | Should Not Throw
        } finally {
            Remove-Item -Path $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
