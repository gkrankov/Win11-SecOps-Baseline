#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sets up a security research environment on Windows 11 using winget + WSL2.

.DESCRIPTION
    Installs selected security tools, enables WSL2, installs Kali Linux, verifies
    installation state, and logs all actions to tools-setup.log.

.PARAMETER LogPath
    Absolute local path to the log file. Must end with .log.
#>
[CmdletBinding()]
param(
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) { throw 'LogPath cannot be empty.' }
        if (-not [System.IO.Path]::IsPathRooted($_)) { throw 'LogPath must be an absolute path.' }
        $fullPath = [System.IO.Path]::GetFullPath($_)
        if ($fullPath.StartsWith('\\')) { throw 'UNC/network LogPath is not allowed.' }
        if ([System.IO.Path]::GetExtension($fullPath).ToLowerInvariant() -ne '.log') { throw 'LogPath must have .log extension.' }
        if ($fullPath.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) { throw 'LogPath contains invalid path characters.' }
        $true
    })]
    [string] $LogPath = (Join-Path $PSScriptRoot 'tools-setup.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:WingetExe = $null

function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string] $Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogPath -Value $entry -Encoding UTF8

    switch ($Level) {
        'SUCCESS' { Write-Host $entry -ForegroundColor Green }
        'WARNING' { Write-Host $entry -ForegroundColor Yellow }
        'ERROR'   { Write-Host $entry -ForegroundColor Red }
        default   { Write-Host $entry -ForegroundColor Gray }
    }
}

function Write-Step {
    param([Parameter(Mandatory)] [string] $Title)
    $line = ('-' * 70)
    Write-Host "`n$line" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "$line" -ForegroundColor Cyan
    Write-Log "=== $Title ==="
}

function Initialize-LogPath {
    $script:LogPath = [System.IO.Path]::GetFullPath($LogPath)
    $parent = Split-Path -Path $script:LogPath -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (-not (Test-Path $script:LogPath)) {
        New-Item -ItemType File -Path $script:LogPath -Force | Out-Null
    }
}

function Resolve-WingetExecutable {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return $null
    }

    $source = $cmd.Source
    if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path $source)) {
        return $null
    }

    return [System.IO.Path]::GetFullPath($source)
}

function Test-WingetAvailable {
    return ($null -ne (Resolve-WingetExecutable))
}

function Test-AppInstallerBundleSignature {
    param([Parameter(Mandatory)] [string] $Path)

    $sig = Get-AuthenticodeSignature -FilePath $Path -ErrorAction Stop
    if ($sig.Status -ne 'Valid') {
        return $false
    }

    if (-not $sig.SignerCertificate) {
        return $false
    }

    if ($sig.SignerCertificate.Subject -notmatch '^CN=Microsoft') {
        return $false
    }

    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::Online
    $chain.ChainPolicy.RevocationFlag = [System.Security.Cryptography.X509Certificates.X509RevocationFlag]::ExcludeRoot
    $chain.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::NoFlag

    return $chain.Build($sig.SignerCertificate)
}

function Test-WingetPackageId {
    param([Parameter(Mandatory)] [string] $PackageId)

    return ($PackageId -match '^[A-Za-z0-9._-]+$')
}

function Invoke-WingetCommand {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [int] $TimeoutSeconds = 300
    )

    $process = Start-Process -FilePath $script:WingetExe `
                             -ArgumentList $Arguments `
                             -NoNewWindow `
                             -PassThru `
                             -ErrorAction Stop

    if ($null -eq $process) {
        throw 'Failed to start winget process.'
    }

    if (-not (Wait-Process -Id $process.Id -Timeout $TimeoutSeconds -ErrorAction SilentlyContinue)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "winget execution timed out after $TimeoutSeconds seconds."
    }

    if ($process.ExitCode -ne 0) {
        throw "winget returned exit code $($process.ExitCode)."
    }
}

function Install-WingetIfMissing {
    if (Test-WingetAvailable) {
        $script:WingetExe = Resolve-WingetExecutable
        Write-Log ("winget is already available at '{0}'." -f $script:WingetExe) -Level SUCCESS
        return
    }

    Write-Log 'winget was not found. Attempting App Installer bootstrap.' -Level WARNING

    $bundleUrl = 'https://aka.ms/getwinget'
    $tempBundle = Join-Path $env:TEMP ("Microsoft.DesktopAppInstaller-{0}.msixbundle" -f ([guid]::NewGuid().ToString('N')))

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $bundleUrl -OutFile $tempBundle -TimeoutSec 60 -ErrorAction Stop

        if (-not (Test-AppInstallerBundleSignature -Path $tempBundle)) {
            throw 'Downloaded App Installer bundle failed signature validation.'
        }

        Add-AppxPackage -Path $tempBundle -ErrorAction Stop
        Write-Log 'App Installer package bootstrap completed.' -Level SUCCESS
    } catch {
        Write-Log "Automatic winget install failed: $($_.Exception.Message)" -Level ERROR
    } finally {
        if (Test-Path $tempBundle) {
            Remove-Item -Path $tempBundle -Force -ErrorAction SilentlyContinue
        }
    }

    $script:WingetExe = Resolve-WingetExecutable
    if (-not $script:WingetExe) {
        throw 'winget is still unavailable. Install "App Installer" from Microsoft Store, then re-run this script.'
    }

    Write-Log ("winget installed and resolved at '{0}'." -f $script:WingetExe) -Level SUCCESS
}

function Test-WingetPackageInstalled {
    param([Parameter(Mandatory)] [string] $PackageId)

    if (-not (Test-WingetPackageId -PackageId $PackageId)) {
        throw "Invalid PackageId format: '$PackageId'."
    }

    try {
        $result = & $script:WingetExe list --exact --id $PackageId --source winget --accept-source-agreements 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }

        $text = ($result -join [Environment]::NewLine)
        return ($text -match [Regex]::Escape($PackageId))
    } catch {
        return $false
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $PackageId,
        [int] $Percent = 0
    )

    Write-Progress -Activity 'Installing security tools' -Status $Name -PercentComplete $Percent

    if (-not (Test-WingetPackageId -PackageId $PackageId)) {
        throw "Invalid PackageId format: '$PackageId'."
    }

    if (Test-WingetPackageInstalled -PackageId $PackageId) {
        Write-Log "$Name is already installed. Skipping." -Level WARNING
        return [PSCustomObject]@{
            Name      = $Name
            PackageId = $PackageId
            Status    = 'Skipped'
            Message   = 'Already installed'
        }
    }

    try {
        Write-Log "Installing $Name ($PackageId)..." -Level INFO
        Invoke-WingetCommand -Arguments @(
            'install', '--exact', '--id', $PackageId, '--source', 'winget', '--silent',
            '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
        )
    } catch {
        Write-Log ("Installation failed for {0}: {1}" -f $Name, $_.Exception.Message) -Level ERROR
        return [PSCustomObject]@{
            Name      = $Name
            PackageId = $PackageId
            Status    = 'Failed'
            Message   = $_.Exception.Message
        }
    }

    if (Test-WingetPackageInstalled -PackageId $PackageId) {
        Write-Log "$Name installation verified." -Level SUCCESS
        return [PSCustomObject]@{
            Name      = $Name
            PackageId = $PackageId
            Status    = 'Installed'
            Message   = 'Verified'
        }
    }

    Write-Log "$Name install command ran, but verification did not detect the package." -Level ERROR
    return [PSCustomObject]@{
        Name      = $Name
        PackageId = $PackageId
        Status    = 'Failed'
        Message   = 'Verification failed'
    }
}

function Enable-Wsl2 {
    Write-Step 'Enable WSL2 Platform Features'

    try {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -All -NoRestart -ErrorAction Stop | Out-Null
        Write-Log 'Enabled feature: Microsoft-Windows-Subsystem-Linux.' -Level SUCCESS
    } catch {
        Write-Log "Failed to enable Microsoft-Windows-Subsystem-Linux: $($_.Exception.Message)" -Level ERROR
    }

    try {
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction Stop | Out-Null
        Write-Log 'Enabled feature: VirtualMachinePlatform.' -Level SUCCESS
    } catch {
        Write-Log "Failed to enable VirtualMachinePlatform: $($_.Exception.Message)" -Level ERROR
    }

    try {
        & wsl --set-default-version 2 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Log 'WSL default version set to 2.' -Level SUCCESS
        } else {
            Write-Log 'Could not set WSL default version to 2 (may require reboot or WSL update).' -Level WARNING
        }
    } catch {
        Write-Log "Error setting WSL default version: $($_.Exception.Message)" -Level WARNING
    }
}

function Install-KaliLinuxWsl {
    Write-Step 'Install Kali Linux via WSL'

    $installedDistros = @()
    try {
        $installedDistros = & wsl --list --quiet 2>$null
    } catch {
        $installedDistros = @()
    }

    $installedText = ($installedDistros -join [Environment]::NewLine).ToLowerInvariant()
    if ($installedText -match 'kali') {
        Write-Log 'Kali Linux is already installed in WSL. Skipping.' -Level WARNING
        return [PSCustomObject]@{ Status = 'Skipped'; Message = 'Already installed' }
    }

    try {
        Write-Log 'Attempting WSL install for Kali Linux...' -Level INFO
        & wsl --install -d kali-linux
        if ($LASTEXITCODE -ne 0) {
            & wsl --install -d Kali-Linux
            if ($LASTEXITCODE -ne 0) {
                throw "wsl --install failed with exit code $LASTEXITCODE."
            }
        }
    } catch {
        Write-Log "WSL Kali install command failed: $($_.Exception.Message)" -Level ERROR
        return [PSCustomObject]@{ Status = 'Failed'; Message = $_.Exception.Message }
    }

    try {
        $postInstall = & wsl --list --quiet 2>$null
        $postText = ($postInstall -join [Environment]::NewLine).ToLowerInvariant()
        if ($postText -match 'kali') {
            Write-Log 'Kali Linux installation verified in WSL distributions.' -Level SUCCESS
            return [PSCustomObject]@{ Status = 'Installed'; Message = 'Verified' }
        }

        Write-Log 'Kali Linux not detected after install attempt. Install from Microsoft Store if needed.' -Level WARNING
        return [PSCustomObject]@{ Status = 'Failed'; Message = 'Verification failed' }
    } catch {
        Write-Log "Unable to verify Kali Linux installation: $($_.Exception.Message)" -Level WARNING
        return [PSCustomObject]@{ Status = 'Failed'; Message = $_.Exception.Message }
    }
}

Initialize-LogPath
Write-Log ("Tools setup started by {0} on {1}" -f $env:USERNAME, $env:COMPUTERNAME)
Write-Log "Log file: $LogPath"

Write-Step 'Check winget availability'
Install-WingetIfMissing

Write-Step 'Install security tools'
$tools = @(
    @{ Name = 'Wireshark';          Id = 'WiresharkFoundation.Wireshark' },
    @{ Name = 'Nmap';               Id = 'Insecure.Nmap' },
    @{ Name = 'Sysinternals Suite'; Id = 'Microsoft.Sysinternals' },
    @{ Name = 'Git';                Id = 'Git.Git' },
    @{ Name = 'Windows Terminal';   Id = 'Microsoft.WindowsTerminal' },
    @{ Name = 'Visual Studio Code'; Id = 'Microsoft.VisualStudioCode' },
    @{ Name = 'Hashcat';            Id = 'hashcat.hashcat' }
)

$installResults = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $tools.Count; $i++) {
    $percent = [int] ((($i + 1) / $tools.Count) * 100)
    $result = Install-WingetPackage -Name $tools[$i].Name -PackageId $tools[$i].Id -Percent $percent
    $installResults.Add($result)
}
Write-Progress -Activity 'Installing security tools' -Completed

Enable-Wsl2
$kaliResult = Install-KaliLinuxWsl

Write-Step 'Final verification summary'
foreach ($tool in $tools) {
    if (Test-WingetPackageInstalled -PackageId $tool.Id) {
        Write-Log ("Verified installed: {0}" -f $tool.Name) -Level SUCCESS
    } else {
        Write-Log ("Verification missing: {0}" -f $tool.Name) -Level ERROR
    }
}

try {
    $distroList = & wsl --list --quiet 2>$null
    $distroText = ($distroList -join [Environment]::NewLine).ToLowerInvariant()
    if ($distroText -match 'kali') {
        Write-Log 'Verified installed: Kali Linux (WSL).' -Level SUCCESS
    } else {
        Write-Log 'Verification missing: Kali Linux (WSL).' -Level WARNING
    }
} catch {
    Write-Log "Could not verify WSL distributions: $($_.Exception.Message)" -Level WARNING
}

$failedTools = $installResults | Where-Object { $_.Status -eq 'Failed' }
$hasCriticalFailure = (($failedTools | Measure-Object).Count -gt 0) -or ($kaliResult.Status -eq 'Failed')

Write-Host "`n$('=' * 70)" -ForegroundColor Cyan
if ($hasCriticalFailure) {
    Write-Host "  Tools setup finished with errors. Review tools-setup.log." -ForegroundColor Yellow
} else {
    Write-Host "  Tools setup complete. Review tools-setup.log for details." -ForegroundColor Cyan
}
Write-Host "  Log: $LogPath" -ForegroundColor Cyan
Write-Host "$('=' * 70)`n" -ForegroundColor Cyan

if ($hasCriticalFailure) {
    Write-Log 'Tools setup finished with one or more critical failures.' -Level ERROR
    exit 2
}

Write-Log 'Tools setup complete.' -Level SUCCESS
