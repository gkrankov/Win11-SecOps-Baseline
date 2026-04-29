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

# Use locale-independent GUIDs — auditpol.exe category names are localized
# and will fail on non-English Windows (e.g. Hungarian). GUIDs are universal.
$auditMap = @{
    'AuditLogonEvents'       = '{69979849-797A-11D9-BED3-505054503030}'
    'AuditAccountLogon'      = '{69979850-797A-11D9-BED3-505054503030}'
    'AuditPrivilegeUse'      = '{6997984B-797A-11D9-BED3-505054503030}'
    'AuditPolicyChange'      = '{6997984D-797A-11D9-BED3-505054503030}'
    'AuditObjectAccess'      = '{6997984A-797A-11D9-BED3-505054503030}'
    'AuditProcessTracking'   = '{6997984C-797A-11D9-BED3-505054503030}'
    'AuditSystemEvents'      = '{69979848-797A-11D9-BED3-505054503030}'
    'AuditAccountManagement' = '{6997984E-797A-11D9-BED3-505054503030}'
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
