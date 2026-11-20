<#
.SYNOPSIS
    sysinfo — carte d'identité de la machine, façon neofetch.
.DESCRIPTION
    Lecture seule, aucun droit administrateur requis.
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$NoLogo,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'sysinfo'

if ($Help -or (Test-PstHelpArg $Rest)) {
    Show-PstHelp -Name 'sysinfo' -Synopsis (L 'Résumé matériel et logiciel de la machine.') `
        -Usage @('sysinfo [-Json] [-NoLogo]') `
        -Options @(@('-Json', (L 'Sortie JSON, pour les scripts')), @('-NoLogo', (L 'Masque le logo'))) `
        -Examples @('sysinfo', 'sysinfo -Json | ConvertFrom-Json')
    exit 0
}

Assert-PstWindows 'sysinfo'

function Get-Cim {
    param([string]$Class, [string]$Filter)
    try {
        if ($Filter) { return @(Get-CimInstance -ClassName $Class -Filter $Filter -ErrorAction Stop) }
        return @(Get-CimInstance -ClassName $Class -ErrorAction Stop)
    }
    catch { return @() }
}

$os = (Get-Cim Win32_OperatingSystem) | Select-Object -First 1
$cs = (Get-Cim Win32_ComputerSystem) | Select-Object -First 1
$cpu = (Get-Cim Win32_Processor) | Select-Object -First 1
$gpus = Get-Cim Win32_VideoController
$disks = Get-Cim Win32_LogicalDisk 'DriveType=3'
$battery = (Get-Cim Win32_Battery) | Select-Object -First 1

$data = [ordered]@{
    User       = $env:USERNAME
    Host       = $env:COMPUTERNAME
    OS         = ''
    Build      = ''
    Model      = ''
    Uptime     = ''
    Shell      = "PowerShell $($PSVersionTable.PSVersion)"
    Terminal   = ''
    Resolution = ''
    CPU        = ''
    GPU        = @()
    MemoryUsed = 0
    MemoryTotal = 0
    Disks      = @()
    Battery    = $null
    LocalIP    = ''
    Admin      = (Test-PstAdmin)
}

if ($os) {
    $data.OS = "$($os.Caption) $($os.OSArchitecture)".Replace('Microsoft ', '').Trim()
    $data.Build = [string]$os.Version
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($cv.DisplayVersion) { $data.Build = "$($cv.DisplayVersion) (build $($cv.CurrentBuild).$($cv.UBR))" }
    }
    catch { $null = $_ }
    $data.Uptime = Format-PstDuration ((Get-Date) - $os.LastBootUpTime)
    $data.MemoryTotal = [double]$os.TotalVisibleMemorySize * 1KB
    $data.MemoryUsed = $data.MemoryTotal - ([double]$os.FreePhysicalMemory * 1KB)
}
if ($cs) { $data.Model = ("$($cs.Manufacturer) $($cs.Model)" -replace '\s+', ' ').Trim() }
if ($cpu) { $data.CPU = (("$($cpu.Name)" -replace '\s+', ' ').Trim() + ' ' + (L '({0} cœurs / {1} threads)' $cpu.NumberOfCores $cpu.NumberOfLogicalProcessors)) }
$data.GPU = @($gpus | Where-Object { $_.Name } | ForEach-Object { $_.Name })
$screen = $gpus | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
if ($screen) { $data.Resolution = "$($screen.CurrentHorizontalResolution) x $($screen.CurrentVerticalResolution) @ $($screen.CurrentRefreshRate) Hz" }
$data.Disks = @($disks | Where-Object { $_.Size -gt 0 } | ForEach-Object {
        [ordered]@{ Name = $_.DeviceID; Total = [double]$_.Size; Free = [double]$_.FreeSpace }
    })
if ($battery) {
    $data.Battery = [ordered]@{
        Percent  = [int]$battery.EstimatedChargeRemaining
        Charging = (@(2, 6, 7, 8, 9) -contains [int]$battery.BatteryStatus)
    }
}
if ($env:WT_SESSION) { $data.Terminal = 'Windows Terminal' }
elseif ($env:TERM_PROGRAM) { $data.Terminal = $env:TERM_PROGRAM }
else { $data.Terminal = L 'Console Windows' }
try {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.AddressState -eq 'Preferred' } |
        Sort-Object InterfaceMetric | Select-Object -First 1
    if ($ip) { $data.LocalIP = $ip.IPAddress }
}
catch { $null = $_ }

if ($Json) {
    $data | ConvertTo-Json -Depth 4
    exit 0
}

# ── Rendu ────────────────────────────────────────────────────────────────────

$g = $script:Pst.Glyph
function Row {
    param([string]$Label, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return (Paint (Format-PstPad $Label 11) 'Accent' -Bold) + $Value
}

$info = @()
$title = "$($data.User)@$($data.Host)"
$info += Format-PstGradient $title -Bold
$info += Paint ($g.H * $title.Length) 'Dim'
$info += Row (L 'Système') $data.OS
$info += Row (L 'Version') $data.Build
$info += Row 'Machine' $data.Model
$info += Row (L 'Démarré') (L 'depuis {0}' $data.Uptime)
$info += Row 'Shell' $data.Shell
$info += Row 'Terminal' $data.Terminal
$info += Row (L 'Écran') $data.Resolution
$info += Row 'CPU' $data.CPU
foreach ($name in $data.GPU) { $info += Row 'GPU' $name }
if ($data.MemoryTotal -gt 0) {
    $pct = $data.MemoryUsed / $data.MemoryTotal * 100
    $info += Row (L 'Mémoire') ((Format-PstBar $pct 14) + " $(Format-PstSize $data.MemoryUsed) / $(Format-PstSize $data.MemoryTotal)")
}
foreach ($d in $data.Disks) {
    $pct = ($d.Total - $d.Free) / $d.Total * 100
    $info += Row (L 'Disque {0}' $d.Name) ((Format-PstBar $pct 14 -Color (Get-PstLevelColor $pct 80 92)) + " $(Format-PstSize ($d.Total - $d.Free)) / $(Format-PstSize $d.Total)")
}
if ($data.Battery) {
    $state = L 'sur batterie'
    if ($data.Battery.Charging) { $state = L 'sur secteur' }
    $info += Row (L 'Batterie') (L '{0} % ({1})' $data.Battery.Percent $state)
}
$info += Row (L 'IP locale') $data.LocalIP
$session = L 'utilisateur standard'
if ($data.Admin) { $session = L 'administrateur' }
$info += Row 'Session' $session
$info += ''
$swatch = ''
foreach ($c in 'Accent', 'Accent2', 'Ok', 'Warn', 'Err', 'Dim', 'Title') { $swatch += Paint ($g.Full * 3) $c }
$info += $swatch
$info = @($info | Where-Object { $null -ne $_ })

# Logo original : quatre vitres, clin d'œil aux fenêtres du système.
$logo = @(
    ' ███████████  ███████████',
    ' ███████████  ███████████',
    ' ███████████  ███████████',
    ' ███████████  ███████████',
    ' ███████████  ███████████',
    '                         ',
    ' ███████████  ███████████',
    ' ███████████  ███████████',
    ' ███████████  ███████████',
    ' ███████████  ███████████',
    ' ███████████  ███████████'
)
if ($env:PSTOOLS_ASCII) { $NoLogo = $true }

Write-Host ''
if ($NoLogo) { $info | ForEach-Object { Write-Host "  $_" } }
else {
    $logoWidth = 28
    $rows = [Math]::Max($logo.Count, $info.Count)
    for ($i = 0; $i -lt $rows; $i++) {
        $left = ''
        if ($i -lt $logo.Count) { $left = Format-PstGradient $logo[$i] -Span 25 }
        $right = ''
        if ($i -lt $info.Count) { $right = $info[$i] }
        Write-Host ((Format-PstPad $left $logoWidth) + $right)
    }
}
Write-Host ''
