<#
.SYNOPSIS
    remind — rappels avec notification Windows, en ligne de commande ou par menu.
.DESCRIPTION
    Les rappels sont planifiés dans le Planificateur de tâches au nom de
    l'utilisateur courant : aucun droit administrateur n'est nécessaire.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1)][string]$Text,
    [string]$In,
    [string]$At,
    [switch]$All,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')

if ($Help -or (Test-PstHelpArg (@($Command, $Text) + @($Rest)))) {
    Show-PstHelp -Name 'remind' -Synopsis 'Crée des rappels et vous notifie au bon moment.' `
        -Usage @(
            'remind                                 menu interactif',
            'remind add "<texte>" -In <durée>       dans 15m, 2h, 1j, 1h30...',
            'remind add "<texte>" -At <moment>      18:30, demain 9:00, 25/12/2026 09:00',
            'remind list [-All]                     rappels à venir (ou tout l''historique)',
            'remind done <n> | rm <n> | clear       terminer, supprimer, purger les terminés'
        ) `
        -Examples @(
            'remind add "Sortir le gâteau du four" -In 25m',
            'remind add "Réunion d''équipe" -At "demain 9:30"',
            'remind list'
        ) `
        -Notes @('Les notifications s''affichent même si le terminal est fermé.')
    exit 0
}

# ── Stockage ─────────────────────────────────────────────────────────────────

$store = Join-Path (Get-PstDataDir) 'reminders.json'
$dateFormat = 'yyyy-MM-dd HH:mm'
$taskPrefix = 'PsTools_Reminder_'
if ($env:PSTOOLS_TASK_PREFIX) { $taskPrefix = $env:PSTOOLS_TASK_PREFIX }   # isole les tâches d'une instance de test

function ConvertTo-Due {
    param($Value)
    if ($Value -is [DateTime]) { return $Value }
    return [DateTime]::ParseExact([string]$Value, $dateFormat, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-Reminders {
    $list = @()
    if (Test-Path -LiteralPath $store) {
        try {
            $raw = Get-Content -LiteralPath $store -Raw -Encoding UTF8
            if ($raw -and $raw.Trim()) {
                # ForEach-Object aplatit le résultat : selon la version, « [] » revient vide ou comme un tableau imbriqué.
                foreach ($r in @($raw | ConvertFrom-Json | ForEach-Object { $_ })) {
                    if ($null -eq $r -or -not $r.Id) { continue }
                    $list += @{ Id = [string]$r.Id; Title = [string]$r.Title; Due = (ConvertTo-Due $r.Due); Done = [bool]$r.Done; Notified = [bool]$r.Notified }
                }
            }
        }
        catch { Write-PstStatus warn "Fichier de rappels illisible ($store) : $($_.Exception.Message)" }
    }
    return @($list | Sort-Object { $_.Due })
}

function Save-Reminders {
    param($List)
    $data = @(@($List) | Where-Object { $_ } | ForEach-Object {
            [ordered]@{ Id = $_.Id; Title = $_.Title; Due = $_.Due.ToString($dateFormat); Done = $_.Done; Notified = $_.Notified }
        })
    $json = ConvertTo-Json -InputObject $data -Depth 4
    [IO.File]::WriteAllText($store, $json, (New-Object Text.UTF8Encoding $false))
}

function Import-LegacyReminders {
    # Reprend les rappels de la version 1 (%LOCALAPPDATA%\RemindSystem).
    if (-not $env:LOCALAPPDATA -or (Test-Path -LiteralPath $store)) { return }
    $old = Join-Path (Join-Path $env:LOCALAPPDATA 'RemindSystem') 'reminders.json'
    if (-not (Test-Path -LiteralPath $old)) { return }
    try {
        $list = @()
        foreach ($r in @(Get-Content -LiteralPath $old -Raw | ConvertFrom-Json | ForEach-Object { $_ })) {
            if ($null -eq $r -or -not $r.Id) { continue }
            $list += @{ Id = [string]$r.Id; Title = [string]$r.Title; Due = [DateTime]$r.DateTime; Done = [bool]$r.Completed; Notified = [bool]$r.Completed }
        }
        Save-Reminders $list
    }
    catch { $null = $_ }
}

# ── Planification et notification ────────────────────────────────────────────

function Register-ReminderTask {
    param($Reminder)
    if (-not $script:Pst.IsWindows) { return $false }
    try {
        $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" fire {1}' -f $PSCommandPath, $Reminder.Id
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -Once -At $Reminder.Due
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName ($taskPrefix + $Reminder.Id) -Action $action -Trigger $trigger -Settings $settings `
            -Description "ps-tools : $($Reminder.Title)" -Force -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        Write-PstStatus warn "Planification impossible : $($_.Exception.Message)"
        Write-PstStatus info 'Le rappel est enregistré ; il sera signalé au prochain lancement de « remind ».'
        return $false
    }
}

function Unregister-ReminderTask {
    param([string]$Id)
    if (-not $script:Pst.IsWindows) { return }
    try { Unregister-ScheduledTask -TaskName ($taskPrefix + $Id) -Confirm:$false -ErrorAction Stop } catch { $null = $_ }
}

function Show-Toast {
    param([string]$Title, [string]$Message)
    $safeTitle = [Security.SecurityElement]::Escape($Title)
    $safeMessage = [Security.SecurityElement]::Escape($Message)
    try {
        # Notification moderne (centre de notifications Windows 10/11)
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml(@"
<toast scenario="reminder">
  <visual><binding template="ToastGeneric"><text>$safeTitle</text><text>$safeMessage</text></binding></visual>
  <actions><action activationType="system" arguments="dismiss" content=""/></actions>
  <audio src="ms-winsoundevent:Notification.Reminder"/>
</toast>
"@)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        return
    }
    catch { $null = $_ }
    try {
        # Repli : boîte de dialogue classique
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', 'Information')
    }
    catch { Write-Host "$Title : $Message" }
}

# ── Analyse des dates ────────────────────────────────────────────────────────

function ConvertFrom-Delay {
    # « 15m », « 2h », « 1j », « 1h30 », « 90s », « 1j 2h »  ->  TimeSpan
    param([string]$Value)
    $v = $Value.Trim().ToLower() -replace '\s+', ''
    if ($v -match '^\d+$') { return [TimeSpan]::FromMinutes([int]$v) }
    if ($v -match '^(\d+)h(\d{1,2})$') { return (New-Object TimeSpan ([int]$Matches[1]), ([int]$Matches[2]), 0) }
    $total = [TimeSpan]::Zero
    $found = [regex]::Matches($v, '(\d+)(j|d|h|min|m|s)')
    $length = 0
    foreach ($m in $found) {
        $n = [int]$m.Groups[1].Value
        $length += $m.Length
        switch ($m.Groups[2].Value) {
            { $_ -eq 'j' -or $_ -eq 'd' } { $total += [TimeSpan]::FromDays($n) }
            'h' { $total += [TimeSpan]::FromHours($n) }
            { $_ -eq 'm' -or $_ -eq 'min' } { $total += [TimeSpan]::FromMinutes($n) }
            's' { $total += [TimeSpan]::FromSeconds($n) }
        }
    }
    if ($found.Count -eq 0 -or $length -ne $v.Length) { throw "Durée non reconnue : « $Value » (exemples : 15m, 2h, 1h30, 1j)" }
    return $total
}

function ConvertFrom-Moment {
    # « 18:30 », « demain 9:00 », « 25/12 09:00 », « 25/12/2026 09:00 », « 2026-12-25 09:00 »
    param([string]$Value, [DateTime]$Now = (Get-Date))
    $v = $Value.Trim().ToLower() -replace 'h(\d{2})', ':$1' -replace '(\d)h\b', '$1:00'
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $day = $null
    if ($v -match '^(demain|tomorrow)\s+(.+)$') { $day = $Now.Date.AddDays(1); $v = $Matches[2] }
    elseif ($v -match "^(aujourd'hui|today)\s+(.+)$") { $day = $Now.Date; $v = $Matches[2] }

    if ($v -match '^(\d{1,2}):(\d{2})$') {
        $h = [int]$Matches[1]; $m = [int]$Matches[2]
        if ($h -gt 23 -or $m -gt 59) { throw "Heure invalide : « $Value »" }
        if ($day) { return $day.AddHours($h).AddMinutes($m) }
        $result = $Now.Date.AddHours($h).AddMinutes($m)
        if ($result -le $Now) { $result = $result.AddDays(1) }   # heure déjà passée : demain
        return $result
    }
    if ($v -match '^(\d{1,2})/(\d{1,2})\s+(\d{1,2}):(\d{2})$') {
        $result = New-Object DateTime $Now.Year, ([int]$Matches[2]), ([int]$Matches[1]), ([int]$Matches[3]), ([int]$Matches[4]), 0
        if ($result -le $Now) { $result = $result.AddYears(1) }
        return $result
    }
    $parsed = [DateTime]::MinValue
    foreach ($f in @('d/M/yyyy H:mm', 'yyyy-M-d H:mm', 'd/M/yyyy', 'yyyy-M-d')) {
        if ([DateTime]::TryParseExact($v, $f, $inv, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            if ($f -notmatch 'H') { $parsed = $parsed.AddHours(9) }   # date seule : 9h
            return $parsed
        }
    }
    throw "Moment non reconnu : « $Value » (exemples : 18:30, demain 9:00, 25/12/2026 09:00)"
}

# Rappel : une fonction qui retourne un seul élément le « déballe » ; les appelants
# enveloppent donc toujours ces listes dans @( ).

# ── Commandes ────────────────────────────────────────────────────────────────

function Add-Reminder {
    param([string]$Title, [string]$Delay, [string]$Moment)
    if ([string]::IsNullOrWhiteSpace($Title)) { Write-PstStatus err 'Le texte du rappel est vide.'; return $false }
    try {
        if ($Delay) { $due = (Get-Date).Add((ConvertFrom-Delay $Delay)) }
        elseif ($Moment) { $due = ConvertFrom-Moment $Moment }
        else { Write-PstStatus err 'Précisez -In <durée> ou -At <moment>.'; return $false }
    }
    catch { Write-PstStatus err $_.Exception.Message; return $false }
    if ($due -le (Get-Date)) { Write-PstStatus err 'Ce moment est déjà passé.'; return $false }

    # Échéance arrondie à la seconde entière.
    $due = $due.AddTicks( - ($due.Ticks % [TimeSpan]::TicksPerSecond))
    $reminder = @{ Id = [Guid]::NewGuid().ToString('N').Substring(0, 12); Title = $Title.Trim(); Due = $due; Done = $false; Notified = $false }
    $list = @(Get-Reminders) + $reminder
    Save-Reminders $list
    $null = Register-ReminderTask $reminder

    Write-PstStatus ok ("Rappel enregistré : " + (Paint $reminder.Title 'Title' -Bold))
    Write-PstStatus info ("{0}  (dans {1})" -f $due.ToString('dddd d MMMM yyyy à HH:mm'), (Format-PstDuration ($due - (Get-Date))))
    return $true
}

function Get-VisibleReminders {
    param([switch]$IncludeDone)
    $list = @(Get-Reminders)
    if ($IncludeDone) { return @($list) }
    return @($list | Where-Object { -not $_.Done })
}

function Show-ReminderList {
    param([switch]$IncludeDone)
    $g = $script:Pst.Glyph
    $items = @(Get-VisibleReminders -IncludeDone:$IncludeDone)
    if ($items.Count -eq 0) { Write-PstStatus info 'Aucun rappel en attente.'; return }
    $now = Get-Date
    $rows = @()
    $i = 1
    foreach ($r in $items) {
        if ($r.Done) { $when = Paint 'terminé' 'Dim'; $mark = Paint $g.Ok 'Dim' }
        elseif ($r.Due -le $now) { $when = Paint ("en retard de " + (Format-PstDuration ($now - $r.Due))) 'Err'; $mark = Paint $g.Warn 'Err' -Bold }
        else { $when = Paint ("dans " + (Format-PstDuration ($r.Due - $now))) 'Ok'; $mark = Paint $g.Info 'Accent' }
        $title = Limit-PstText $r.Title 40
        if ($r.Done) { $title = Paint $title 'Dim' }
        $rows += , @([string]$i, "$mark $title", $r.Due.ToString('ddd dd/MM HH:mm'), $when)
        $i++
    }
    Format-PstTable -Columns @(
        @{ Name = 'N°'; Width = 3; Right = $true }, @{ Name = '  Rappel'; Width = 42 },
        @{ Name = 'Échéance'; Width = 16 }, @{ Name = ''; Width = 26 }
    ) -Rows $rows | ForEach-Object { Write-Host "  $_" }
}

function Select-Reminder {
    # Convertit un numéro affiché par « list » en rappel.
    param([string]$Number, [switch]$IncludeDone)
    $items = @(Get-VisibleReminders -IncludeDone:$IncludeDone)
    if ($Number -notmatch '^\d+$' -or [int]$Number -lt 1 -or [int]$Number -gt $items.Count) {
        Write-PstStatus err "Numéro invalide : « $Number » (voir « remind list »)."
        return $null
    }
    return $items[[int]$Number - 1]
}

function Complete-Reminder {
    param([string]$Number, [switch]$Delete)
    $target = Select-Reminder $Number
    if ($null -eq $target) { return }
    $list = @(Get-Reminders)
    if ($Delete) { $list = @($list | Where-Object { $_.Id -ne $target.Id }) }
    else { foreach ($r in $list) { if ($r.Id -eq $target.Id) { $r.Done = $true } } }
    Save-Reminders $list
    Unregister-ReminderTask $target.Id
    if ($Delete) { Write-PstStatus ok "Rappel supprimé : $($target.Title)" }
    else { Write-PstStatus ok "Rappel terminé : $($target.Title)" }
}

function Invoke-Fire {
    # Appelé par le Planificateur de tâches à l'échéance.
    param([string]$Id)
    $list = @(Get-Reminders)
    $hit = $null
    foreach ($r in $list) { if ($r.Id -eq $Id) { $hit = $r } }
    if ($null -eq $hit -or $hit.Done) { Unregister-ReminderTask $Id; return }
    Show-Toast -Title 'Rappel' -Message $hit.Title
    $hit.Notified = $true
    $hit.Done = $true
    Save-Reminders $list
    Unregister-ReminderTask $Id
    Start-Sleep -Seconds 2   # laisse le temps à la notification de s'afficher
}

function Show-Menu {
    while ($true) {
        try { Clear-Host } catch { $null = $_ }
        Show-PstHeader -Tool 'remind' -Subtitle 'rappels'
        Show-ReminderList
        Write-Host ''
        $choice = Read-PstChoice -Title 'Que voulez-vous faire ?' -Items @(
            'Nouveau rappel', 'Marquer un rappel comme terminé', 'Supprimer un rappel', 'Voir l''historique', 'Quitter'
        )
        Write-Host ''
        switch ($choice) {
            0 {
                $title = Read-Host '  Texte du rappel'
                $when = Read-Host '  Quand ? (15m, 2h, 18:30, demain 9:00, 25/12/2026 09:00)'
                if ($when -match '^\s*\d+\s*(j|d|h|min|m|s)' -or $when -match '^\s*\d+\s*$') { $null = Add-Reminder -Title $title -Delay $when }
                else { $null = Add-Reminder -Title $title -Moment $when }
                Wait-PstKey
            }
            1 { Complete-Reminder (Read-Host '  Numéro du rappel'); Wait-PstKey }
            2 { Complete-Reminder (Read-Host '  Numéro du rappel') -Delete; Wait-PstKey }
            3 { Show-ReminderList -IncludeDone; Wait-PstKey }
            default { return }
        }
    }
}

# ── Point d'entrée ───────────────────────────────────────────────────────────

Import-LegacyReminders

switch -Regex ($Command) {
    '^fire$' { Invoke-Fire $Text; break }
    '^(add|new|a)$' {
        Show-PstHeader -Tool 'remind'
        if (-not (Add-Reminder -Title $Text -Delay $In -Moment $At)) { exit 1 }
        Write-Host ''
        break
    }
    '^(list|ls|l)$' { Show-PstHeader -Tool 'remind' -Subtitle 'rappels'; Show-ReminderList -IncludeDone:$All; Write-Host ''; break }
    '^(done|ok)$' { Show-PstHeader -Tool 'remind'; Complete-Reminder $Text; Write-Host ''; break }
    '^(rm|remove|del|delete)$' { Show-PstHeader -Tool 'remind'; Complete-Reminder $Text -Delete; Write-Host ''; break }
    '^clear$' {
        Show-PstHeader -Tool 'remind'
        $list = @(Get-Reminders)
        $kept = @($list | Where-Object { -not $_.Done })
        Save-Reminders $kept
        Write-PstStatus ok "$($list.Count - $kept.Count) rappel(s) terminé(s) purgé(s)."
        Write-Host ''
        break
    }
    default {
        if ($Command) { Write-PstStatus err "Commande inconnue : « $Command » $($script:Pst.Glyph.Dot) voir « remind -Help »"; exit 1 }
        if (Test-PstInteractive) { Show-Menu }
        else { Show-PstHeader -Tool 'remind' -Subtitle 'rappels'; Show-ReminderList; Write-Host '' }
    }
}
