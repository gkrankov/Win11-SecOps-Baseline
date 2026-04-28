#Requires -Version 5.1
<##
.SYNOPSIS
    New-RefactorCheckpoint.ps1

.DESCRIPTION
    Creates rollback checkpoints using git tags or filesystem snapshots for refactor phase safety.

.NOTES
    Gap addressed: Gap 5 - Rollback Strategy and Phase Gates
    Date created: 2026-04-28
    #Requires -Version 5.1
##>

[CmdletBinding()]
param(
    [string] $PhaseName,
    [switch] $Rollback,
    [string] $TagName,
    [string] $Confirmation,
    [string] $ProjectRoot = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-GitAvailable {
    return [bool](Get-Command -Name git -ErrorAction SilentlyContinue)
}

function New-FallbackCheckpoint {
    param(
        [Parameter(Mandatory)] [string] $PhaseName,
        [Parameter(Mandatory)] [string] $ProjectRoot
    )

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safePhase = ($PhaseName -replace '[^A-Za-z0-9._-]', '-')
    $checkpointRoot = Join-Path $ProjectRoot '.checkpoints'
    $checkpointPath = Join-Path $checkpointRoot ("{0}-{1}" -f $safePhase, $timestamp)

    New-Item -ItemType Directory -Path $checkpointPath -Force -ErrorAction Stop | Out-Null

    $files = Get-ChildItem -Path $ProjectRoot -Recurse -File -Include '*.ps1', '*.json'
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($ProjectRoot.Length).TrimStart('\')
        $destination = Join-Path $checkpointPath $relative
        $destinationDir = Split-Path -Path $destination -Parent
        if (-not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationDir -Force -ErrorAction Stop | Out-Null
        }

        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
    }

    Write-Host ("Created fallback checkpoint at: {0}" -f $checkpointPath)
    return $checkpointPath
}

function New-RefactorCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $PhaseName,
        [Parameter(Mandatory)] [string] $ProjectRoot
    )

    $resolvedRoot = (Resolve-Path -Path $ProjectRoot -ErrorAction Stop).Path

    if (-not (Test-GitAvailable)) {
        return New-FallbackCheckpoint -PhaseName $PhaseName -ProjectRoot $resolvedRoot
    }

    Push-Location $resolvedRoot
    try {
        $statusOutput = & git status --porcelain
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to determine git status.'
        }

        if (-not [string]::IsNullOrWhiteSpace(($statusOutput | Out-String))) {
            Write-Warning 'Uncommitted changes detected in working tree.'
            $continue = Read-Host 'Continue checkpoint creation anyway? Type YES to continue'
            if ($continue -cne 'YES') {
                throw 'Checkpoint creation cancelled by user due to uncommitted changes.'
            }
        }

        $safePhase = ($PhaseName -replace '[^A-Za-z0-9._-]', '-')
        $tagName = 'refactor/{0}-pre-{1}' -f $safePhase, (Get-Date -Format 'yyyyMMdd')
        $existingTag = & git tag --list $tagName
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to list git tags.'
        }

        if (-not [string]::IsNullOrWhiteSpace(($existingTag | Out-String).Trim())) {
            throw ("Tag already exists: {0}" -f $tagName)
        }

        & git tag $tagName
        if ($LASTEXITCODE -ne 0) {
            throw ("Failed to create tag: {0}" -f $tagName)
        }

        Write-Host ("Created checkpoint tag: {0}" -f $tagName)
        return $tagName
    } finally {
        Pop-Location
    }
}

function Invoke-RollbackToCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TagName,
        [Parameter(Mandatory)] [string] $Confirmation,
        [string] $ProjectRoot = $PSScriptRoot
    )

    $resolvedRoot = (Resolve-Path -Path $ProjectRoot -ErrorAction Stop).Path

    if (-not (Test-GitAvailable)) {
        $checkpointRoot = Join-Path $resolvedRoot '.checkpoints'
        if (-not (Test-Path -LiteralPath $checkpointRoot -PathType Container)) {
            Write-Warning 'Git is unavailable and no .checkpoints folder exists. Manual rollback data not found.'
            return
        }

        $matching = Get-ChildItem -Path $checkpointRoot -Directory | Where-Object { $_.Name -like "*$TagName*" }
        if (-not $matching) {
            Write-Warning ("Git is unavailable and no matching checkpoint folder was found for: {0}" -f $TagName)
            return
        }

        foreach ($folder in $matching) {
            Write-Host ("Manual restore checkpoint: {0}" -f $folder.FullName)
            Get-ChildItem -Path $folder.FullName -Recurse -File | ForEach-Object { Write-Host (" - {0}" -f $_.FullName) }
        }

        return
    }

    Push-Location $resolvedRoot
    try {
        $tagExists = & git tag --list $TagName
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to query git tags.'
        }

        if ([string]::IsNullOrWhiteSpace(($tagExists | Out-String).Trim())) {
            throw ("Checkpoint tag not found: {0}" -f $TagName)
        }

        $changes = & git diff --name-only "$TagName..HEAD"
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to compute changed files since tag.'
        }

        Write-Host ("Files changed since {0}:" -f $TagName)
        if ([string]::IsNullOrWhiteSpace(($changes | Out-String).Trim())) {
            Write-Host ' - No changed files detected.'
        } else {
            $changes | ForEach-Object { Write-Host (" - {0}" -f $_) }
        }

        if ($Confirmation -ne 'CONFIRM-ROLLBACK') {
            throw 'Rollback aborted: pass -Confirmation CONFIRM-ROLLBACK to execute restore.'
        }

        & git checkout $TagName -- .
        if ($LASTEXITCODE -ne 0) {
            throw ("Rollback command failed for tag: {0}" -f $TagName)
        }

        Write-Host ("Rollback completed to checkpoint tag: {0}" -f $TagName)
    } finally {
        Pop-Location
    }
}

$scriptWasDotSourced = $MyInvocation.InvocationName -eq '.'

if (-not $scriptWasDotSourced) {
    if (-not $Rollback -and [string]::IsNullOrWhiteSpace($PhaseName) -and [string]::IsNullOrWhiteSpace($TagName)) {
        Write-Host 'Usage:'
        Write-Host '  Create checkpoint:'
        Write-Host '    .\scripts\New-RefactorCheckpoint.ps1 -PhaseName Phase1'
        Write-Host '  Roll back to checkpoint:'
        Write-Host '    .\scripts\New-RefactorCheckpoint.ps1 -Rollback -TagName refactor/Phase1-pre-20260428 -Confirmation CONFIRM-ROLLBACK'
        return
    }

    if ($Rollback) {
        if ([string]::IsNullOrWhiteSpace($TagName)) {
            throw 'TagName is required when using -Rollback.'
        }

        Invoke-RollbackToCheckpoint -TagName $TagName -Confirmation $Confirmation -ProjectRoot $ProjectRoot
    } else {
        if ([string]::IsNullOrWhiteSpace($PhaseName)) {
            throw 'PhaseName is required when creating a checkpoint.'
        }

        New-RefactorCheckpoint -PhaseName $PhaseName -ProjectRoot $ProjectRoot | Out-Null
    }
}
