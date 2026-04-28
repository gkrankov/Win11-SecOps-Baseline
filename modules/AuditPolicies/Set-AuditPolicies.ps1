<#
.SYNOPSIS
    Applies advanced audit policy settings per CIS Benchmark for Windows 11.
.PARAMETER Config
    The parsed baseline.json configuration object.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)] [PSCustomObject] $Config
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$settings = $Config.AuditPolicies
$results  = @{}

$auditMap = @{
    'AuditLogonEvents'       = 'Logon/Logoff'
    'AuditAccountLogon'      = 'Account Logon'
    'AuditPrivilegeUse'      = 'Privilege Use'
    'AuditPolicyChange'      = 'Policy Change'
    'AuditObjectAccess'      = 'Object Access'
    'AuditProcessTracking'   = 'Detailed Tracking'
    'AuditSystemEvents'      = 'System'
    'AuditAccountManagement' = 'Account Management'
}

foreach ($key in $auditMap.Keys) {
    $category  = $auditMap[$key]
    $value     = $settings.$key

    if (-not $value) { continue }

    $success = $value -match 'Success'
    $failure = $value -match 'Failure'
    $args = @('/set', "/category:$category")
    if ($success) { $args += '/success:enable' } else { $args += '/success:disable' }
    if ($failure) { $args += '/failure:enable' } else { $args += '/failure:disable' }

    if ($PSCmdlet.ShouldProcess($category, "Set audit policy to $value")) {
        try {
            $output = & auditpol.exe @args 2>&1
            if ($LASTEXITCODE -eq 0) {
                $results[$key] = 'Applied'
            } else {
                $results[$key] = "Failed: $($output -join ' ')"
            }
        } catch {
            $results[$key] = "Failed: $($_.Exception.Message)"
            throw
        }
    } else {
        $results[$key] = 'WhatIf'
    }
}

return $results
