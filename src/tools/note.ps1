<#
.SYNOPSIS
    note — notes rapides et journal du quotidien.
.DESCRIPTION
    Chaque note est horodatée et ajoutée au fichier du jour : un fichier Markdown par
    jour (notes/AAAA-MM-JJ.md dans le dossier de données de ps-tools), lisible et facile
    à synchroniser ou sauvegarder. Aucune connexion réseau, aucun droit administrateur.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Text,
    # Reçoit le pipeline ; l'ensemble des lignes est lu plus bas via `$input.
    [Parameter(ValueFromPipeline = $true)][object]$InputObject,
    [string]$Search,
    [switch]$Today,
    [switch]$Edit,
    [switch]$List,
    [switch]$Path,
    [int]$Days = 3,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$piped = @($input)
. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'note'
$g = $script:Pst.Glyph

if ($Help -or (Test-PstHelpArg (@($Text) + @($Rest)))) {
    Show-PstHelp -Name 'note' -Synopsis (L 'Notes rapides et journal : une idée, une ligne, sans quitter le terminal.') `
        -Usage @(
            (L 'note "<texte>"            ajoute une note horodatée à la page du jour'),
            (L 'note                      dernières notes (aujourd''hui et les jours précédents)'),
            (L 'note -Search <mot>        cherche dans toutes les notes'),
            (L 'note -Today | -Edit       ouvre la page du jour dans votre éditeur'),
            (L 'note -List                jours avec le nombre de notes'),
            (L '<commande> | note         note le texte reçu par le pipeline')
        ) `
        -Options @(
            @('-Days <n>', (L 'Nombre de jours affichés par « note » (3 par défaut)')),
            @('-Path', (L 'Affiche seulement le chemin du fichier du jour')),
            @('-Json', (L 'Sortie JSON (pour scripts ou « ask »)'))
        ) `
        -Examples @(
            (L 'note "Appeler le plombier pour le devis"'),
            (L 'note -Search plombier'),
            'Get-Clipboard | note',
            (L 'note -Days 7 -Json | ask "Résume ma semaine"')
        ) `
        -Notes @(
            (L 'Éditeur : $env:EDITOR, sinon VS Code (code), sinon le Bloc-notes sous Windows.'),
            (L 'Fichiers : un fichier Markdown par jour dans le dossier « notes » des données de ps-tools.')
        )
    exit 0
}

# ── Stockage ─────────────────────────────────────────────────────────────────

$notesDir = Join-Path (Get-PstDataDir) 'notes'
$inv = [Globalization.CultureInfo]::InvariantCulture
$utf8 = New-Object Text.UTF8Encoding $false

function Get-DayFile {
    param([DateTime]$Date)
    return (Join-Path $notesDir ($Date.ToString('yyyy-MM-dd', $inv) + '.md'))
}

function Initialize-DayFile {
    # Crée le fichier du jour avec son titre ; retourne son chemin.
    param([DateTime]$Date)
    if (-not (Test-Path -LiteralPath $notesDir)) { New-Item -ItemType Directory -Path $notesDir -Force | Out-Null }
    $file = Get-DayFile $Date
    if (-not (Test-Path -LiteralPath $file)) {
        $title = L 'Notes du {0}' ($Date.ToString((L 'dddd d MMMM yyyy'), (Get-PstCulture)))
        [IO.File]::WriteAllText($file, "# $title`n", $utf8)
    }
    return $file
}

function Get-DayFiles {
    # Fichiers AAAA-MM-JJ.md, du plus récent au plus ancien.
    if (-not (Test-Path -LiteralPath $notesDir)) { return @() }
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $notesDir -Filter '*.md' -File | Sort-Object Name -Descending)) {
        $d = [DateTime]::MinValue
        if ([DateTime]::TryParseExact($f.BaseName, 'yyyy-MM-dd', $inv, [Globalization.DateTimeStyles]::None, [ref]$d)) {
            $out += @{ Date = $d; File = $f.FullName }
        }
    }
    return @($out)
}

function Read-DayNotes {
    # Entrées d'un fichier : « - **HH:mm** texte », lignes suivantes indentées.
    # Les lignes ajoutées à la main (hors titre) deviennent des notes sans heure.
    param([string]$File)
    $entries = New-Object System.Collections.ArrayList
    $current = $null
    $lines = @()
    try { $lines = [IO.File]::ReadAllLines($File, [Text.Encoding]::UTF8) } catch { return @() }
    foreach ($raw in $lines) {
        $line = $raw.TrimStart([char]0xFEFF).TrimEnd()
        if ($line -match '^- \*\*(\d{1,2}:\d{2})\*\* ?(.*)$') {
            $current = @{ Time = $Matches[1]; Lines = @($Matches[2]) }
            [void]$entries.Add($current)
        }
        elseif ($line -match '^#') { $current = $null }
        elseif (-not $line.Trim()) { continue }
        elseif ($current -and $raw -match '^\s{2,}') { $current.Lines += $line.Trim() }
        else {
            $current = @{ Time = ''; Lines = @(($line -replace '^[-*]\s+', '')) }
            [void]$entries.Add($current)
        }
    }
    return @($entries | ForEach-Object { @{ Time = $_.Time; Text = ($_.Lines -join "`n") } })
}

function Add-Note {
    param([string]$Body)
    $now = Get-Date
    $file = Initialize-DayFile $now
    $lines = @($Body -split "\r?\n")
    # Retire les lignes vides de début et de fin.
    while ($lines.Count -and -not $lines[0].Trim()) { $lines = @($lines | Select-Object -Skip 1) }
    while ($lines.Count -and -not $lines[-1].Trim()) { $lines = @($lines | Select-Object -SkipLast 1) }
    if ($lines.Count -eq 0) { Write-PstStatus err (L 'La note est vide.'); return $false }
    $entry = "- **$($now.ToString('HH:mm', $inv))** $($lines[0].TrimEnd())`n"
    foreach ($l in @($lines | Select-Object -Skip 1)) { $entry += "  $($l.TrimEnd())`n" }
    $existing = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    if ($existing.Length -and -not $existing.EndsWith("`n")) { $entry = "`n" + $entry }
    if ($existing -notmatch '(?m)^- \*\*') { $entry = "`n" + $entry }   # ligne vide sous le titre
    [IO.File]::AppendAllText($file, $entry, $utf8)
    $preview = Limit-PstText $lines[0].Trim() 60
    if ($lines.Count -gt 1) { $preview += ' ' + (Paint (L '(+{0} ligne(s))' ($lines.Count - 1)) 'Dim') }
    Write-PstStatus ok (L 'Note ajoutée à {0} : {1}' $now.ToString('HH:mm', $inv) $preview)
    Write-Host ('  ' + (Paint $file 'Dim'))
    return $true
}

# ── Affichage ────────────────────────────────────────────────────────────────

function Get-DayTitle {
    param([DateTime]$Date)
    $today = (Get-Date).Date
    $long = $Date.ToString((L 'dddd d MMMM yyyy'), (Get-PstCulture))
    if ($Date -eq $today) { return (Paint (L 'Aujourd''hui') 'Accent' -Bold) + (Paint "  $($g.Dot) $long" 'Dim') }
    if ($Date -eq $today.AddDays(-1)) { return (Paint (L 'Hier') 'Accent' -Bold) + (Paint "  $($g.Dot) $long" 'Dim') }
    return (Paint $long 'Accent' -Bold)
}

function Write-NoteEntry {
    # Une note : heure en gris, texte (lignes suivantes alignées) ; -Pattern surligne.
    param($Entry, [string]$Pattern = '')
    $time = $Entry.Time
    if (-not $time) { $time = '  -  ' }
    $first = $true
    foreach ($l in @($Entry.Text -split "`n")) {
        $shown = $l
        if ($Pattern) { $shown = [regex]::Replace($l, $Pattern, { param($m) Paint $m.Value 'Warn' -Bold }) }
        if ($first) { Write-Host ('    ' + (Paint $time.PadLeft(5) 'Dim') + '  ' + $shown); $first = $false }
        else { Write-Host ('           ' + $shown) }
    }
}

function Show-RecentNotes {
    param([int]$DayCount)
    $files = @(Get-DayFiles | Select-Object -First ([Math]::Max(1, $DayCount)))
    $result = @()
    foreach ($f in $files) {
        $notes = @(Read-DayNotes $f.File)
        if ($notes.Count) { $result += @{ Date = $f.Date; Notes = $notes } }
    }
    return @($result)
}

function ConvertTo-NoteJson {
    param($Date, $Entry)
    return [ordered]@{ date = $Date.ToString('yyyy-MM-dd', $inv); time = $Entry.Time; text = $Entry.Text }
}

function Open-InEditor {
    # $env:EDITOR (avec ses arguments), sinon code, sinon notepad (Windows), sinon le chemin.
    param([string]$File)
    if (-not (Test-PstInteractive)) { Write-Output $File; return }
    $editor = $env:EDITOR
    if (-not $editor) { $editor = $env:VISUAL }
    if ($editor) {
        $exe = $editor; $editorArgs = @()
        if (-not (Test-Path -LiteralPath $editor)) {
            $tokens = @([regex]::Matches($editor, '"[^"]*"|\S+') | ForEach-Object { $_.Value.Trim('"') })
            $exe = $tokens[0]
            if ($tokens.Count -gt 1) { $editorArgs = @($tokens[1..($tokens.Count - 1)]) }
        }
        try {
            Write-PstStatus info (L 'Ouverture dans {0}...' $exe)
            & $exe @editorArgs $File
            return
        }
        catch { Write-PstStatus warn (L 'Impossible de lancer l''éditeur « {0} » : {1}' $exe $_.Exception.Message) }
    }
    $code = Get-Command code -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($code) {
        Write-PstStatus info (L 'Ouverture dans {0}...' 'VS Code')
        & $code.Source $File
        return
    }
    if ($script:Pst.IsWindows) {
        try { Start-Process notepad.exe -ArgumentList "`"$File`"" -ErrorAction Stop; Write-PstStatus info (L 'Ouverture dans {0}...' 'notepad'); return }
        catch { $null = $_ }
    }
    Write-PstStatus info (L 'Aucun éditeur trouvé (définissez $env:EDITOR). Fichier du jour :')
    Write-Output $File
}

# ── Point d'entrée ───────────────────────────────────────────────────────────

$words = @(@($Text) + @($Rest) | Where-Object { $null -ne $_ -and $_ -ne '' })
$body = ($words -join ' ')
$pipedText = (@($piped | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) -join "`n")
if ($pipedText.Trim()) {
    if ($body) { $body = $body + "`n" + $pipedText } else { $body = $pipedText }
}

if ($Path) { Write-Output (Get-DayFile (Get-Date)); exit 0 }

if ($Today -or $Edit) {
    $file = Initialize-DayFile (Get-Date)
    if ($body.Trim()) { $null = Add-Note $body }
    Open-InEditor $file
    exit 0
}

if ($body.Trim()) {
    Show-PstHeader -Tool 'note'
    if (-not (Add-Note $body)) { exit 1 }
    Write-Host ''
    exit 0
}

if ($Search) {
    $pattern = [regex]::Escape($Search.Trim())
    $rx = New-Object regex $pattern, ([Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $hits = @()
    foreach ($f in @(Get-DayFiles)) {
        foreach ($e in @(Read-DayNotes $f.File)) {
            if ($rx.IsMatch($e.Text)) { $hits += @{ Date = $f.Date; Entry = $e } }
        }
    }
    if ($Json) { Write-Output (ConvertTo-Json -InputObject @($hits | ForEach-Object { ConvertTo-NoteJson $_.Date $_.Entry }) -Depth 3); exit 0 }
    Show-PstHeader -Tool 'note' -Subtitle (L 'recherche')
    if ($hits.Count -eq 0) { Write-PstStatus info (L 'Aucune note ne contient « {0} ».' $Search); Write-Host ''; exit 0 }
    $day = $null
    foreach ($h in $hits) {
        if ($h.Date -ne $day) {
            if ($null -ne $day) { Write-Host '' }
            $day = $h.Date
            Write-Host ('  ' + (Get-DayTitle $day))
        }
        Write-NoteEntry $h.Entry -Pattern ('(?i)' + $pattern)
    }
    Write-Host ''
    Write-Host ('  ' + (Paint (L '{0} note(s) trouvée(s) pour « {1} ».' $hits.Count $Search) 'Dim'))
    Write-Host ''
    exit 0
}

if ($List) {
    $dayList = @(Get-DayFiles | ForEach-Object { @{ Date = $_.Date; Notes = @(Read-DayNotes $_.File); File = $_.File } })
    if ($Json) {
        Write-Output (ConvertTo-Json -InputObject @($dayList | ForEach-Object { [ordered]@{ date = $_.Date.ToString('yyyy-MM-dd', $inv); count = $_.Notes.Count; file = $_.File } }) -Depth 3)
        exit 0
    }
    Show-PstHeader -Tool 'note' -Subtitle (L 'jours')
    if ($dayList.Count -eq 0) { Write-PstStatus info (L 'Aucune note pour l''instant. Essayez : note "Ma première note"'); Write-Host ''; exit 0 }
    $max = 1
    foreach ($d in $dayList) { $max = [Math]::Max($max, $d.Notes.Count) }
    $rows = @()
    foreach ($d in $dayList) {
        $first = ''
        if ($d.Notes.Count) { $first = Limit-PstText (($d.Notes[0].Text -split "`n")[0]) 36 }
        $rows += , @($d.Date.ToString((L 'ddd d MMM yyyy'), (Get-PstCulture)), [string]$d.Notes.Count, (Format-PstBar ($d.Notes.Count * 100 / $max) -Width 12 -Color 'Accent'), (Paint $first 'Dim'))
    }
    Format-PstTable -Columns @(
        @{ Name = (L 'Jour'); Width = 18 }, @{ Name = (L 'Notes'); Width = 5; Right = $true },
        @{ Name = ''; Width = 12 }, @{ Name = (L 'Première note'); Width = 36 }
    ) -Rows $rows | ForEach-Object { Write-Host "  $_" }
    $total = 0
    foreach ($d in $dayList) { $total += $d.Notes.Count }
    Write-Host ''
    Write-Host ('  ' + (Paint (L '{0} note(s) sur {1} jour(s) · {2}' $total $dayList.Count $notesDir) 'Dim'))
    Write-Host ''
    exit 0
}

# Sans argument : les dernières notes.
$recent = @(Show-RecentNotes $Days)
if ($Json) {
    $flat = @()
    foreach ($d in $recent) { foreach ($e in $d.Notes) { $flat += ConvertTo-NoteJson $d.Date $e } }
    Write-Output (ConvertTo-Json -InputObject $flat -Depth 3)
    exit 0
}
Show-PstHeader -Tool 'note' -Subtitle (L 'dernières notes')
if ($recent.Count -eq 0) {
    Write-PstStatus info (L 'Aucune note pour l''instant. Essayez : note "Ma première note"')
    Write-Host ''
    exit 0
}
$first = $true
foreach ($d in $recent) {
    if (-not $first) { Write-Host '' }
    $first = $false
    Write-Host ('  ' + (Get-DayTitle $d.Date))
    foreach ($e in $d.Notes) { Write-NoteEntry $e }
}
Write-Host ''
Write-Host ('  ' + (Paint (L 'note -Search <mot> pour chercher · note -Edit pour ouvrir la page du jour') 'Dim'))
Write-Host ''
exit 0
