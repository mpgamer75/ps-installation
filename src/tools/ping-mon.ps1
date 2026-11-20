<#
.SYNOPSIS
    ping-mon — surveillance de latence multi-hôtes avec historique et statistiques.
.DESCRIPTION
    Aucun droit administrateur requis. Tous les hôtes sont interrogés en parallèle.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Hosts,
    [ValidateRange(1, 60)][int]$Interval = 1,
    [ValidateRange(0, 100000)][int]$Count = 0,
    [ValidateRange(200, 10000)][int]$Timeout = 1500,
    [switch]$Help
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')

if ($Help -or (Test-PstHelpArg $Hosts)) {
    Show-PstHelp -Name 'ping-mon' -Synopsis 'Surveille la latence de plusieurs hôtes en même temps.' `
        -Usage @('ping-mon [hôtes...] [-Interval <s>] [-Count <n>] [-Timeout <ms>]') `
        -Options @(
            @('hôtes', 'Noms ou adresses IP (défaut : passerelle, 1.1.1.1, 8.8.8.8, google.com)'),
            @('-Interval <s>', 'Délai entre deux séries de pings (défaut : 1)'),
            @('-Count <n>', 'Nombre de séries puis bilan (défaut : 0 = illimité)'),
            @('-Timeout <ms>', 'Délai d''attente d''une réponse (défaut : 1500)')
        ) `
        -Examples @('ping-mon', 'ping-mon github.com 192.168.1.1', 'ping-mon 1.1.1.1 -Count 20') `
        -Notes @('Touches : Q quitter · R remettre les statistiques à zéro')
    exit 0
}

function Get-DefaultGateway {
    if (-not $script:Pst.IsWindows) { return $null }
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
        if ($route -and $route.NextHop -and $route.NextHop -ne '0.0.0.0') { return $route.NextHop }
    }
    catch { $null = $_ }
    return $null
}

function New-Target {
    param([string]$Address, [string]$Label)
    return @{
        Address = $Address; Label = $Label
        Sent = 0; Lost = 0; Last = $null; Min = $null; Max = 0.0; Sum = 0.0; Jitter = 0.0; Prev = $null
        History = New-Object System.Collections.ArrayList
        Error = ''
    }
}

$targets = @()
if ($Hosts) {
    foreach ($h in $Hosts) { if ($h -and -not $h.StartsWith('-')) { $targets += New-Target $h $h } }
}
if ($targets.Count -eq 0) {
    $gw = Get-DefaultGateway
    if ($gw) { $targets += New-Target $gw 'Passerelle' }
    $targets += New-Target '1.1.1.1' 'Cloudflare DNS'
    $targets += New-Target '8.8.8.8' 'Google DNS'
    $targets += New-Target 'google.com' 'google.com'
}

function Invoke-PingRound {
    # Lance tous les pings en parallèle puis met à jour les statistiques.
    $jobs = @()
    foreach ($t in $targets) {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $task = $null
        try { $task = $ping.SendPingAsync($t.Address, $Timeout) } catch { $task = $null }
        $jobs += @{ Target = $t; Ping = $ping; Task = $task }
    }
    foreach ($j in $jobs) {
        $t = $j.Target
        $t.Sent++
        $ms = $null
        $t.Error = ''
        try {
            if ($null -eq $j.Task) { throw 'envoi impossible' }
            $reply = $j.Task.GetAwaiter().GetResult()
            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $ms = [double]$reply.RoundtripTime }
            else { $t.Error = [string]$reply.Status }
        }
        catch {
            $inner = $_.Exception
            while ($inner.InnerException) { $inner = $inner.InnerException }
            $t.Error = $inner.Message
        }
        finally { $j.Ping.Dispose() }

        if ($null -eq $ms) { $t.Lost++; $t.Last = $null; [void]$t.History.Add($null) }
        else {
            $t.Last = $ms
            $t.Sum += $ms
            if ($null -eq $t.Min -or $ms -lt $t.Min) { $t.Min = $ms }
            if ($ms -gt $t.Max) { $t.Max = $ms }
            # Gigue lissée (RFC 3550)
            if ($null -ne $t.Prev) { $t.Jitter += ([Math]::Abs($ms - $t.Prev) - $t.Jitter) / 16 }
            $t.Prev = $ms
            [void]$t.History.Add($ms)
        }
        while ($t.History.Count -gt 120) { $t.History.RemoveAt(0) }
    }
}

function Get-LatencyColor {
    param($Ms)
    if ($null -eq $Ms) { return 'Err' }
    if ($Ms -lt 50) { return 'Ok' }
    if ($Ms -lt 120) { return 'Warn' }
    return 'Err'
}

function Format-Ms {
    param($Value)
    if ($null -eq $Value) { return '-' }
    return ('{0:N0} ms' -f $Value)
}

function Get-Frame {
    param([switch]$Summary)
    $g = $script:Pst.Glyph
    $width = Get-PstWidth -Max 110
    $sparkW = [Math]::Max(10, $width - 82)
    $rows = @()
    foreach ($t in $targets) {
        $ok = $t.Sent - $t.Lost
        $avg = $null
        if ($ok -gt 0) { $avg = $t.Sum / $ok }
        $loss = 0
        if ($t.Sent -gt 0) { $loss = $t.Lost / $t.Sent * 100 }
        $lossColor = 'Ok'
        if ($loss -ge 5) { $lossColor = 'Err' } elseif ($loss -gt 0) { $lossColor = 'Warn' }

        if ($null -ne $t.Last) { $state = (Paint $g.Info 'Ok') ; $last = Paint (Format-Ms $t.Last) (Get-LatencyColor $t.Last) -Bold }
        elseif ($t.Sent -eq 0) { $state = Paint $g.Info 'Dim'; $last = Paint '...' 'Dim' }
        else { $state = Paint $g.Err 'Err'; $last = Paint 'perdu' 'Err' -Bold }

        $name = $t.Label
        if ($t.Label -ne $t.Address) { $name = "$($t.Label) ($($t.Address))" }
        $maxShown = $null
        if ($ok -gt 0) { $maxShown = $t.Max }
        $rows += , @(
            ("$state " + (Limit-PstText $name 28)), $last, (Format-Ms $t.Min), (Format-Ms $avg), (Format-Ms $maxShown),
            ('{0:N1} ms' -f $t.Jitter), (Paint ('{0:N1} %' -f $loss) $lossColor),
            (Paint (Format-PstSparkline $t.History.ToArray() -Width $sparkW) (Get-LatencyColor $avg))
        )
    }
    $table = Format-PstTable -Columns @(
        @{ Name = '  Hôte'; Width = 30 }, @{ Name = 'Dernier'; Width = 8; Right = $true },
        @{ Name = 'Min'; Width = 7; Right = $true }, @{ Name = 'Moy'; Width = 7; Right = $true },
        @{ Name = 'Max'; Width = 7; Right = $true }, @{ Name = 'Gigue'; Width = 8; Right = $true },
        @{ Name = 'Pertes'; Width = 7; Right = $true }, @{ Name = 'Historique'; Width = $sparkW }
    ) -Rows $rows

    $lines = @()
    $sub = "$($targets.Count) hôte(s) $($g.Dot) toutes les ${Interval}s"
    if ($Summary) { $sub = 'bilan' }
    $lines += ' ' + (Get-PstHeaderLine -Tool 'ping-mon' -Subtitle $sub -Width ($width - 1))
    $lines += ''
    foreach ($l in $table) { $lines += ' ' + $l }
    $errors = @($targets | Where-Object { $_.Error -and $_.Error -ne 'TimedOut' })
    if ($errors.Count) {
        $lines += ''
        foreach ($t in $errors) { $lines += ' ' + (Paint (Limit-PstText "$($g.Warn) $($t.Address) : $($t.Error)" ($width - 2)) 'Warn') }
    }
    if (-not $Summary) {
        $lines += ''
        $lines += ' ' + (Paint "Q quitter $($g.Dot) R remise à zéro $($g.Dot) série n° $($targets[0].Sent)" 'Dim')
    }
    return $lines
}

$interactive = Test-PstInteractive
if (-not $interactive -and $Count -eq 0) { $Count = 4 }

if ($interactive) { Start-PstScreen }
try {
    $round = 0
    while ($true) {
        Invoke-PingRound
        $round++
        if ($interactive) { Write-PstFrame (Get-Frame) }
        if ($Count -gt 0 -and $round -ge $Count) { break }
        if ($interactive) {
            $key = Read-PstKey -TimeoutMs ($Interval * 1000)
            if (Test-PstQuitKey $key) { break }
            if ($key -and $key.Key -eq 'R') {
                $targets = @($targets | ForEach-Object { New-Target $_.Address $_.Label })
            }
        }
        else { Start-Sleep -Seconds $Interval }
    }
}
finally { if ($interactive) { Stop-PstScreen } }

# Bilan conservé à l'écran après la sortie
Write-Host ''
Get-Frame -Summary | Write-PstLine
Write-Host ''
