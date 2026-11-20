<#
.SYNOPSIS
    awake — empêche le PC (et, au choix, l'écran) de se mettre en veille.
.DESCRIPTION
    Utilise l'API Windows SetThreadExecutionState pendant la durée demandée,
    puis rétablit toujours le comportement normal en sortant (Q, Ctrl+C, fin du
    délai). Aucun réglage d'alimentation n'est modifié ; aucun droit
    administrateur n'est nécessaire. Windows uniquement.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Duration,
    [string]$Until,
    [switch]$Display,
    [switch]$Once,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'awake'

if ($Help -or (Test-PstHelpArg (@($Duration) + @($Rest)))) {
    Show-PstHelp -Name 'awake' -Synopsis (L 'Garde le PC éveillé (et l''écran allumé si besoin), puis rétablit la veille.') `
        -Usage @(
            (L 'awake                       jusqu''à l''appui sur Q'),
            (L 'awake <durée>               ex. : 45m, 2h, 1h30, 90s'),
            (L 'awake -Until <heure>        ex. : 18:30 (demain si l''heure est passée)'),
            (L 'awake ... -Display          garde aussi l''écran allumé')
        ) `
        -Options @(
            @((L 'durée'), (L 'Durée : 30s, 15m, 2h, 1h30, 1j (un nombre seul = minutes)')),
            @((L '-Until <heure>'), (L 'Heure de fin, ex. : 18:30 ou 18h30')),
            @('-Display', (L 'Empêche aussi l''extinction de l''écran')),
            @('-Once', (L 'Affiche un seul écran puis quitte (scripts)'))
        ) `
        -Examples @('awake', 'awake 2h', 'awake -Until 18:30', 'awake 45m -Display') `
        -Notes @(
            (L 'Touches : Q quitter, D écran allumé oui/non.'),
            (L 'La veille normale est rétablie dès la sortie, même après Ctrl+C.'),
            (L 'Windows uniquement : aucun réglage d''alimentation n''est modifié.')
        )
    exit 0
}

# ── Durées et heures ─────────────────────────────────────────────────────────

function ConvertFrom-AwakeDuration {
    # « 2h », « 1h30 », « 45m », « 90s », « 1j »/« 1d », « 1h 15m » ; un nombre seul = minutes.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim().ToLowerInvariant() -replace ',', '.'
    if ($t -match '^\d+(\.\d+)?$') { return [TimeSpan]::FromMinutes([double]$t) }
    $total = 0.0
    $pos = 0
    $lastUnit = ''
    foreach ($m in [regex]::Matches($t, '\s*(\d+(?:\.\d+)?)\s*(j|d|h|min|mn|m|s)?')) {
        if ($m.Index -ne $pos -or $m.Length -eq 0) { return $null }
        $pos = $m.Index + $m.Length
        $n = [double]$m.Groups[1].Value
        $unit = $m.Groups[2].Value
        if (-not $unit) {
            # « 1h30 » : le nombre qui suit les heures compte en minutes, après les minutes en secondes.
            if ($lastUnit -eq 'h') { $unit = 'm' } elseif ($lastUnit -in 'm', 'min', 'mn') { $unit = 's' } else { return $null }
        }
        switch ($unit) {
            { $_ -in 'j', 'd' } { $total += $n * 86400 }
            'h' { $total += $n * 3600 }
            { $_ -in 'm', 'min', 'mn' } { $total += $n * 60 }
            's' { $total += $n }
        }
        $lastUnit = $unit
    }
    if ($pos -ne $t.Length -or $total -le 0) { return $null }
    return [TimeSpan]::FromSeconds($total)
}

function ConvertFrom-AwakeTime {
    # « 18:30 », « 18h30 », « 18h », « 9:05 » : aujourd'hui, ou demain si l'heure est passée.
    param([string]$Text, [DateTime]$Now = (Get-Date))
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim().ToLowerInvariant()
    $tomorrow = $false
    if ($t -match '^(demain|tomorrow)\s+(.+)$') { $tomorrow = $true; $t = $Matches[2] }
    if ($t -notmatch '^(\d{1,2})\s*(?:[:h]\s*(\d{2})?)?$') { return $null }
    $h = [int]$Matches[1]
    $mi = 0
    if ($Matches[2]) { $mi = [int]$Matches[2] }
    if ($h -gt 23 -or $mi -gt 59) { return $null }
    $target = $Now.Date.AddHours($h).AddMinutes($mi)
    if ($tomorrow -or $target -le $Now) { $target = $target.AddDays(1) }
    return $target
}

function Format-AwakeClock {
    # Compte à rebours « 01:59:32 » (ou « 1j 02:00:00 ») ; -Up arrondit à la seconde supérieure.
    param([TimeSpan]$Span, [switch]$Up)
    if ($Span.TotalSeconds -lt 0) { $Span = [TimeSpan]::Zero }
    if ($Up) { $Span = [TimeSpan]::FromSeconds([Math]::Ceiling($Span.TotalSeconds)) }
    $text = '{0:00}:{1:00}:{2:00}' -f $Span.Hours, $Span.Minutes, $Span.Seconds
    if ($Span.Days -gt 0) { $text = (L '{0}j' $Span.Days) + ' ' + $text }
    return $text
}

# ── État d'exécution (API Windows) ───────────────────────────────────────────

$script:RealWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or [bool]$IsWindows
$script:Simulated = $script:Pst.IsWindows -and -not $script:RealWindows   # tests : rendu sans appel natif
$ES_CONTINUOUS = [uint32]2147483648
$ES_SYSTEM_REQUIRED = [uint32]1
$ES_DISPLAY_REQUIRED = [uint32]2

function Set-AwakeState {
    # Demande à Windows de ne pas mettre en veille ; $false (ou rien) rétablit le comportement normal.
    param([bool]$Keep, [bool]$Screen)
    $flags = $ES_CONTINUOUS
    if ($Keep) { $flags = $flags -bor $ES_SYSTEM_REQUIRED }
    if ($Keep -and $Screen) { $flags = $flags -bor $ES_DISPLAY_REQUIRED }
    if ($script:Simulated) { return $true }
    if (-not ('PsTools.AwakeNative' -as [type])) {
        Add-Type -Namespace 'PsTools' -Name 'AwakeNative' -MemberDefinition '[DllImport("kernel32.dll", SetLastError = true)] public static extern uint SetThreadExecutionState(uint esFlags);'
    }
    return ([PsTools.AwakeNative]::SetThreadExecutionState($flags) -ne 0)
}

if (-not $script:Pst.IsWindows) {
    Write-PstStatus err (L 'awake nécessite Windows : il s''appuie sur l''API de gestion de la veille de Windows.')
    Write-PstStatus info (L 'Sous Linux, « systemd-inhibit » ou « caffeinate » (macOS) rendent le même service.')
    exit 1
}

# ── Arguments ────────────────────────────────────────────────────────────────

$start = Get-Date
$end = $null
if ($Until) {
    $end = ConvertFrom-AwakeTime $Until $start
    if ($null -eq $end) { Write-PstStatus err (L 'Heure invalide : « {0} » (ex. : 18:30).' $Until); exit 1 }
}
elseif ($Duration) {
    $span = ConvertFrom-AwakeDuration $Duration
    if ($null -eq $span) {
        # « awake 18:30 » : une heure donnée sans -Until.
        $end = ConvertFrom-AwakeTime $Duration $start
        if ($null -eq $end) { Write-PstStatus err (L 'Durée invalide : « {0} » (ex. : 45m, 2h, 1h30).' $Duration); exit 1 }
    }
    else { $end = $start + $span }
}
if ($Rest.Count) { Write-PstStatus err (L 'Argument inattendu : {0}' ($Rest -join ' ')); exit 1 }

$state = @{ Screen = [bool]$Display }

function Get-AwakeFrame {
    param([DateTime]$Now)
    $g = $script:Pst.Glyph
    $width = Get-PstWidth -Max 72
    $lines = @('', (' ' + (Get-PstHeaderLine -Tool 'awake' -Subtitle (L 'anti-veille') -Width ($width - 1))), '')
    $elapsed = $Now - $start
    $body = @('')
    if ($end) {
        $left = $end - $Now
        $body += '  ' + (Paint (Format-AwakeClock $left -Up) 'Title' -Bold) + (Paint ('  ' + (L 'restant')) 'Dim')
        $total = ($end - $start).TotalSeconds
        $pct = 100.0
        if ($total -gt 0) { $pct = [Math]::Min(100, $elapsed.TotalSeconds / $total * 100) }
        $body += '  ' + (Format-PstBar $pct ($width - 16) -Color 'Accent') + (Paint ('  {0,3:N0} %' -f $pct) 'Dim')
        $body += ''
        $body += '  ' + (Paint (Format-PstPad (L 'Fin prévue') 16) 'Dim') + $end.ToString((L 'dddd d MMMM à HH:mm'), (Get-PstCulture))
    }
    else {
        $body += '  ' + (Paint (Format-AwakeClock $elapsed) 'Title' -Bold) + (Paint ('  ' + (L 'écoulé')) 'Dim')
        $body += ''
        $body += '  ' + (Paint (Format-PstPad (L 'Fin prévue') 16) 'Dim') + (L 'à l''appui sur Q')
    }
    $mode = Paint (L 'PC éveillé, écran libre de s''éteindre') 'Accent'
    if ($state.Screen) { $mode = Paint (L 'PC éveillé et écran allumé') 'Accent2' }
    $body += '  ' + (Paint (Format-PstPad (L 'Mode') 16) 'Dim') + $mode
    $body += '  ' + (Paint (Format-PstPad (L 'Depuis') 16) 'Dim') + $start.ToString('HH:mm') + (Paint ("  $($g.Dot) " + (Format-PstDuration $elapsed)) 'Dim')
    $body += ''
    $lines += Format-PstBox -Title (L 'Veille suspendue') -Lines $body -Width $width -Color 'Accent'
    $lines += ''
    $lines += ' ' + (Format-PstKeyBar @(@('Q', (L 'quitter')), @('D', (L 'écran allumé oui/non'))) -Bar -Width ($width - 1))
    return $lines
}

# ── Boucle principale ────────────────────────────────────────────────────────

$interactive = (Test-PstInteractive) -and -not $Once
if (-not (Set-AwakeState $true $state.Screen)) {
    Write-PstStatus err (L 'Windows a refusé la demande de maintien en éveil.')
    exit 1
}
$screen = $false
try {
    if (-not $interactive) {
        $frame = Get-AwakeFrame (Get-Date)
        $frame[0..($frame.Count - 2)] | Write-PstLine
        if ($end -and -not $Once) {
            # Session non interactive (script, tâche planifiée) : on attend la fin du délai.
            while ((Get-Date) -lt $end) { Start-Sleep -Milliseconds ([int][Math]::Min(1000, [Math]::Max(50, ($end - (Get-Date)).TotalMilliseconds))) }
            Write-PstStatus ok (L 'Délai écoulé.')
        }
        elseif (-not $Once) {
            Write-PstStatus warn (L 'Session non interactive : indiquez une durée (ex. : awake 30m).')
        }
    }
    else {
        Start-PstScreen
        $screen = $true
        while ($true) {
            $now = Get-Date
            if ($end -and $now -ge $end) { break }
            Write-PstFrame (Get-AwakeFrame $now)
            $wait = 1000
            if ($end) { $wait = [int][Math]::Max(50, [Math]::Min(1000, ($end - $now).TotalMilliseconds)) }
            $key = Read-PstKey -TimeoutMs $wait
            if ($null -eq $key) { continue }
            if (Test-PstQuitKey $key) { break }
            if ($key.Key -eq 'D') {
                $state.Screen = -not $state.Screen
                $null = Set-AwakeState $true $state.Screen
            }
        }
    }
}
finally {
    if ($screen) { Stop-PstScreen }
    $null = Set-AwakeState $false $false
}

Write-PstStatus ok (L 'Veille normale rétablie après {0}.' (Format-PstDuration ((Get-Date) - $start)))
Write-Host ''
exit 0
