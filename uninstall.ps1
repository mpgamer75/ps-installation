<#
.SYNOPSIS
    ps-tools uninstaller (bootstrap).

.DESCRIPTION
    Removes ps-tools for the current user without administrator rights.
    An "all users" installation is removed when run from an elevated terminal
    (the script offers to elevate when needed).

        irm https://raw.githubusercontent.com/mpgamer75/ps-installation/main/uninstall.ps1 | iex

    Pure ASCII on purpose, like install.ps1, which does the actual work.

.PARAMETER Yes
    Never prompt (personal data is kept unless -PurgeData is given).
.PARAMETER PurgeData
    Also delete personal data (saved reminders).
.PARAMETER Source
    Repository root (local folder or URL). Can also be set with $env:PSTOOLS_SOURCE.
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$PurgeData,
    [string]$Source,
    [string]$InstallRoot
)

& {
    param($Bound, $ScriptRoot)
    $ErrorActionPreference = 'Stop'

    $source = $Bound['Source']
    if (-not $source) { $source = $env:PSTOOLS_SOURCE }
    if (-not $source -and $ScriptRoot -and (Test-Path -LiteralPath (Join-Path $ScriptRoot 'install.ps1'))) { $source = $ScriptRoot }
    if (-not $source) { $source = 'https://raw.githubusercontent.com/mpgamer75/ps-installation/main' }
    $Bound['Source'] = $source

    try {
        if ($source -match '^https?://') {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }
            $client = New-Object System.Net.WebClient
            try { $text = $client.DownloadString($source.TrimEnd('/') + '/install.ps1') }
            finally { $client.Dispose() }
        }
        else { $text = [IO.File]::ReadAllText((Join-Path $source 'install.ps1')) }
    }
    catch {
        Write-Host ('  ps-tools: unable to load the uninstaller from ' + $source) -ForegroundColor Red
        Write-Host ('  ' + $_.Exception.Message) -ForegroundColor DarkGray
        return
    }
    & ([scriptblock]::Create($text)) -Uninstall @Bound
} $PSBoundParameters $PSScriptRoot
