#Requires -Version 5.1
<##
.SYNOPSIS
    InputSanitization.ps1

.DESCRIPTION
    Provides centralized sanitization functions for configuration values and file paths.

.NOTES
    Gap addressed: Gap 1 - Input Sanitization Layer
    Date created: 2026-04-28
    #Requires -Version 5.1
    Prevents injection of malicious strings from externally-sourced baseline.json or settings.json into downstream privileged commands
##>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-SanitizeConfigValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Value,
        [Parameter(Mandatory)] [string] $FieldName,
        [string] $AllowedPattern = '^[A-Za-z0-9._\\-]+$'
    )

    if ([string]::IsNullOrWhiteSpace($FieldName)) {
        throw 'FieldName cannot be null or empty.'
    }

    if ($null -eq $Value) {
        throw ("Configuration field '{0}' cannot be null." -f $FieldName)
    }

    if ($Value -notmatch $AllowedPattern) {
        throw ("Invalid characters detected in configuration field '{0}'. Value '{1}' does not match allowed pattern '{2}'." -f $FieldName, $Value, $AllowedPattern)
    }

    return $Value
}

function Invoke-SanitizeFilePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $FieldName
    )

    if ([string]::IsNullOrWhiteSpace($FieldName)) {
        throw 'FieldName cannot be null or empty.'
    }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw ("Path field '{0}' cannot be null or empty." -f $FieldName)
    }

    if ($Path.Contains([char]0)) {
        throw ("Path field '{0}' contains a null byte, which is not allowed." -f $FieldName)
    }

    if ($Path.Length -gt 260) {
        throw ("Path field '{0}' exceeds maximum supported length (260)." -f $FieldName)
    }

    if ($Path -match '(?:^|[\\/])\.\.(?:[\\/]|$)') {
        throw ("Path field '{0}' contains path traversal sequence '..\'." -f $FieldName)
    }

    if ($Path -match '[\*\?"<>\|]') {
        throw ("Path field '{0}' contains forbidden characters." -f $FieldName)
    }

    return $Path
}

function Invoke-SanitizeConfigObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $ConfigObject,
        [string[]] $RequiredKeys = @(),
        [string[]] $PathKeys = @()
    )

    $sanitized = @{}

    foreach ($requiredKey in $RequiredKeys) {
        if (-not $ConfigObject.ContainsKey($requiredKey)) {
            throw ("Required configuration key '{0}' is missing." -f $requiredKey)
        }
    }

    foreach ($key in $ConfigObject.Keys) {
        $value = $ConfigObject[$key]

        if ($PathKeys -contains $key) {
            if ($value -is [string]) {
                $sanitized[$key] = Invoke-SanitizeFilePath -Path $value -FieldName $key
            } else {
                throw ("Path key '{0}' must contain a string value." -f $key)
            }
            continue
        }

        if ($value -is [string]) {
            $sanitized[$key] = Invoke-SanitizeConfigValue -Value $value -FieldName $key
            continue
        }

        $sanitized[$key] = $value
    }

    return $sanitized
}
