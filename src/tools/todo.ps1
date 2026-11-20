<#
.SYNOPSIS
    todo — liste de tâches du quotidien, rapide à utiliser en ligne de commande.
.DESCRIPTION
    Inspiré de todo.txt et taskwarrior, en plus simple : échéances en mots courants
    (demain, lundi, 25/12, +3j), priorités (! et !!), étiquettes (+courses).
    Les tâches sont enregistrées dans todo.json, dans le dossier de données de ps-tools.
    Aucune connexion réseau, aucun droit administrateur.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [string]$Due,
    [string]$Priority,
    [string[]]$Tag,
    [switch]$All,
    [switch]$Json,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'todo'
$g = $script:Pst.Glyph

if ($Help -or (Test-PstHelpArg (@($Command) + @($Rest)))) {
    Show-PstHelp -Name 'todo' -Synopsis (L 'Votre liste de tâches, rapide à tenir depuis le terminal.') `
        -Usage @(
            (L 'todo                                 tâches en cours (menu en session interactive)'),
            (L 'todo add "<texte>" [options]         ajoute une tâche (+tag, ! ou !! dans le texte)'),
            (L 'todo done <n> | undo <n>             marque comme faite / à refaire'),
            (L 'todo edit <n> "<texte>" [options]    modifie le texte, l''échéance ou la priorité'),
            (L 'todo rm <n> | clear                  supprime une tâche / purge les tâches faites'),
            (L 'todo list [-All] [-Tag <tag>]        liste (avec les tâches faites, filtrée)')
        ) `
        -Options @(
            @('-Due <date>', (L 'aujourd''hui, demain, lundi, 25/12, 2026-12-25, +3j, +2sem, aucune')),
            @('-Priority <p>', (L 'haute, moyenne, basse (ou high, medium, low)')),
            @('-Tag <tag>', (L 'Étiquette à ajouter, ou filtre pour « list »')),
            @('-All', (L 'Affiche aussi les tâches faites')),
            @('-Json', (L 'Sortie JSON (pour scripts ou « ask »)')),
            @('-DryRun', (L 'Montre ce que « rm » ou « clear » supprimerait, sans rien changer')),
            @('-Yes', (L 'Supprime sans demander de confirmation'))
        ) `
        -Examples @(
            (L 'todo add "Acheter du pain +courses" -Due demain'),
            (L 'todo add "Payer le loyer !!" -Due 1/12'),
            'todo done 2',
            (L 'todo edit 3 "Appeler le garage" -Due lundi'),
            (L 'todo list -Tag courses'),
            (L 'todo -Json | ask "Que dois-je faire en priorité ?"')
        ) `
        -Notes @(
            (L 'Les numéros sont ceux affichés par « todo » ; « todo list -All » numérote aussi les tâches faites.'),
            (L 'Un « ! » isolé dans le texte donne la priorité moyenne, « !! » la priorité haute.'),
            (L 'Fichier : todo.json dans le dossier de données de ps-tools.')
        )
    exit 0
}

# ── Messages (JSON : seuls les avertissements et erreurs, sur la sortie d'erreur) ──

function Write-TodoStatus {
    param([string]$Level, [string]$Message)
    if ($Json) {
        if ($Level -in 'warn', 'err') { [Console]::Error.WriteLine($Message) }
        return
    }
    Write-PstStatus $Level $Message
}

# ── Stockage ─────────────────────────────────────────────────────────────────

$store = Join-Path (Get-PstDataDir) 'todo.json'
$script:Corrupt = $false
$inv = [Globalization.CultureInfo]::InvariantCulture

function ConvertTo-TaskDate {
    # « yyyy-MM-dd » -> DateTime, ou $null.
    param($Value)
    if (-not $Value) { return $null }
    $d = [DateTime]::MinValue
    if ([DateTime]::TryParseExact([string]$Value, 'yyyy-MM-dd', $inv, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    return $null
}

function Get-Tasks {
    $list = @()
    if (-not (Test-Path -LiteralPath $store)) { return @() }
    try {
        $raw = [IO.File]::ReadAllText($store, [Text.Encoding]::UTF8)
        if (-not $raw.Trim()) { return @() }
        $data = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop
        # ForEach-Object aplatit le résultat : selon la version, « [] » revient vide ou comme un tableau imbriqué.
        foreach ($t in @($data | ForEach-Object { $_ })) {
            if ($null -eq $t -or $t -isnot [System.Management.Automation.PSCustomObject] -or -not $t.id) { continue }
            $prio = [string]$t.priority
            if ($prio -notin 'high', 'medium', 'low') { $prio = '' }
            $due = ''
            if (ConvertTo-TaskDate $t.due) { $due = [string]$t.due }
            $list += @{
                Id = [string]$t.id; Text = [string]$t.text; Done = [bool]$t.done
                Created = [string]$t.created; DoneAt = [string]$t.doneAt
                Due = $due; Priority = $prio
                Tags = @(@($t.tags) | Where-Object { $_ } | ForEach-Object { [string]$_ })
            }
        }
    }
    catch {
        $script:Corrupt = $true
        Write-TodoStatus warn (L 'Fichier de tâches illisible ({0}) : {1}' $store $_.Exception.Message)
        Write-TodoStatus warn (L 'Il sera mis de côté (copie de sauvegarde) à la prochaine modification.')
        return @()
    }
    return @($list)
}

function Save-Tasks {
    param($List)
    if ($script:Corrupt -and (Test-Path -LiteralPath $store)) {
        $backup = Join-Path (Split-Path -Parent $store) ('todo.corrupt-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        try {
            Move-Item -LiteralPath $store -Destination $backup -Force -ErrorAction Stop
            Write-TodoStatus warn (L 'Ancien fichier illisible conservé sous « {0} ».' $backup)
        }
        catch { $null = $_ }
        $script:Corrupt = $false
    }
    $data = @(@($List) | Where-Object { $_ } | ForEach-Object {
            [ordered]@{
                id = $_.Id; text = $_.Text; done = [bool]$_.Done; created = $_.Created; doneAt = $_.DoneAt
                due = $_.Due; priority = $_.Priority; tags = @($_.Tags)
            }
        })
    $json = ConvertTo-Json -InputObject $data -Depth 5
    [IO.File]::WriteAllText($store, $json, (New-Object Text.UTF8Encoding $false))
}

# ── Analyse des saisies ──────────────────────────────────────────────────────

function ConvertTo-Plain {
    # Minuscules sans accents, apostrophes typographiques normalisées.
    param([string]$Text)
    $t = $Text.Trim().ToLowerInvariant().Replace([string][char]0x2019, "'")
    $t = $t.Normalize([Text.NormalizationForm]::FormD)
    return ($t -replace '\p{Mn}', '')
}

function ConvertFrom-DueText {
    # « demain », « lundi », « 25/12 », « 2026-12-25 », « +3j »  ->  date ; [DateTime]::MinValue = aucune échéance.
    param([string]$Value, [DateTime]$Today = (Get-Date).Date)
    $v = (ConvertTo-Plain $Value) -replace '\s+', ' '
    if ($v -match '^(aucune?|none|jamais|never|-|0)$') { return [DateTime]::MinValue }
    if ($v -match "^(aujourd'?hui|auj|today|tod)$") { return $Today }
    if ($v -match '^(demain|dem|tomorrow|tmr)$') { return $Today.AddDays(1) }
    if ($v -match '^(apres[- ]?demain|day after tomorrow)$') { return $Today.AddDays(2) }
    if ($v -match '^(hier|yesterday)$') { return $Today.AddDays(-1) }
    if ($v -match '^(semaine prochaine|next week)$') { return $Today.AddDays(7) }
    if ($v -match '^(mois prochain|next month)$') { return $Today.AddMonths(1) }

    $days = @{
        'lundi' = 1; 'lun' = 1; 'monday' = 1; 'mon' = 1
        'mardi' = 2; 'mar' = 2; 'tuesday' = 2; 'tue' = 2; 'tues' = 2
        'mercredi' = 3; 'mer' = 3; 'wednesday' = 3; 'wed' = 3
        'jeudi' = 4; 'jeu' = 4; 'thursday' = 4; 'thu' = 4; 'thur' = 4; 'thurs' = 4
        'vendredi' = 5; 'ven' = 5; 'friday' = 5; 'fri' = 5
        'samedi' = 6; 'sam' = 6; 'saturday' = 6; 'sat' = 6
        'dimanche' = 0; 'dim' = 0; 'sunday' = 0; 'sun' = 0
    }
    $word = $v -replace '^(next|ce|cette) ', '' -replace ' (prochain|prochaine)$', '' -replace '\.$', ''
    if ($days.ContainsKey($word)) {
        $delta = ($days[$word] - [int]$Today.DayOfWeek + 7) % 7
        if ($delta -eq 0) { $delta = 7 }   # « lundi » un lundi : celui de la semaine prochaine
        return $Today.AddDays($delta)
    }

    if ($v -match '^(?:\+|dans |in )?(\d+) ?(j|d|jours?|days?)?$') { return $Today.AddDays([int]$Matches[1]) }
    if ($v -match '^(?:\+|dans |in )?(\d+) ?(s|sem|semaines?|w|wk|weeks?)$') { return $Today.AddDays(7 * [int]$Matches[1]) }
    if ($v -match '^(?:\+|dans |in )?(\d+) ?(mois|mo|months?)$') { return $Today.AddMonths([int]$Matches[1]) }

    try {
        if ($v -match '^(\d{1,2})[/.](\d{1,2})$') {
            $d = New-Object DateTime $Today.Year, ([int]$Matches[2]), ([int]$Matches[1])
            if ($d -lt $Today) { $d = $d.AddYears(1) }   # date déjà passée cette année : l'an prochain
            return $d
        }
        if ($v -match '^(\d{1,2})[/.](\d{1,2})[/.](\d{2}|\d{4})$') {
            $y = [int]$Matches[3]
            if ($y -lt 100) { $y += 2000 }
            return (New-Object DateTime $y, ([int]$Matches[2]), ([int]$Matches[1]))
        }
        if ($v -match '^(\d{4})-(\d{1,2})-(\d{1,2})$') {
            return (New-Object DateTime ([int]$Matches[1]), ([int]$Matches[2]), ([int]$Matches[3]))
        }
    }
    catch { $null = $_ }
    throw (L 'Échéance non reconnue : « {0} » (exemples : demain, lundi, 25/12, 2026-12-25, +3j)' $Value)
}

function ConvertFrom-PriorityText {
    param([string]$Value)
    $v = ConvertTo-Plain $Value
    if ($v -match '^(haute?|high|h|elevee|urgente?|urgent|!!+|a|1)$') { return 'high' }
    if ($v -match '^(moyenne?|medium|med|m|normale?|normal|!|b|2)$') { return 'medium' }
    if ($v -match '^(basse?|low|l|faible|c|3)$') { return 'low' }
    if ($v -match '^(aucune?|none|-|0)$') { return '' }
    throw (L 'Priorité non reconnue : « {0} » (haute, moyenne, basse)' $Value)
}

function ConvertTo-TagName {
    param([string]$Value)
    return ($Value.Trim() -replace '^\+', '').ToLowerInvariant()
}

function Split-TaskText {
    # Extrait du texte les étiquettes « +tag » et les marques de priorité « ! » / « !! ».
    param([string]$Text)
    $tags = @(); $prio = ''; $words = @()
    foreach ($w in ($Text.Trim() -split '\s+')) {
        if (-not $w) { continue }
        if ($w -match '^\+([\p{L}\p{N}][\p{L}\p{N}_\-\.]*)$') { $tags += $Matches[1].ToLowerInvariant(); continue }
        if ($w -match '^!{2,}$') { $prio = 'high'; continue }
        if ($w -eq '!') { if ($prio -ne 'high') { $prio = 'medium' }; continue }
        $words += $w
    }
    return @{ Text = ($words -join ' '); Tags = @($tags | Select-Object -Unique); Priority = $prio }
}

# ── Classement et numérotation ───────────────────────────────────────────────

function Get-TaskGroup {
    param($Task, [DateTime]$Today)
    if ($Task.Done) { return 'done' }
    $due = ConvertTo-TaskDate $Task.Due
    if ($null -eq $due) { return 'someday' }
    if ($due -lt $Today) { return 'overdue' }
    if ($due -eq $Today) { return 'today' }
    return 'upcoming'
}

function Get-OrderedTasks {
    # Ordre d'affichage ; les numéros des commandes en découlent :
    # en retard, aujourd'hui, à venir, un jour, puis les tâches faites.
    param($List)
    $today = (Get-Date).Date
    $groupRank = @{ overdue = 0; today = 1; upcoming = 2; someday = 3; done = 4 }
    $prioRank = @{ high = 0; medium = 1; '' = 2; low = 3 }
    # Départage final par ordre d'ajout : deux tâches créées dans la même seconde gardent
    # toujours le même numéro (Sort-Object n'est pas stable sous Windows PowerShell 5.1).
    $position = @{}
    $k = 0
    foreach ($t in @($List)) { if ($t) { $position[[string]$t.Id] = $k; $k++ } }
    $open = @(@($List) | Where-Object { -not $_.Done } | Sort-Object `
            @{ Expression = { $groupRank[(Get-TaskGroup $_ $today)] } },
            @{ Expression = { if ($_.Due) { $_.Due } else { '9999' } } },
            @{ Expression = { $prioRank[[string]$_.Priority] } },
            @{ Expression = { $_.Created } },
            @{ Expression = { $position[[string]$_.Id] } })
    $done = @(@($List) | Where-Object { $_.Done } | Sort-Object @{ Expression = { $_.DoneAt }; Descending = $true }, @{ Expression = { $position[[string]$_.Id] } })
    $out = @()
    $n = 1
    foreach ($t in @($open + $done)) {
        $t.Number = $n
        $t.Group = Get-TaskGroup $t $today
        $out += $t
        $n++
    }
    return @($out)
}

function Select-Tasks {
    # Numéros affichés -> tâches ; $null si l'un d'eux est invalide.
    param([string[]]$Numbers, $Ordered)
    $Numbers = @($Numbers | ForEach-Object { $_ -split '[,; ]+' } | Where-Object { $_ })
    if ($Numbers.Count -eq 0) { Write-TodoStatus err (L 'Précisez le numéro d''une tâche (voir « todo list »).'); return $null }
    $picked = @()
    foreach ($n in $Numbers) {
        if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt @($Ordered).Count) {
            Write-TodoStatus err (L 'Numéro invalide : « {0} » (voir « todo list -All »).' $n)
            return $null
        }
        $t = @($Ordered)[[int]$n - 1]
        if (-not ($picked | Where-Object { $_.Id -eq $t.Id })) { $picked += $t }
    }
    return , @($picked)
}

# ── Affichage ────────────────────────────────────────────────────────────────

function Format-DueWords {
    param($Task, [DateTime]$Today)
    $due = ConvertTo-TaskDate $Task.Due
    if ($null -eq $due) { return '' }
    $d = [int]($due - $Today).TotalDays
    $date = $due.ToString((L 'ddd d MMM'), (Get-PstCulture))
    if ($Task.Done) { return (Paint $date 'Dim') }
    if ($d -lt 0) {
        if ($d -eq -1) { $rel = L 'en retard de 1 j' } else { $rel = L 'en retard de {0} j' (-$d) }
        return (Paint $rel 'Err' -Bold) + '  ' + (Paint $date 'Dim')
    }
    if ($d -eq 0) { return (Paint (L 'aujourd''hui') 'Warn' -Bold) }
    if ($d -eq 1) { return (Paint (L 'demain') 'Accent') + '  ' + (Paint $date 'Dim') }
    return (Paint (L 'dans {0} j' $d) 'Ok') + '  ' + (Paint $date 'Dim')
}

function Format-PriorityMark {
    param([string]$Priority, [switch]$Done)
    if ($Done) { return (Paint $g.Ok 'Ok') + ' ' }
    switch ($Priority) {
        'high' { return (Paint '!!' 'Err' -Bold) }
        'medium' { return (Paint ' !' 'Warn' -Bold) }
        'low' { return (Paint (' ' + $g.Down) 'Dim') }
        default { return '  ' }
    }
}

function Get-GroupTitle {
    param([string]$Group)
    switch ($Group) {
        'overdue' { return (Paint (L 'En retard') 'Err' -Bold) }
        'today' { return (Paint (L 'Pour aujourd''hui') 'Warn' -Bold) }
        'upcoming' { return (Paint (L 'À venir') 'Accent' -Bold) }
        'someday' { return (Paint (L 'Un jour') 'Accent2' -Bold) }
        default { return (Paint (L 'Faites') 'Dim' -Bold) }
    }
}

function Show-TaskList {
    param([switch]$IncludeDone, [string[]]$Tags = @())
    $ordered = @(Get-OrderedTasks (Get-Tasks))
    $today = (Get-Date).Date
    $wanted = @($Tags | Where-Object { $_ } | ForEach-Object { ConvertTo-TagName $_ })
    $shown = @($ordered | Where-Object {
            ($IncludeDone -or -not $_.Done) -and
            ($wanted.Count -eq 0 -or @($_.Tags | Where-Object { $wanted -contains $_ }).Count -gt 0)
        })
    $openCount = @($ordered | Where-Object { -not $_.Done }).Count
    $doneCount = $ordered.Count - $openCount

    if ($shown.Count -eq 0) {
        if ($wanted.Count) { Write-PstStatus info (L 'Aucune tâche avec l''étiquette « {0} ».' ($wanted -join ', ')) }
        elseif ($openCount -eq 0) {
            Write-PstStatus ok (L 'Rien à faire, profitez-en.')
            Write-Host ('  ' + (Paint (L 'Ajoutez une tâche : todo add "Acheter du pain" -Due demain') 'Dim'))
        }
        return
    }

    $textWidth = [Math]::Max(20, [Math]::Min(46, (Get-PstWidth) - 52))
    $group = $null
    foreach ($t in $shown) {
        if ($t.Group -ne $group) {
            if ($null -ne $group) { Write-Host '' }
            $group = $t.Group
            Write-Host ('  ' + (Get-GroupTitle $group))
        }
        $text = Limit-PstText $t.Text $textWidth
        if ($t.Done) { $text = Paint $text 'Dim' }
        $tagText = ''
        if (@($t.Tags).Count) { $tagText = Paint ((@($t.Tags) | ForEach-Object { "+$_" }) -join ' ') 'Accent2' }
        $line = '  ' + (Paint ('{0,4}' -f $t.Number) 'Dim') + ' ' + (Format-PriorityMark $t.Priority -Done:$t.Done) + ' ' +
        (Format-PstPad $text $textWidth) + '  ' + (Format-PstPad $tagText 14) + ' ' + (Format-DueWords $t $today)
        Write-Host $line.TrimEnd()
    }
    Write-Host ''
    $summary = L '{0} tâche(s) en cours · {1} faite(s)' $openCount $doneCount
    if (-not $IncludeDone -and $doneCount -gt 0) { $summary += '  ' + $g.Dot + '  ' + (L '« todo list -All » pour tout voir') }
    Write-Host ('  ' + (Paint $summary 'Dim'))
}

function ConvertTo-TaskJson {
    param($Task)
    $due = $null
    if ($Task.Due) { $due = $Task.Due }
    return [ordered]@{
        number = $Task.Number; text = $Task.Text; done = [bool]$Task.Done; group = $Task.Group
        due = $due; priority = $Task.Priority; tags = @($Task.Tags); created = $Task.Created; doneAt = $Task.DoneAt
    }
}

function Write-TaskJson {
    param($Tasks, [switch]$Single)
    $items = @(@($Tasks) | Where-Object { $_ } | ForEach-Object { ConvertTo-TaskJson $_ })
    if ($Single -and $items.Count -eq 1) { Write-Output (ConvertTo-Json -InputObject $items[0] -Depth 4); return }
    Write-Output (ConvertTo-Json -InputObject $items -Depth 4)
}

function Find-Ordered {
    # Retrouve une tâche (avec son numéro) dans la liste ordonnée.
    param([string]$Id)
    return (@(Get-OrderedTasks (Get-Tasks)) | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

# ── Commandes ────────────────────────────────────────────────────────────────

function Add-Task {
    param([string]$Text, [string]$DueText, [string]$PriorityText, [string[]]$Tags = @())
    $parts = Split-TaskText $Text
    if ([string]::IsNullOrWhiteSpace($parts.Text)) { Write-TodoStatus err (L 'Le texte de la tâche est vide.'); return $null }
    try {
        $dueValue = ''
        if ($DueText) {
            $d = ConvertFrom-DueText $DueText
            if ($d -ne [DateTime]::MinValue) { $dueValue = $d.ToString('yyyy-MM-dd') }
        }
        $prio = $parts.Priority
        if ($PriorityText) { $prio = ConvertFrom-PriorityText $PriorityText }
    }
    catch { Write-TodoStatus err $_.Exception.Message; return $null }
    $allTags = @(@($parts.Tags) + @($Tags | Where-Object { $_ } | ForEach-Object { ($_ -split ',') } | Where-Object { $_.Trim() } | ForEach-Object { ConvertTo-TagName $_ }) | Select-Object -Unique)
    $task = @{
        Id = [Guid]::NewGuid().ToString('N').Substring(0, 10); Text = $parts.Text; Done = $false
        Created = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'); DoneAt = ''; Due = $dueValue; Priority = $prio; Tags = $allTags
    }
    $list = @(Get-Tasks) + $task
    Save-Tasks $list
    $saved = Find-Ordered $task.Id
    $detail = ''
    if ($dueValue) { $detail = ' ' + $g.Dot + ' ' + (Format-DueWords $saved (Get-Date).Date) }
    Write-TodoStatus ok ((L 'Tâche n° {0} ajoutée : {1}' $saved.Number (Paint $task.Text 'Title' -Bold)) + $detail)
    return $saved
}

function Set-TaskState {
    # done / undo / rm sur un ou plusieurs numéros.
    param([string[]]$Numbers, [ValidateSet('done', 'undo', 'rm')][string]$Action)
    $ordered = @(Get-OrderedTasks (Get-Tasks))
    $targets = Select-Tasks $Numbers $ordered
    if ($null -eq $targets) { return $null }
    $ids = @($targets | ForEach-Object { $_.Id })

    if ($Action -eq 'rm') {
        foreach ($t in $targets) { Write-TodoStatus info (L 'À supprimer : n° {0} {1}' $t.Number $t.Text) }
        if ($DryRun) { Write-TodoStatus info (L 'Simulation : rien n''a été supprimé.'); return , @() }
        if (-not $Yes) {
            if (-not (Test-PstInteractive)) { Write-TodoStatus err (L 'Session non interactive : ajoutez -Yes pour confirmer la suppression.'); return $null }
            if (-not (Read-PstConfirm (L 'Supprimer définitivement ?') -DefaultYes)) { Write-TodoStatus info (L 'Annulé.'); return , @() }
        }
        Save-Tasks @($ordered | Where-Object { $ids -notcontains $_.Id })
        foreach ($t in $targets) { Write-TodoStatus ok (L 'Tâche supprimée : {0}' $t.Text) }
        return , @($targets)
    }

    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    foreach ($t in $ordered) {
        if ($ids -notcontains $t.Id) { continue }
        if ($Action -eq 'done') { $t.Done = $true; $t.DoneAt = $now } else { $t.Done = $false; $t.DoneAt = '' }
    }
    Save-Tasks $ordered
    foreach ($t in $targets) {
        if ($Action -eq 'done') { Write-TodoStatus ok (L 'Bravo, c''est fait : {0}' (Paint $t.Text 'Title' -Bold)) }
        else { Write-TodoStatus ok (L 'Tâche remise en cours : {0}' (Paint $t.Text 'Title' -Bold)) }
    }
    return , @($targets | ForEach-Object { Find-Ordered $_.Id })
}

function Edit-Task {
    param([string]$Number, [string]$Text, [string]$DueText, [string]$PriorityText, [string[]]$Tags = @())
    $ordered = @(Get-OrderedTasks (Get-Tasks))
    $targets = Select-Tasks @($Number) $ordered
    if ($null -eq $targets) { return $null }
    $target = @($targets)[0]
    if (-not $Text -and -not $DueText -and -not $PriorityText -and -not @($Tags | Where-Object { $_ }).Count) {
        Write-TodoStatus err (L 'Rien à modifier : donnez un nouveau texte, -Due, -Priority ou -Tag.')
        return $null
    }
    try {
        if ($Text) {
            $parts = Split-TaskText $Text
            if ($parts.Text) { $target.Text = $parts.Text }
            if ($parts.Priority) { $target.Priority = $parts.Priority }
            $target.Tags = @(@($target.Tags) + @($parts.Tags) | Select-Object -Unique)
        }
        if ($DueText) {
            $d = ConvertFrom-DueText $DueText
            if ($d -eq [DateTime]::MinValue) { $target.Due = '' } else { $target.Due = $d.ToString('yyyy-MM-dd') }
        }
        if ($PriorityText) { $target.Priority = ConvertFrom-PriorityText $PriorityText }
    }
    catch { Write-TodoStatus err $_.Exception.Message; return $null }
    foreach ($tg in @($Tags | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | Where-Object { $_.Trim() })) {
        $name = ConvertTo-TagName $tg
        if ($tg.Trim().StartsWith('-')) {
            # « -Tag -courses » retire l'étiquette
            $name = ConvertTo-TagName ($tg.Trim().Substring(1))
            $target.Tags = @(@($target.Tags) | Where-Object { $_ -ne $name })
        }
        elseif (@($target.Tags) -notcontains $name) { $target.Tags = @(@($target.Tags) + $name) }
    }
    Save-Tasks $ordered
    $saved = Find-Ordered $target.Id
    Write-TodoStatus ok (L 'Tâche n° {0} modifiée : {1}' $saved.Number (Paint $saved.Text 'Title' -Bold))
    return $saved
}

function Clear-DoneTasks {
    $ordered = @(Get-OrderedTasks (Get-Tasks))
    $done = @($ordered | Where-Object { $_.Done })
    if ($done.Count -eq 0) { Write-TodoStatus info (L 'Aucune tâche faite à purger.'); return $true }
    foreach ($t in $done) { Write-TodoStatus info (L 'À purger : {0}' $t.Text) }
    if ($DryRun) { Write-TodoStatus info (L 'Simulation : {0} tâche(s) seraient purgée(s).' $done.Count); return $true }
    if (-not $Yes) {
        if (-not (Test-PstInteractive)) { Write-TodoStatus err (L 'Session non interactive : ajoutez -Yes pour confirmer la purge.'); return $false }
        if (-not (Read-PstConfirm (L 'Purger ces {0} tâche(s) faite(s) ?' $done.Count) -DefaultYes)) { Write-TodoStatus info (L 'Annulé.'); return $true }
    }
    Save-Tasks @($ordered | Where-Object { -not $_.Done })
    Write-TodoStatus ok (L '{0} tâche(s) faite(s) purgée(s).' $done.Count)
    return $true
}

# ── Menu interactif ──────────────────────────────────────────────────────────

function Select-TaskInMenu {
    # Choix d'une tâche aux flèches ; $null si annulé.
    param([string]$Title, [switch]$Done)
    $ordered = @(Get-OrderedTasks (Get-Tasks))
    $pool = @($ordered | Where-Object { [bool]$_.Done -eq [bool]$Done })
    if ($pool.Count -eq 0) { Write-PstStatus info (L 'Aucune tâche à choisir.'); return $null }
    $items = @($pool | ForEach-Object { ('{0,3}. {1}' -f $_.Number, (Limit-PstText $_.Text 50)) })
    $hints = @($pool | ForEach-Object { Format-DueWords $_ (Get-Date).Date })
    $i = Read-PstChoice -Title $Title -Items $items -Hints $hints
    if ($i -lt 0) { return $null }
    return $pool[$i]
}

function Show-Menu {
    $showDone = $false
    while ($true) {
        try { Clear-Host } catch { $null = $_ }
        Show-PstHeader -Tool 'todo' -Subtitle (L 'tâches')
        Show-TaskList -IncludeDone:$showDone
        Write-Host ''
        $toggle = L 'Afficher les tâches faites'
        if ($showDone) { $toggle = L 'Masquer les tâches faites' }
        $choice = Read-PstChoice -Title (L 'Que voulez-vous faire ?') -Items @(
            (L 'Ajouter une tâche'), (L 'Marquer une tâche comme faite'), (L 'Modifier une tâche'),
            (L 'Supprimer une tâche'), (L 'Remettre une tâche en cours'), $toggle, (L 'Purger les tâches faites'), (L 'Quitter')
        )
        Write-Host ''
        switch ($choice) {
            0 {
                $text = Read-PstText (L 'Tâche (+tag pour une étiquette, ! ou !! pour la priorité)')
                if ($text) {
                    $when = Read-PstText (L 'Échéance (demain, lundi, 25/12, +3j ; Entrée = aucune)')
                    $null = Add-Task -Text $text -DueText $when
                    Wait-PstKey (L 'Appuyez sur une touche pour continuer...')
                }
            }
            1 { $t = Select-TaskInMenu (L 'Quelle tâche est faite ?'); if ($t) { $null = Set-TaskState @([string]$t.Number) 'done'; Wait-PstKey (L 'Appuyez sur une touche pour continuer...') } }
            2 {
                $t = Select-TaskInMenu (L 'Quelle tâche modifier ?')
                if ($t) {
                    $text = Read-PstText (L 'Texte') -Default $t.Text
                    $current = ''
                    if ($t.Due) { $current = (ConvertTo-TaskDate $t.Due).ToString('dd/MM/yyyy') }
                    $when = Read-PstText (L 'Échéance (« aucune » pour l''enlever)') -Default $current
                    $prio = Read-PstText (L 'Priorité (haute, moyenne, basse, aucune)') -Default $t.Priority
                    if ($text -eq $t.Text) { $text = '' }
                    if ($when -eq $current) { $when = '' }
                    if ($prio -eq $t.Priority) { $prio = '' }
                    if ($text -or $when -or $prio) { $null = Edit-Task -Number ([string]$t.Number) -Text $text -DueText $when -PriorityText $prio }
                    else { Write-PstStatus info (L 'Aucun changement.') }
                    Wait-PstKey (L 'Appuyez sur une touche pour continuer...')
                }
            }
            3 { $t = Select-TaskInMenu (L 'Quelle tâche supprimer ?'); if ($t) { $null = Set-TaskState @([string]$t.Number) 'rm'; Wait-PstKey (L 'Appuyez sur une touche pour continuer...') } }
            4 { $t = Select-TaskInMenu (L 'Quelle tâche remettre en cours ?') -Done; if ($t) { $null = Set-TaskState @([string]$t.Number) 'undo' }; Wait-PstKey (L 'Appuyez sur une touche pour continuer...') }
            5 { $showDone = -not $showDone }
            6 { $null = Clear-DoneTasks; Wait-PstKey (L 'Appuyez sur une touche pour continuer...') }
            default { return }
        }
    }
}

# ── Point d'entrée ───────────────────────────────────────────────────────────

$words = @($Rest | Where-Object { $null -ne $_ -and $_ -ne '' })
$header = { param([string]$Subtitle) if (-not $Json) { Show-PstHeader -Tool 'todo' -Subtitle $Subtitle } }
$footer = { if (-not $Json) { Write-Host '' } }

switch -Regex ($Command) {
    '^(add|a|new|ajouter|ajout)$' {
        & $header
        $task = Add-Task -Text ($words -join ' ') -DueText $Due -PriorityText $Priority -Tags $Tag
        if ($null -eq $task) { exit 1 }
        if ($Json) { Write-TaskJson $task -Single }
        & $footer
        break
    }
    '^(done|do|ok|fait|finir|x)$' {
        & $header
        $r = Set-TaskState $words 'done'
        if ($null -eq $r) { exit 1 }
        if ($Json) { Write-TaskJson $r }
        & $footer
        break
    }
    '^(undo|undone|reopen|defaire|refaire)$' {
        & $header
        $r = Set-TaskState $words 'undo'
        if ($null -eq $r) { exit 1 }
        if ($Json) { Write-TaskJson $r }
        & $footer
        break
    }
    '^(rm|remove|del|delete|suppr|supprimer)$' {
        & $header
        $r = Set-TaskState $words 'rm'
        if ($null -eq $r) { exit 1 }
        if ($Json) { Write-TaskJson $r }
        & $footer
        break
    }
    '^(edit|e|modifier|mod)$' {
        & $header
        $number = ''
        if ($words.Count) { $number = $words[0] }
        $text = ''
        if ($words.Count -gt 1) { $text = ($words[1..($words.Count - 1)] -join ' ') }
        $task = Edit-Task -Number $number -Text $text -DueText $Due -PriorityText $Priority -Tags $Tag
        if ($null -eq $task) { exit 1 }
        if ($Json) { Write-TaskJson $task -Single }
        & $footer
        break
    }
    '^(clear|purge|purger)$' {
        & $header
        if (-not (Clear-DoneTasks)) { exit 1 }
        & $footer
        break
    }
    '^(list|ls|l|liste)?$' {
        if ($Json) {
            $ordered = @(Get-OrderedTasks (Get-Tasks))
            $wanted = @($Tag | Where-Object { $_ } | ForEach-Object { ConvertTo-TagName $_ })
            Write-TaskJson @($ordered | Where-Object {
                    ($All -or -not $_.Done) -and ($wanted.Count -eq 0 -or @($_.Tags | Where-Object { $wanted -contains $_ }).Count -gt 0)
                })
            break
        }
        if (-not $Command -and -not $All -and -not $Tag -and (Test-PstInteractive)) { Show-Menu; break }
        Show-PstHeader -Tool 'todo' -Subtitle (L 'tâches')
        Show-TaskList -IncludeDone:$All -Tags $Tag
        Write-Host ''
        break
    }
    default {
        Write-TodoStatus err (L 'Commande inconnue : « {0} » · pour ajouter une tâche : todo add "<texte>" · voir « todo -Help »' $Command)
        exit 1
    }
}
exit 0
