<#
.SYNOPSIS
    netinfo — état du réseau en un coup d'œil (équivalent de « ip a » + « ifconfig »).
.DESCRIPTION
    Lecture seule, aucun droit administrateur requis. L'adresse IP publique est
    obtenue par une requête HTTPS vers api.ipify.org ; -Offline la désactive.
#>
[CmdletBinding()]
param(
    [switch]$Offline,
    [switch]$All,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')

if ($Help -or (Test-PstHelpArg $Rest)) {
    Show-PstHelp -Name 'netinfo' -Synopsis 'Interfaces, adresses, DNS, Wi-Fi et connectivité Internet.' `
        -Usage @('netinfo [-Offline] [-All] [-Json]') `
        -Options @(
            @('-Offline', 'Aucune requête vers Internet (pas d''IP publique ni de test)'),
            @('-All', 'Affiche aussi les interfaces déconnectées et virtuelles'),
            @('-Json', 'Sortie JSON, pour les scripts')
        ) `
        -Examples @('netinfo', 'netinfo -Offline', 'netinfo -Json')
    exit 0
}

Assert-PstWindows 'netinfo'

# ── Collecte ─────────────────────────────────────────────────────────────────

function Get-Adapters {
    $list = @()
    try {
        $configs = @(Get-NetIPConfiguration -All -ErrorAction Stop)
        foreach ($cfg in $configs) {
            $adapter = $cfg.NetAdapter
            if ($null -eq $adapter) { continue }
            $up = ($adapter.Status -eq 'Up')
            if (-not $All -and -not $up) { continue }
            $list += [ordered]@{
                Name        = $cfg.InterfaceAlias
                Description = $cfg.InterfaceDescription
                Up          = $up
                Speed       = [string]$adapter.LinkSpeed
                Mac         = [string]$adapter.MacAddress
                IPv4        = @($cfg.IPv4Address | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
                IPv6        = @($cfg.IPv6Address | Where-Object { $_.IPAddress -notlike 'fe80*' } | ForEach-Object { $_.IPAddress })
                Gateway     = @($cfg.IPv4DefaultGateway | ForEach-Object { $_.NextHop })
                Dns         = @($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses })
            }
        }
    }
    catch {
        # Repli CIM pour les systèmes sans le module NetTCPIP
        try {
            foreach ($n in @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' -ErrorAction Stop)) {
                $list += [ordered]@{
                    Name = $n.Description; Description = $n.Description; Up = $true; Speed = ''; Mac = [string]$n.MACAddress
                    IPv4 = @($n.IPAddress | Where-Object { $_ -notmatch ':' }); IPv6 = @($n.IPAddress | Where-Object { $_ -match ':' -and $_ -notlike 'fe80*' })
                    Gateway = @($n.DefaultIPGateway | Where-Object { $_ }); Dns = @($n.DNSServerSearchOrder | Where-Object { $_ })
                }
            }
        }
        catch { $null = $_ }
    }
    return $list
}

function Get-Wifi {
    # netsh traduit ses libellés : on se limite aux champs stables (SSID, Signal, %).
    try {
        $out = @(& netsh.exe wlan show interfaces 2>$null)
        $ssid = $null; $signal = $null
        foreach ($line in $out) {
            if ($line -match '^\s*SSID\s*:\s*(.+)$') { $ssid = $Matches[1].Trim() }
            elseif ($line -match ':\s*(\d{1,3})\s*%\s*$') { $signal = [int]$Matches[1] }
        }
        if ($ssid) { return [ordered]@{ Ssid = $ssid; Signal = $signal } }
    }
    catch { $null = $_ }
    return $null
}

function Test-Internet {
    $result = [ordered]@{ Reachable = $false; LatencyMs = $null; Dns = $false; PublicIP = $null }
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send('1.1.1.1', 2000)
        if ($reply.Status -eq 'Success') { $result.Reachable = $true; $result.LatencyMs = [int]$reply.RoundtripTime }
        $ping.Dispose()
    }
    catch { $null = $_ }
    try { $null = [System.Net.Dns]::GetHostAddresses('www.microsoft.com'); $result.Dns = $true } catch { $null = $_ }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $ip = Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 4 -UseBasicParsing -ErrorAction Stop
        if ("$ip" -match '^[0-9a-fA-F:.]+$') { $result.PublicIP = "$ip".Trim(); $result.Reachable = $true }
    }
    catch { $null = $_ }
    return $result
}

$adapters = @(Get-Adapters)
$wifi = Get-Wifi
$internet = $null
if (-not $Offline) { $internet = Test-Internet }

if ($Json) {
    [ordered]@{ Host = $env:COMPUTERNAME; Adapters = $adapters; Wifi = $wifi; Internet = $internet } | ConvertTo-Json -Depth 5
    exit 0
}

# ── Rendu ────────────────────────────────────────────────────────────────────

$g = $script:Pst.Glyph
$width = Get-PstWidth -Max 90
Show-PstHeader -Tool 'netinfo' -Subtitle $env:COMPUTERNAME

function Row {
    param([string]$Label, $Value)
    $text = (@($Value) | Where-Object { $_ }) -join ', '
    if (-not $text) { return $null }
    return (Paint (Format-PstPad $Label 12) 'Accent') + (Limit-PstText $text ($width - 18))
}

if ($internet) {
    $lines = @()
    if ($internet.Reachable) {
        $latency = ''
        if ($null -ne $internet.LatencyMs) { $latency = "  $($g.Dot) $($internet.LatencyMs) ms vers 1.1.1.1" }
        $lines += (Paint "$($g.Ok) Connecté à Internet" 'Ok' -Bold) + (Paint $latency 'Dim')
    }
    else { $lines += Paint "$($g.Err) Pas d'accès à Internet" 'Err' -Bold }
    if ($internet.Dns) { $lines += Row 'DNS' 'résolution fonctionnelle' }
    else { $lines += (Paint (Format-PstPad 'DNS' 12) 'Accent') + (Paint 'résolution en échec' 'Err') }
    $lines += Row 'IP publique' $internet.PublicIP
    $color = 'Ok'
    if (-not $internet.Reachable) { $color = 'Err' }
    Format-PstBox -Title 'Internet' -Lines @($lines | Where-Object { $_ }) -Width $width -Color $color | Write-PstLine
}

if ($wifi) {
    $signalText = ''
    if ($null -ne $wifi.Signal) {
        $signalColor = 'Ok'
        if ($wifi.Signal -lt 40) { $signalColor = 'Err' } elseif ($wifi.Signal -lt 65) { $signalColor = 'Warn' }
        $signalText = (Format-PstBar $wifi.Signal 16 -Color $signalColor) + " $($wifi.Signal) %"
    }
    $lines = @((Row 'Réseau' $wifi.Ssid))
    if ($signalText) { $lines += (Paint (Format-PstPad 'Signal' 12) 'Accent') + $signalText }
    Format-PstBox -Title 'Wi-Fi' -Lines $lines -Width $width | Write-PstLine
}

if ($adapters.Count -eq 0) { Write-PstStatus warn 'Aucune interface réseau active.' }
foreach ($a in $adapters) {
    $state = Paint 'connectée' 'Ok'
    if (-not $a.Up) { $state = Paint 'déconnectée' 'Dim' }
    $lines = @(
        ((Paint (Format-PstPad 'État' 12) 'Accent') + $state + (Paint "  $($a.Speed)" 'Dim')),
        (Row 'Carte' $a.Description), (Row 'IPv4' $a.IPv4), (Row 'IPv6' $a.IPv6),
        (Row 'Passerelle' $a.Gateway), (Row 'DNS' $a.Dns), (Row 'MAC' $a.Mac)
    )
    Format-PstBox -Title $a.Name -Lines @($lines | Where-Object { $_ }) -Width $width | Write-PstLine
}
Write-Host ''
