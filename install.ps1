<#
.SYNOPSIS
    ps-tools installer (bootstrap).

.DESCRIPTION
    Works with or without administrator rights:
      - standard user  -> installs to %LOCALAPPDATA%\ps-tools (user PATH)
      - administrator  -> you choose: current user, or all users (%ProgramFiles%\ps-tools)

    One-liner:
        irm https://raw.githubusercontent.com/mpgamer75/ps-installation/main/install.ps1 | iex

    With options:
        & ([scriptblock]::Create((irm https://raw.githubusercontent.com/mpgamer75/ps-installation/main/install.ps1))) -Scope AllUsers

    This file is intentionally pure ASCII so that it survives any download
    encoding. It only fetches the UI library and the setup engine (UTF-8) and
    hands over to them.

.PARAMETER Scope
    Auto (default), CurrentUser or AllUsers. Can also be set with $env:PSTOOLS_SCOPE.
.PARAMETER Tools
    Install only these tools (comma separated). Default: all.
.PARAMETER Source
    Repository root (local folder or URL). Can also be set with $env:PSTOOLS_SOURCE.
.PARAMETER InstallRoot
    Custom destination folder (advanced / tests).
.PARAMETER NoPath
    Do not modify the PATH environment variable.
.PARAMETER Yes
    Never prompt.
.PARAMETER Uninstall
    Remove ps-tools instead of installing it.
.PARAMETER PurgeData
    With -Uninstall: also delete personal data (saved reminders).
#>
[CmdletBinding()]
param(
    [string]$Scope,
    [string[]]$Tools,
    [string]$Source,
    [string]$InstallRoot,
    [switch]$NoPath,
    [switch]$Yes,
    [switch]$Uninstall,
    [switch]$PurgeData,
    [switch]$Deferred
)

# Everything runs inside a child scope: nothing leaks into the caller's
# session when the script is piped to Invoke-Expression.
& {
    param($Bound, $ScriptRoot)
    $ErrorActionPreference = 'Stop'

    if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
        Write-Host 'ps-tools requires PowerShell 5.1 or later.' -ForegroundColor Red
        return
    }

    $source = $Bound['Source']
    if (-not $source) { $source = $env:PSTOOLS_SOURCE }
    if (-not $source -and $ScriptRoot -and (Test-Path -LiteralPath (Join-Path $ScriptRoot 'src/lib/PsTools.ps1'))) { $source = $ScriptRoot }
    if (-not $source) { $source = 'https://raw.githubusercontent.com/mpgamer75/ps-installation/main' }
    $Bound['Source'] = $source
    if (-not $Bound['Scope'] -and $env:PSTOOLS_SCOPE) { $Bound['Scope'] = $env:PSTOOLS_SCOPE }
    if (-not $Bound['Scope']) { $null = $Bound.Remove('Scope') }

    function Get-BootstrapText {
        param([string]$RelativePath)
        if ($source -match '^https?://') {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }
            $client = New-Object System.Net.WebClient
            $client.Encoding = [System.Text.Encoding]::UTF8
            try { $text = $client.DownloadString($source.TrimEnd('/') + '/' + $RelativePath) }
            finally { $client.Dispose() }
        }
        else {
            $file = $source
            foreach ($part in ($RelativePath -split '/')) { $file = Join-Path $file $part }
            $text = [IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
        }
        return $text.TrimStart([char]0xFEFF)
    }

    try {
        $libText = Get-BootstrapText 'src/lib/PsTools.ps1'
        $setupText = Get-BootstrapText 'src/setup.ps1'
    }
    catch {
        Write-Host ''
        Write-Host ('  ps-tools: unable to load the installer from ' + $source) -ForegroundColor Red
        Write-Host ('  ' + $_.Exception.Message) -ForegroundColor DarkGray
        Write-Host '  Check your Internet connection (or corporate proxy) and try again.'
        Write-Host ''
        return
    }

    # Loaded from memory: no temporary file, so the execution policy and the
    # console code page cannot get in the way.
    . ([scriptblock]::Create($libText))
    try { & ([scriptblock]::Create($setupText)) @Bound }
    catch {
        Write-Host ''
        Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ''
        $global:LASTEXITCODE = 1
    }
    finally { Remove-Variable -Name Pst -Scope Script -ErrorAction SilentlyContinue }
} $PSBoundParameters $PSScriptRoot
