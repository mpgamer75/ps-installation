<#
.SYNOPSIS
    monitor — tableau de bord système en temps réel (CPU, mémoire, disques, réseau, processus).
.DESCRIPTION
    Fonctionne sans droits administrateur. En mode utilisateur, les processus
    protégés du système n'exposent pas leur temps CPU et sont simplement ignorés.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 60)][int]$Interval = 2,
    [ValidateRange(3, 30)][int]$Top = 8,
    [ValidateSet('cpu', 'mem')][string]$Sort = 'cpu',
    [switch]$Once,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'monitor'

if ($Help -or (Test-PstHelpArg $Rest)) {
    Show-PstHelp -Name 'monitor' -Synopsis (L 'Tableau de bord système en temps réel.') `
        -Usage @('monitor [-Interval <s>] [-Top <n>] [-Sort cpu|mem] [-Once]') `
        -Options @(
            @('-Interval <s>', (L 'Délai de rafraîchissement en secondes (défaut : 2)')),
            @('-Top <n>', (L 'Nombre de processus affichés (défaut : 8)')),
            @('-Sort cpu|mem', (L 'Tri initial des processus')),
            @('-Once', (L 'Affiche un instantané puis quitte (pratique pour les scripts)'))
        ) `
        -Examples @('monitor', 'monitor -Interval 1 -Top 12', 'monitor -Once') `
        -Notes @((L 'Touches : Q quitter · C tri CPU · M tri mémoire · P pause · +/- vitesse'))
    exit 0
}

Assert-PstWindows 'monitor'

# ── Collecte ─────────────────────────────────────────────────────────────────

$state = @{
    Sort      = $Sort
    Interval  = $Interval
    Paused    = $false
    CpuHist   = New-Object System.Collections.ArrayList
    RxHist    = New-Object System.Collections.ArrayList
    TxHist    = New-Object System.Collections.ArrayList
    ProcTimes = @{}
    LastTick  = [DateTime]::UtcNow
    Cores     = [Environment]::ProcessorCount
}

function Add-Sample {
    param([System.Collections.ArrayList]$List, $Value, [int]$Max = 60)
    [void]$List.Add($Value)
    while ($List.Count -gt $Max) { $List.RemoveAt(0) }
}

function Get-StaticInfo {
    $info = @{ Os = 'Windows'; Cpu = (L 'Processeur'); Boot = $null; Host = $env:COMPUTERNAME }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $info.Os = "$($os.Caption) ($($os.Version))".Replace('Microsoft ', '')
        $info.Boot = $os.LastBootUpTime
    }
    catch { $null = $_ }
    try {
        $cpu = @(Get-CimInstance Win32_Processor -ErrorAction Stop)[0]
        $info.Cpu = ($cpu.Name -replace '\s+', ' ').Trim()
    }
    catch { $null = $_ }
    return $info
}

function Get-Snapshot {
    $snap = @{
        CpuTotal = 0; CpuCores = @(); MemTotal = 0; MemUsed = 0
        Disks = @(); Rx = 0; Tx = 0; Battery = $null; Procs = @(); ProcCount = 0
    }

    # CPU (classes CIM : noms non localisés, lisibles sans droits admin)
    try {
        $perf = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop)
        foreach ($p in $perf) {
            if ($p.Name -eq '_Total') { $snap.CpuTotal = [double]$p.PercentProcessorTime }
        }
        $snap.CpuCores = @($perf | Where-Object { $_.Name -ne '_Total' } |
                Sort-Object { [int]$_.Name } | ForEach-Object { [double]$_.PercentProcessorTime })
    }
    catch { $null = $_ }

    # Mémoire (valeurs CIM en Ko)
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $snap.MemTotal = [double]$os.TotalVisibleMemorySize * 1KB
        $snap.MemUsed = $snap.MemTotal - ([double]$os.FreePhysicalMemory * 1KB)
    }
    catch { $null = $_ }

    # Disques fixes
    try {
        $snap.Disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
                Where-Object { $_.Size -gt 0 } | ForEach-Object {
                    @{ Name = $_.DeviceID; Label = $_.VolumeName; Total = [double]$_.Size; Free = [double]$_.FreeSpace }
                })
    }
    catch { $null = $_ }

    # Débit réseau (octets/s, toutes interfaces physiques confondues)
    try {
        $nics = @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -ErrorAction Stop |
                Where-Object { $_.Name -notmatch 'isatap|Loopback|Teredo|6to4' })
        foreach ($n in $nics) {
            $snap.Rx += [double]$n.BytesReceivedPersec
            $snap.Tx += [double]$n.BytesSentPersec
        }
    }
    catch { $null = $_ }

    # Batterie (absente sur un poste fixe)
    try {
        $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
        if ($bat.Count -gt 0) {
            $snap.Battery = @{
                Percent  = [double]$bat[0].EstimatedChargeRemaining
                Charging = (@(2, 6, 7, 8, 9) -contains [int]$bat[0].BatteryStatus)
            }
        }
    }
    catch { $null = $_ }

    # Processus : % CPU calculé par différence de temps processeur entre deux relevés
    $now = [DateTime]::UtcNow
    $elapsed = [Math]::Max(($now - $state.LastTick).TotalSeconds, 0.1)
    $newTimes = @{}
    $list = New-Object System.Collections.ArrayList
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $cpuSec = $null
        try { $cpuSec = $p.TotalProcessorTime.TotalSeconds } catch { $cpuSec = $null }
        $pct = 0.0
        if ($null -ne $cpuSec) {
            $newTimes[$p.Id] = $cpuSec
            if ($state.ProcTimes.ContainsKey($p.Id)) {
                $pct = (($cpuSec - $state.ProcTimes[$p.Id]) / $elapsed) * 100 / $state.Cores
                $pct = [Math]::Max(0, [Math]::Min(100, $pct))
            }
        }
        [void]$list.Add(@{ Id = $p.Id; Name = $p.ProcessName; Cpu = $pct; Mem = [double]$p.WorkingSet64; Threads = $p.Threads.Count })
    }
    $state.ProcTimes = $newTimes
    $state.LastTick = $now
    $snap.Procs = $list
    $snap.ProcCount = $list.Count
    return $snap
}

# ── Rendu ────────────────────────────────────────────────────────────────────

function Get-Frame {
    param($Info, $Snap)
    $g = $script:Pst.Glyph
    $width = Get-PstWidth -Max 96
    $inner = $width - 4
    $barW = [Math]::Max(16, [Math]::Min(34, $inner - 46))
    $lines = @()

    $sub = "$($Info.Host)"
    if ($Info.Boot) { $sub += ' ' + $g.Dot + ' ' + (L 'actif depuis {0}' (Format-PstDuration ((Get-Date) - $Info.Boot))) }
    $lines += ' ' + (Get-PstHeaderLine -Tool 'monitor' -Subtitle $sub -Width ($width - 1))
    $lines += ' ' + (Paint (Limit-PstText "$($Info.Os) $($g.Dot) $($Info.Cpu)" ($width - 2)) 'Dim')
    $lines += ''

    # Processeur
    $cpuColor = Get-PstLevelColor $Snap.CpuTotal
    $cpuLines = @(
        ((Format-PstPad 'Total' 8) + (Format-PstBar $Snap.CpuTotal $barW) + ' ' + (Paint ('{0,5:N1} %' -f $Snap.CpuTotal) $cpuColor -Bold) +
            '  ' + (Paint (Format-PstSparkline $state.CpuHist.ToArray() -Width ($inner - $barW - 20) -Max 100) 'Accent'))
    )
    if ($Snap.CpuCores.Count -gt 0) {
        $cores = ''
        foreach ($c in $Snap.CpuCores) {
            $idx = [int][Math]::Floor(([Math]::Min($c, 100) / 100) * ($g.Spark.Count - 1))
            $cores += Paint $g.Spark[$idx] (Get-PstLevelColor $c)
        }
        $cpuLines += (Format-PstPad (L 'Cœurs') 8) + $cores + (Paint ('  ' + (L '{0} threads' $Snap.CpuCores.Count)) 'Dim')
    }
    $lines += Format-PstBox -Title (L 'Processeur') -Lines $cpuLines -Width $width

    # Mémoire + batterie
    $memPct = 0
    if ($Snap.MemTotal -gt 0) { $memPct = $Snap.MemUsed / $Snap.MemTotal * 100 }
    $memLines = @(
        ((Format-PstPad 'RAM' 8) + (Format-PstBar $memPct $barW) + ' ' + (Paint ('{0,5:N1} %' -f $memPct) (Get-PstLevelColor $memPct) -Bold) +
            (Paint "  $(Format-PstSize $Snap.MemUsed) / $(Format-PstSize $Snap.MemTotal)" 'Dim'))
    )
    if ($Snap.Battery) {
        $batColor = 'Ok'
        if ($Snap.Battery.Percent -lt 20) { $batColor = 'Err' } elseif ($Snap.Battery.Percent -lt 40) { $batColor = 'Warn' }
        $batState = L 'sur batterie'
        if ($Snap.Battery.Charging) { $batState = L 'sur secteur' }
        $memLines += (Format-PstPad (L 'Batt.') 8) + (Format-PstBar $Snap.Battery.Percent $barW -Color $batColor) + ' ' +
            (Paint ('{0,5:N0} %' -f $Snap.Battery.Percent) $batColor -Bold) + (Paint "  $batState" 'Dim')
    }
    $lines += Format-PstBox -Title (L 'Mémoire') -Lines $memLines -Width $width

    # Disques
    $diskLines = @()
    foreach ($d in $Snap.Disks) {
        $pct = ($d.Total - $d.Free) / $d.Total * 100
        $diskLines += (Format-PstPad $d.Name 8) + (Format-PstBar $pct $barW) + ' ' + (Paint ('{0,5:N1} %' -f $pct) (Get-PstLevelColor $pct 80 92) -Bold) +
            (Paint ('  ' + (L '{0} libres sur {1}' (Format-PstSize $d.Free) (Format-PstSize $d.Total))) 'Dim')
    }
    if ($diskLines.Count -eq 0) { $diskLines = @(Paint (L 'Aucun disque fixe détecté') 'Dim') }
    $lines += Format-PstBox -Title (L 'Disques') -Lines $diskLines -Width $width

    # Réseau
    $sparkW = [Math]::Max(10, $inner - 30)
    $netLines = @(
        ((Paint ("$($g.Down) " + (Format-PstPad (L 'Reçu') 6)) 'Accent') + (Format-PstPad ("$(Format-PstSize $Snap.Rx)/s") 14 -Right) + '  ' + (Paint (Format-PstSparkline $state.RxHist.ToArray() -Width $sparkW) 'Accent')),
        ((Paint ("$($g.Up) " + (Format-PstPad (L 'Envoyé') 6)) 'Accent2') + (Format-PstPad ("$(Format-PstSize $Snap.Tx)/s") 14 -Right) + '  ' + (Paint (Format-PstSparkline $state.TxHist.ToArray() -Width $sparkW) 'Accent2'))
    )
    $lines += Format-PstBox -Title (L 'Réseau') -Lines $netLines -Width $width

    # Processus
    if ($state.Sort -eq 'mem') { $sorted = @($Snap.Procs | Sort-Object { $_.Mem } -Descending | Select-Object -First $Top) }
    else { $sorted = @($Snap.Procs | Sort-Object { $_.Cpu }, { $_.Mem } -Descending | Select-Object -First $Top) }
    $nameW = [Math]::Max(16, $inner - 44)
    $rows = @()
    foreach ($p in $sorted) {
        $rows += , @(
            [string]$p.Id,
            (Limit-PstText $p.Name $nameW),
            (Paint ('{0:N1} %' -f $p.Cpu) (Get-PstLevelColor $p.Cpu 25 60)),
            (Format-PstSize $p.Mem),
            [string]$p.Threads
        )
    }
    $procTitle = L 'Processus ({0}) {1} tri CPU' $Snap.ProcCount $g.Dot
    if ($state.Sort -eq 'mem') { $procTitle = L 'Processus ({0}) {1} tri mémoire' $Snap.ProcCount $g.Dot }
    $procLines = Format-PstTable -Columns @(
        @{ Name = 'PID'; Width = 7; Right = $true }, @{ Name = (L 'Processus'); Width = $nameW },
        @{ Name = 'CPU'; Width = 8; Right = $true }, @{ Name = (L 'Mémoire'); Width = 10; Right = $true },
        @{ Name = 'Threads'; Width = 7; Right = $true }
    ) -Rows $rows
    $lines += Format-PstBox -Title $procTitle -Lines $procLines -Width $width

    $status = L 'Q quitter {0} C tri CPU {0} M tri mémoire {0} P pause {0} +/- intervalle ({1}s)' $g.Dot $state.Interval
    if ($state.Paused) { $status = (Paint (L 'EN PAUSE ') 'Warn' -Bold) + (Paint (L '{0} P reprendre {0} Q quitter' $g.Dot) 'Dim') }
    else { $status = Paint $status 'Dim' }
    $lines += ' ' + $status + (Paint ("  $(Get-Date -Format 'HH:mm:ss')") 'Dim')
    return $lines
}

# ── Boucle principale ────────────────────────────────────────────────────────

$info = Get-StaticInfo
$null = Get-Snapshot   # premier relevé : sert de référence pour les % CPU par processus

if ($Once -or -not (Test-PstInteractive)) {
    Start-Sleep -Milliseconds 800
    $snap = Get-Snapshot
    Add-Sample $state.CpuHist $snap.CpuTotal
    Add-Sample $state.RxHist $snap.Rx
    Add-Sample $state.TxHist $snap.Tx
    $frame = Get-Frame $info $snap
    $frame[0..($frame.Count - 2)] | Write-PstLine
    exit 0
}

Start-PstScreen
try {
    $snap = $null
    while ($true) {
        if (-not $state.Paused -or $null -eq $snap) {
            $snap = Get-Snapshot
            Add-Sample $state.CpuHist $snap.CpuTotal
            Add-Sample $state.RxHist $snap.Rx
            Add-Sample $state.TxHist $snap.Tx
        }
        Write-PstFrame (Get-Frame $info $snap)

        $key = Read-PstKey -TimeoutMs ($state.Interval * 1000)
        if ($null -eq $key) { continue }
        if (Test-PstQuitKey $key) { break }
        switch ($key.Key) {
            'C' { $state.Sort = 'cpu' }
            'M' { $state.Sort = 'mem' }
            'P' { $state.Paused = -not $state.Paused }
        }
        if ($key.KeyChar -eq '+') { $state.Interval = [Math]::Min(60, $state.Interval + 1) }
        elseif ($key.KeyChar -eq '-') { $state.Interval = [Math]::Max(1, $state.Interval - 1) }
    }
}
finally { Stop-PstScreen }
