<#
.SYNOPSIS
    timer — minuteur, chronomètre et Pomodoro dans le terminal.
.DESCRIPTION
    Compte à rebours avec grands chiffres et barre de progression, chronomètre avec
    tours, cycles Pomodoro. Notification Windows et bip à la fin (sous Windows) ;
    ailleurs, un simple message. Aucune connexion réseau, aucun droit administrateur.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Duration,
    [string]$Label,
    [switch]$Stopwatch,
    [switch]$Pomodoro,
    [int]$Rounds = 4,
    [string]$Work = '25m',
    [string]$Break = '5m',
    [string]$LongBreak = '15m',
    [int]$Count = 1,
    [switch]$Quiet,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'timer'
$g = $script:Pst.Glyph

if ($Help -or (Test-PstHelpArg (@($Duration) + @($Rest)))) {
    Show-PstHelp -Name 'timer' -Synopsis (L 'Minuteur, chronomètre et Pomodoro, avec un affichage clair et une alerte à la fin.') `
        -Usage @(
            (L 'timer <durée> [-Label <texte>]      compte à rebours : 25m, 1h30, 90s, 10:00'),
            (L 'timer -Stopwatch                   chronomètre (Espace : tour)'),
            (L 'timer -Pomodoro [options]          cycles travail / pause')
        ) `
        -Options @(
            @('-Label <texte>', (L 'Nom affiché et rappelé dans la notification')),
            @('-Rounds <n>', (L 'Pomodoro : nombre de séances de travail (4 par défaut)')),
            @('-Work <durée>', (L 'Pomodoro : durée d''une séance (25m)')),
            @('-Break <durée>', (L 'Pomodoro : petite pause (5m)')),
            @('-LongBreak <durée>', (L 'Pomodoro : longue pause toutes les 4 séances (15m)')),
            @('-Count <n>', (L 'Chronomètre hors session interactive : nombre de relevés')),
            @('-Quiet', (L 'Ni bip ni notification'))
        ) `
        -Examples @(
            'timer 25m',
            'timer 4m -Label "Thé"',
            'timer 1h30 -Label "Lessive"',
            'timer -Stopwatch',
            'timer -Pomodoro -Rounds 3 -Work 50m -Break 10m'
        ) `
        -Notes @(
            (L 'Touches : Espace pause / reprise (tour pour le chronomètre), S passe l''étape (Pomodoro), Q ou Échap quitte.'),
            (L 'Hors session interactive, la progression s''affiche ligne par ligne.')
        )
    exit 0
}

# ── Durées ───────────────────────────────────────────────────────────────────

function ConvertFrom-TimerDuration {
    # « 25m », « 1h30 », « 90s », « 2m30s », « 10:00 », « 1:30:00 », « 25 » (minutes)  ->  secondes
    param([string]$Value)
    $v = ([string]$Value).Trim().ToLowerInvariant() -replace '\s+', ''
    $seconds = -1
    if ($v -match '^\d+$') { $seconds = 60 * [int]$v }
    elseif ($v -match '^(\d+):(\d{2})$') { $seconds = 60 * [int]$Matches[1] + [int]$Matches[2] }
    elseif ($v -match '^(\d+):(\d{2}):(\d{2})$') { $seconds = 3600 * [int]$Matches[1] + 60 * [int]$Matches[2] + [int]$Matches[3] }
    elseif ($v -match '^(\d+)h(\d{1,2})$') { $seconds = 3600 * [int]$Matches[1] + 60 * [int]$Matches[2] }
    elseif ($v -match '^(\d+)m(\d{1,2})$') { $seconds = 60 * [int]$Matches[1] + [int]$Matches[2] }
    else {
        $found = [regex]::Matches($v, '(\d+)(h|min|mn|m|sec|s)')
        $length = 0; $total = 0
        foreach ($m in $found) {
            $n = [int]$m.Groups[1].Value
            $length += $m.Length
            switch ($m.Groups[2].Value) {
                'h' { $total += 3600 * $n }
                { $_ -in 'min', 'mn', 'm' } { $total += 60 * $n }
                default { $total += $n }
            }
        }
        if ($found.Count -gt 0 -and $length -eq $v.Length) { $seconds = $total }
    }
    if ($seconds -le 0 -or $seconds -gt 100 * 3600) {
        throw (L 'Durée non reconnue : « {0} » (exemples : 25m, 1h30, 90s, 10:00)' $Value)
    }
    return $seconds
}

function Format-Clock {
    # 75 -> « 01:15 » ; 3725 -> « 1:02:05 » ; -Tenths ajoute les dixièmes.
    param([double]$Seconds, [switch]$Tenths)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $whole = [int][Math]::Floor($Seconds)
    $h = [int][Math]::Floor($whole / 3600); $m = [int][Math]::Floor(($whole % 3600) / 60); $s = $whole % 60
    if ($h -gt 0) { $text = '{0}:{1:00}:{2:00}' -f $h, $m, $s } else { $text = '{0:00}:{1:00}' -f $m, $s }
    if ($Tenths) { $text += '.' + [int][Math]::Floor(($Seconds - $whole) * 10) }
    return $text
}

# ── Grands chiffres ──────────────────────────────────────────────────────────

$script:Font = @{
    '0' = @('###', '# #', '# #', '# #', '###'); '1' = @('  #', '  #', '  #', '  #', '  #')
    '2' = @('###', '  #', '###', '#  ', '###'); '3' = @('###', '  #', '###', '  #', '###')
    '4' = @('# #', '# #', '###', '  #', '  #'); '5' = @('###', '#  ', '###', '  #', '###')
    '6' = @('###', '#  ', '###', '# #', '###'); '7' = @('###', '  #', '  #', '  #', '  #')
    '8' = @('###', '# #', '###', '# #', '###'); '9' = @('###', '# #', '###', '  #', '###')
    ':' = @(' ', '#', ' ', '#', ' '); '.' = @(' ', ' ', ' ', ' ', '#')
}

function Get-BigText {
    # Texte en chiffres de 5 lignes ; -Scale 2 double la largeur des traits.
    param([string]$Text, [int]$Scale = 2)
    $rows = @('', '', '', '', '')
    foreach ($ch in $Text.ToCharArray()) {
        $glyph = $script:Font[[string]$ch]
        if (-not $glyph) { continue }
        for ($r = 0; $r -lt 5; $r++) {
            $cells = ''
            foreach ($c in $glyph[$r].ToCharArray()) {
                if ($c -eq '#') { $cells += $g.Full * $Scale } else { $cells += ' ' * $Scale }
            }
            $rows[$r] += $cells + (' ' * $Scale)
        }
    }
    return @($rows | ForEach-Object { $_.TrimEnd() })
}

function Get-CenteredBig {
    param([string]$Text, [int]$Width, $Color = 'Accent')
    $scale = 2
    $big = @(Get-BigText $Text 2)
    if (($big | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum -gt $Width - 4) { $big = @(Get-BigText $Text 1); $scale = 1 }
    $span = ($big | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    $pad = ' ' * [Math]::Max(2, [int](($Width - $span) / 2))
    return @($big | ForEach-Object { $pad + (Paint $_ $Color -Bold) })
}

function Get-Centered {
    param([string]$Text, [int]$Width)
    $pad = [Math]::Max(2, [int](($Width - (Get-PstVisibleLength $Text)) / 2))
    return (' ' * $pad) + $Text
}

# ── Alertes ──────────────────────────────────────────────────────────────────

function Show-TimerToast {
    param([string]$Title, [string]$Message)
    $safeTitle = [Security.SecurityElement]::Escape($Title)
    $safeMessage = [Security.SecurityElement]::Escape($Message)
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml(@"
<toast>
  <visual><binding template="ToastGeneric"><text>$safeTitle</text><text>$safeMessage</text></binding></visual>
  <audio src="ms-winsoundevent:Notification.Looping.Alarm" />
</toast>
"@)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        return $true
    }
    catch { return $false }
}

function Send-TimerAlert {
    # Notification Windows + bip ; ailleurs rien de plus que le message affiché.
    param([string]$Title, [string]$Message)
    if ($Quiet) { return }
    if ($script:Pst.IsWindows) {
        $null = Show-TimerToast -Title $Title -Message $Message
        try { [Console]::Beep(880, 200); [Console]::Beep(1175, 300) } catch { $null = $_ }
    }
    elseif (Test-PstInteractive) {
        try { [Console]::Beep() } catch { $null = $_ }
    }
}

# ── Compte à rebours ─────────────────────────────────────────────────────────

function Get-CountdownFrame {
    param([string]$Title, [string]$Subtitle, [double]$Total, [double]$Remain, [bool]$Paused, [string]$Phase, [switch]$CanSkip)
    $width = Get-PstWidth
    $pct = 0
    if ($Total -gt 0) { $pct = 100 * ($Total - $Remain) / $Total }
    $color = 'Accent'
    if ($Paused) { $color = 'Warn' } elseif ($Remain -le 10) { $color = 'Ok' }
    $lines = @('', (' ' + (Get-PstHeaderLine -Tool 'timer' -Subtitle $Subtitle -Width ($width - 1))), '', '')
    $lines += Get-Centered (Paint $Title 'Title' -Bold) $width
    if ($Phase) { $lines += Get-Centered $Phase $width }
    $lines += ''
    $lines += Get-CenteredBig (Format-Clock ([Math]::Ceiling($Remain))) $width $color
    $lines += ''
    $barWidth = [Math]::Max(20, [Math]::Min(60, $width - 16))
    $lines += Get-Centered ((Format-PstBar $pct -Width $barWidth -Color $color) + '  ' + (Paint ('{0,3:N0} %' -f $pct) 'Dim')) $width
    if ($Paused) { $state = Paint (L 'En pause') 'Warn' -Bold }
    else { $state = Paint (L 'Fin prévue à {0}' ((Get-Date).AddSeconds($Remain).ToString('HH:mm'))) 'Dim' }
    $lines += Get-Centered $state $width
    $lines += ''
    $keys = @(, @((L 'Espace'), (L 'pause')))
    if ($CanSkip) { $keys += , @('S', (L 'passer')) }
    $keys += , @('Q', (L 'quitter'))
    $lines += ' ' + (Format-PstKeyBar $keys -Bar -Width ($width - 2))
    return $lines
}

function Invoke-Countdown {
    # Retourne 'done', 'skip' ou 'quit'.
    param([int]$Seconds, [string]$Title, [string]$Subtitle, [string]$Phase = '', [switch]$Live, [switch]$CanSkip)
    if (-not $Live) {
        # Mode non interactif : quelques lignes de progression, puis fin.
        if ($Seconds -le 10) { $step = 1 } elseif ($Seconds -le 120) { $step = 10 } elseif ($Seconds -le 1800) { $step = 60 } else { $step = 300 }
        $start = Get-Date
        $line = $Title
        if ($Phase) { $line += "  $($g.Dot)  $Phase" }
        Write-PstStatus step ((Paint $line 'Title' -Bold) + (Paint ('  ' + (L '{0} · fin prévue à {1}' (Format-PstDuration ([TimeSpan]::FromSeconds($Seconds))) $start.AddSeconds($Seconds).ToString('HH:mm:ss'))) 'Dim'))
        $next = $step
        while ($true) {
            $elapsed = ((Get-Date) - $start).TotalSeconds
            if ($elapsed -ge $Seconds) { break }
            $wait = [Math]::Min($next, $Seconds) - $elapsed
            if ($wait -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($wait * 1000)) }
            $elapsed = [Math]::Min($Seconds, ((Get-Date) - $start).TotalSeconds)
            $remain = [Math]::Max(0, $Seconds - $elapsed)
            $pct = 100 * $elapsed / $Seconds
            Write-Host ('    ' + (Paint (Format-Clock ([Math]::Round($remain))) 'Accent' -Bold) + '  ' + (Format-PstBar $pct -Width 24 -Color 'Accent') + (Paint ('  {0,3:N0} %' -f $pct) 'Dim'))
            $next += $step
        }
        return 'done'
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = -1; $dirty = $true
    while ($true) {
        $remain = [Math]::Max(0, $Seconds - $sw.Elapsed.TotalSeconds)
        $shown = [int][Math]::Ceiling($remain)
        if ($shown -ne $last -or $dirty) {
            Write-PstFrame (Get-CountdownFrame -Title $Title -Subtitle $Subtitle -Total $Seconds -Remain $remain -Paused (-not $sw.IsRunning) -Phase $Phase -CanSkip:$CanSkip)
            $last = $shown; $dirty = $false
        }
        if ($remain -le 0) { return 'done' }
        $key = Read-PstKey -TimeoutMs 100
        if ($null -eq $key) { continue }
        if (Test-PstQuitKey $key) { return 'quit' }
        if ($key.Key -eq 'Spacebar' -or $key.Key -eq 'P') {
            if ($sw.IsRunning) { $sw.Stop() } else { $sw.Start() }
            $dirty = $true
        }
        elseif ($CanSkip -and $key.Key -eq 'S') { return 'skip' }
    }
}

function Start-Countdown {
    param([string]$Value)
    try { $seconds = ConvertFrom-TimerDuration $Value }
    catch { Write-PstStatus err $_.Exception.Message; return 1 }
    $title = $Label
    if (-not $title) { $title = L 'Minuteur' }
    $live = Test-PstInteractive
    $length = Format-PstDuration ([TimeSpan]::FromSeconds($seconds))
    if ($live) {
        Start-PstScreen
        try { $result = Invoke-Countdown -Seconds $seconds -Title $title -Subtitle $length -Live }
        finally { Stop-PstScreen }
    }
    else {
        Show-PstHeader -Tool 'timer' -Subtitle $length
        $result = Invoke-Countdown -Seconds $seconds -Title $title -Subtitle $length
    }
    if ($result -eq 'quit') {
        Write-PstStatus warn (L 'Minuteur arrêté avant la fin : {0}' $title)
        Write-Host ''
        return 1
    }
    Write-PstStatus ok (L 'Temps écoulé : {0} ({1})' (Paint $title 'Title' -Bold) $length)
    Write-Host ''
    Send-TimerAlert -Title (L 'Temps écoulé') -Message (L '{0} · {1}' $title $length)
    return 0
}

# ── Pomodoro ─────────────────────────────────────────────────────────────────

function Start-Pomodoro {
    try {
        $workSec = ConvertFrom-TimerDuration $Work
        $breakSec = ConvertFrom-TimerDuration $Break
        $longSec = ConvertFrom-TimerDuration $LongBreak
    }
    catch { Write-PstStatus err $_.Exception.Message; return 1 }
    if ($Rounds -lt 1 -or $Rounds -gt 24) { Write-PstStatus err (L 'Nombre de séances invalide : {0} (de 1 à 24).' $Rounds); return 1 }

    # Séances de travail entrecoupées de pauses ; longue pause après chaque 4e séance.
    $phases = @()
    for ($r = 1; $r -le $Rounds; $r++) {
        $phases += @{ Kind = 'work'; Round = $r; Seconds = $workSec }
        if ($r -lt $Rounds) {
            if ($r % 4 -eq 0) { $phases += @{ Kind = 'long'; Round = $r; Seconds = $longSec } }
            else { $phases += @{ Kind = 'break'; Round = $r; Seconds = $breakSec } }
        }
    }
    $live = Test-PstInteractive
    $subtitle = L 'Pomodoro · {0} séance(s)' $Rounds
    $completed = 0
    $result = 'done'
    if ($live) { Start-PstScreen } else { Show-PstHeader -Tool 'timer' -Subtitle $subtitle }
    try {
        foreach ($p in $phases) {
            switch ($p.Kind) {
                'work' { $title = L 'Travail' }
                'long' { $title = L 'Longue pause' }
                default { $title = L 'Petite pause' }
            }
            if ($Label -and $p.Kind -eq 'work') { $title = L 'Travail : {0}' $Label }
            $dots = ''
            for ($i = 1; $i -le $Rounds; $i++) {
                if ($i -lt $p.Round -or ($i -eq $p.Round -and $p.Kind -ne 'work')) { $dots += $g.Bullet } else { $dots += $g.Hollow }
                if ($i -lt $Rounds) { $dots += ' ' }
            }
            $phase = (Paint $dots 'Accent2') + '  ' + (Paint (L 'séance {0}/{1}' $p.Round $Rounds) 'Dim')
            if (-not $live) { $phase = L 'séance {0}/{1}' $p.Round $Rounds }
            $result = Invoke-Countdown -Seconds $p.Seconds -Title $title -Subtitle $subtitle -Phase $phase -Live:$live -CanSkip
            if ($result -eq 'quit') { break }
            if ($p.Kind -eq 'work') { $completed++ }
            if ($result -eq 'done') {
                if ($p.Kind -eq 'work') { Send-TimerAlert -Title (L 'Séance terminée') -Message (L 'Séance {0}/{1} terminée. Place à la pause.' $p.Round $Rounds) }
                else { Send-TimerAlert -Title (L 'Fin de la pause') -Message (L 'On reprend : séance {0}/{1}.' ($p.Round + 1) $Rounds) }
            }
        }
    }
    finally { if ($live) { Stop-PstScreen } }

    if ($result -eq 'quit') {
        Write-PstStatus warn (L 'Pomodoro interrompu : {0} séance(s) sur {1} terminée(s).' $completed $Rounds)
        Write-Host ''
        return 1
    }
    Write-PstStatus ok (L 'Cycle terminé : {0} séance(s) de travail, {1} au total.' $completed (Format-PstDuration ([TimeSpan]::FromSeconds($workSec * $completed))))
    Write-PstStatus info (L 'Vous avez mérité une longue pause ({0}).' (Format-PstDuration ([TimeSpan]::FromSeconds($longSec))))
    Write-Host ''
    return 0
}

# ── Chronomètre ──────────────────────────────────────────────────────────────

function Show-Laps {
    param($Laps, [double]$Total)
    if (@($Laps).Count) {
        $rows = @()
        $prev = 0
        $i = 1
        foreach ($t in $Laps) {
            $rows += , @([string]$i, (Format-Clock ($t - $prev) -Tenths), (Format-Clock $t -Tenths))
            $prev = $t; $i++
        }
        Format-PstTable -Columns @(@{ Name = (L 'Tour'); Width = 4; Right = $true }, @{ Name = (L 'Durée'); Width = 10; Right = $true }, @{ Name = (L 'Cumul'); Width = 10; Right = $true }) -Rows $rows |
            ForEach-Object { Write-Host "  $_" }
        Write-Host ''
    }
    Write-PstStatus ok (L 'Temps total : {0}' (Paint (Format-Clock $Total -Tenths) 'Title' -Bold))
    Write-Host ''
}

function Start-Stopwatch {
    $title = $Label
    if (-not $title) { $title = L 'Chronomètre' }
    $laps = New-Object System.Collections.ArrayList
    $sw = [Diagnostics.Stopwatch]::StartNew()

    if (-not (Test-PstInteractive)) {
        Show-PstHeader -Tool 'timer' -Subtitle (L 'chronomètre')
        Write-PstStatus step (Paint $title 'Title' -Bold)
        $n = [Math]::Max(1, $Count)
        for ($i = 1; $i -le $n; $i++) {
            if ($i -gt 1) { Start-Sleep -Seconds 1 }
            Write-Host ('    ' + (Paint (Format-Clock $sw.Elapsed.TotalSeconds -Tenths) 'Accent' -Bold))
        }
        $sw.Stop()
        Write-Host ''
        Show-Laps @() $sw.Elapsed.TotalSeconds
        return 0
    }

    Start-PstScreen
    try {
        $last = ''
        while ($true) {
            $elapsed = $sw.Elapsed.TotalSeconds
            $clock = Format-Clock $elapsed -Tenths
            if ($clock -ne $last) {
                $width = Get-PstWidth
                $color = 'Accent'
                if (-not $sw.IsRunning) { $color = 'Warn' }
                $lines = @('', (' ' + (Get-PstHeaderLine -Tool 'timer' -Subtitle (L 'chronomètre') -Width ($width - 1))), '', '')
                $lines += Get-Centered (Paint $title 'Title' -Bold) $width
                $lines += ''
                $lines += Get-CenteredBig $clock $width $color
                $lines += ''
                if (-not $sw.IsRunning) { $lines += Get-Centered (Paint (L 'En pause') 'Warn' -Bold) $width }
                else { $lines += Get-Centered (Paint (L '{0} tour(s)' $laps.Count) 'Dim') $width }
                $prev = 0
                $recent = @()
                for ($i = 0; $i -lt $laps.Count; $i++) {
                    $recent += (Paint ('{0,3}' -f ($i + 1)) 'Dim') + '   ' + (Format-Clock ($laps[$i] - $prev) -Tenths) + '   ' + (Paint (Format-Clock $laps[$i] -Tenths) 'Dim')
                    $prev = $laps[$i]
                }
                $lines += ''
                foreach ($r in @($recent | Select-Object -Last 5)) { $lines += Get-Centered $r $width }
                $lines += ''
                $lines += ' ' + (Format-PstKeyBar @(@((L 'Espace'), (L 'tour')), @('P', (L 'pause')), @('Q', (L 'terminer'))) -Bar -Width ($width - 2))
                Write-PstFrame $lines
                $last = $clock
            }
            $key = Read-PstKey -TimeoutMs 50
            if ($null -eq $key) { continue }
            if (Test-PstQuitKey $key) { break }
            if ($key.Key -eq 'Spacebar' -or $key.Key -eq 'L' -or $key.Key -eq 'Enter') {
                if ($sw.IsRunning) { [void]$laps.Add($sw.Elapsed.TotalSeconds) }
                $last = ''
            }
            elseif ($key.Key -eq 'P') {
                if ($sw.IsRunning) { $sw.Stop() } else { $sw.Start() }
                $last = ''
            }
        }
    }
    finally { Stop-PstScreen }
    $sw.Stop()
    Write-Host ''
    Show-PstHeader -Tool 'timer' -Subtitle (L 'chronomètre')
    Show-Laps @($laps) $sw.Elapsed.TotalSeconds
    return 0
}

# ── Point d'entrée ───────────────────────────────────────────────────────────

if ($Stopwatch) { exit (Start-Stopwatch) }
if ($Pomodoro) { exit (Start-Pomodoro) }
$value = (@(@($Duration) + @($Rest) | Where-Object { $_ }) -join '')
if (-not $value) {
    Write-PstStatus err (L 'Précisez une durée (25m, 1h30, 90s), ou -Stopwatch, ou -Pomodoro. Voir « timer -Help ».')
    exit 1
}
exit (Start-Countdown $value)
