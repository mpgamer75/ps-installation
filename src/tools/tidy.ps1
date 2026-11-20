<#
.SYNOPSIS
    tidy — range un dossier en vrac (par défaut : Téléchargements) par type ou par mois.
.DESCRIPTION
    Trie les fichiers du premier niveau dans des dossiers de catégorie (Images,
    Documents, Vidéos...) ou de mois (2026-11). Les sous-dossiers existants ne
    sont jamais parcourus. Aperçu systématique, confirmation, aucun écrasement
    (« nom (2).ext »), téléchargements inachevés et fichiers ouverts ignorés.
    Chaque rangement est consigné dans un journal : « tidy -Undo » l'annule.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path,
    [string]$By = 'Type',
    [int]$OlderThan = 0,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Undo,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'tidy'

if ($Help -or (Test-PstHelpArg (@($Path) + @($Rest)))) {
    Show-PstHelp -Name 'tidy' -Synopsis (L 'Range un dossier en vrac par type de fichier ou par mois, avec annulation.') `
        -Usage @(
            (L 'tidy [dossier] [-By Type|Date] [-OlderThan <jours>] [-DryRun] [-Yes]'),
            (L 'tidy -Undo [-DryRun] [-Yes]       remet en place le dernier rangement')
        ) `
        -Options @(
            @((L 'dossier'), (L 'Dossier à ranger (défaut : Téléchargements)')),
            @('-By Type|Date', (L 'Par catégorie (défaut) ou par mois de modification (2026-11)')),
            @((L '-OlderThan <jours>'), (L 'Seulement les fichiers non modifiés depuis N jours')),
            @('-DryRun', (L 'Affiche l''aperçu sans rien déplacer')),
            @('-Yes', (L 'Range sans demander de confirmation')),
            @('-Undo', (L 'Annule le dernier rangement (journal dans le dossier de données)')),
            @('-Json', (L 'Plan de rangement en JSON, sans rien déplacer'))
        ) `
        -Examples @('tidy -DryRun', 'tidy', 'tidy D:\Bureau -By Date -OlderThan 30', 'tidy -Undo') `
        -Notes @(
            (L 'Seul le premier niveau est trié : les sous-dossiers existants ne sont pas touchés.'),
            (L 'Jamais d''écrasement : en cas de doublon de nom, « (2) », « (3) »... est ajouté.'),
            (L 'Ignorés : téléchargements en cours (.crdownload, .part, .tmp), fichiers ouverts et cachés.')
        )
    exit 0
}

# ── Catégories ───────────────────────────────────────────────────────────────

$categories = [ordered]@{
    images     = @{ Folder = (L 'Images'); Ext = 'jpg jpeg jfif png gif bmp webp heic heif tif tiff svg ico raw cr2 nef arw dng psd avif' }
    documents  = @{ Folder = (L 'Documents'); Ext = 'pdf doc docx docm odt rtf txt md xls xlsx xlsm ods csv ppt pptx odp epub mobi pages key numbers tex one vsdx' }
    videos     = @{ Folder = (L 'Vidéos'); Ext = 'mp4 mkv avi mov wmv webm flv m4v mpg mpeg 3gp ts' }
    music      = @{ Folder = (L 'Musique'); Ext = 'mp3 wav flac aac ogg oga m4a wma opus aiff aif mid midi' }
    archives   = @{ Folder = (L 'Archives'); Ext = 'zip rar 7z tar gz tgz bz2 xz zst iso img cab' }
    installers = @{ Folder = (L 'Installateurs'); Ext = 'exe msi msix msixbundle appx appxbundle dmg pkg deb rpm apk' }
    code       = @{ Folder = (L 'Code'); Ext = 'ps1 psm1 psd1 py js mjs ts jsx tsx json xml yml yaml toml ini html htm css scss c h cpp hpp cs java kt go rs rb php sh bat cmd sql ipynb lua swift vue' }
    other      = @{ Folder = (L 'Autres'); Ext = '' }
}
$extMap = @{}
foreach ($id in $categories.Keys) {
    foreach ($e in ($categories[$id].Ext -split ' ')) { if ($e) { $extMap[".$e"] = $id } }
}
# Téléchargements inachevés : jamais déplacés (le navigateur écrit encore dedans).
$partialExt = @('.crdownload', '.part', '.partial', '.tmp', '.download', '.opdownload', '.!ut')

function Get-TidyCategory {
    param([string]$Name)
    $ext = [IO.Path]::GetExtension($Name).ToLowerInvariant()
    if ($extMap.ContainsKey($ext)) { return $extMap[$ext] }
    return 'other'
}

function Get-DownloadsFolder {
    # Dossier Téléchargements réel (il peut avoir été déplacé, ex. sur D:).
    if ($script:Pst.IsWindows) {
        try {
            $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
            $raw = (Get-ItemProperty -LiteralPath $key -Name '{374DE290-123F-4565-9164-39C4925E467B}' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
            if ($raw) {
                $dir = [Environment]::ExpandEnvironmentVariables([string]$raw)
                if (Test-Path -LiteralPath $dir -PathType Container) { return $dir }
            }
        }
        catch { $null = $_ }
    }
    return (Join-Path $HOME 'Downloads')
}

function Test-TidyRoot {
    # Refuse les racines de lecteur et les dossiers système.
    param([string]$Root)
    try { $full = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') } catch { return $false }
    if ($full.Length -le 3) { return $false }
    $forbidden = @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, $env:SystemDrive, $env:APPDATA, $env:LOCALAPPDATA, (Get-PstDataDir)) |
        Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\', '/') }
    foreach ($f in $forbidden) { if ($full -ieq $f) { return $false } }
    return $true
}

function Test-FileInUse {
    # Un fichier qu'on ne peut pas ouvrir en exclusivité est en cours d'utilisation.
    param([string]$File)
    try {
        $stream = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        $stream.Close()
        return $false
    }
    catch { return $true }
}

function Get-FreeName {
    # « photo.jpg » → « photo (2).jpg », « photo (3).jpg »... jusqu'à un nom libre.
    param([string]$Dir, [string]$Name)
    $target = Join-Path $Dir $Name
    if (-not (Test-Path -LiteralPath $target)) { return $target }
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $ext = [IO.Path]::GetExtension($Name)
    $n = 2
    while ($true) {
        $target = Join-Path $Dir ('{0} ({1}){2}' -f $base, $n, $ext)
        if (-not (Test-Path -LiteralPath $target)) { return $target }
        $n++
    }
}

# ── Journal d'annulation ─────────────────────────────────────────────────────

$journalFile = Join-Path (Get-PstDataDir) 'tidy-journal.json'

function Get-TidyJournal {
    $data = Read-PstJsonFile $journalFile
    if ($null -eq $data) { return @() }
    return @(@($data) | Where-Object { $_ -is [hashtable] -and $_.moves })
}

function Save-TidyJournal {
    param([object[]]$Runs)
    # On garde les 20 derniers rangements.
    $keep = @($Runs | Select-Object -Last 20)
    $json = ConvertTo-Json -InputObject $keep -Depth 6
    if (-not $keep.Count) { $json = '[]' }
    [IO.File]::WriteAllText($journalFile, $json, (New-Object Text.UTF8Encoding $false))
}

function Format-TidyTable {
    param([object[]]$Rows, [string]$FirstColumn)
    $out = @()
    foreach ($r in $Rows) { $out += , @($r.Label, [string]$r.Count, (Format-PstSize $r.Size)) }
    return Format-PstTable -Columns @(
        @{ Name = $FirstColumn; Width = 22 }, @{ Name = (L 'Fichiers'); Width = 8; Right = $true }, @{ Name = (L 'Taille'); Width = 10; Right = $true }
    ) -Rows $out
}

function Confirm-Tidy {
    # Vrai si l'on peut agir : -Yes, ou confirmation en session interactive.
    param([string]$Question, [string]$FlagHint)
    if ($Yes) { return $true }
    if (-not (Test-PstInteractive)) { Write-PstStatus warn $FlagHint; Write-Host ''; exit 0 }
    return (Read-PstConfirm $Question -DefaultYes)
}

# ── Annulation ───────────────────────────────────────────────────────────────

if ($Undo) {
    $runs = @(Get-TidyJournal)
    Show-PstHeader -Tool 'tidy' -Subtitle (L 'annulation')
    if (-not $runs.Count) { Write-PstStatus info (L 'Aucun rangement à annuler.'); Write-Host ''; exit 0 }
    $last = $runs[$runs.Count - 1]
    $moves = @($last.moves)
    $when = $last.date
    try { $when = ([DateTime]::ParseExact([string]$last.date, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)).ToString((L 'dddd d MMMM yyyy à HH:mm'), (Get-PstCulture)) } catch { $null = $_ }
    Write-PstStatus info (L 'Dernier rangement : {0} {1} {2}' $when $script:Pst.Glyph.Dot $last.root)
    $present = @($moves | Where-Object { Test-Path -LiteralPath $_.to -PathType Leaf })
    Write-PstStatus info (L '{0} fichier(s) à remettre en place ({1} introuvable(s)).' $present.Count ($moves.Count - $present.Count))
    Write-Host ''
    if ($DryRun) {
        foreach ($m in ($present | Select-Object -First 15)) { Write-Host ('    ' + (Paint (Split-Path -Leaf $m.to) 'Title') + (Paint "  $($script:Pst.Glyph.Pointer) $($m.from)" 'Dim')) }
        if ($present.Count -gt 15) { Write-Host (Paint ('    ' + (L '... et {0} autre(s)' ($present.Count - 15))) 'Dim') }
        Write-Host ''
        Write-PstStatus info (L 'Simulation : aucun fichier déplacé.'); Write-Host ''; exit 0
    }
    if (-not (Confirm-Tidy (L 'Remettre {0} fichier(s) à leur place ?' $present.Count) (L 'Session non interactive : ajoutez -Yes pour annuler le rangement.'))) {
        Write-PstStatus info (L 'Annulé, rien n''a été déplacé.'); exit 0
    }
    $done = 0; $failed = 0; $renamed = 0
    foreach ($m in $present) {
        try {
            $dir = Split-Path -Parent $m.from
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $target = Get-FreeName $dir (Split-Path -Leaf $m.from)
            if ($target -ne $m.from) { $renamed++ }
            [IO.File]::Move($m.to, $target)
            $done++
        }
        catch { $failed++ }
    }
    # Dossiers créés par le rangement : supprimés s'ils sont restés vides.
    foreach ($d in @($last.created)) {
        try { if ($d -and (Test-Path -LiteralPath $d) -and -not @(Get-ChildItem -LiteralPath $d -Force).Count) { Remove-Item -LiteralPath $d -Force } } catch { $null = $_ }
    }
    if ($failed -eq 0) { $runs = @($runs | Select-Object -First ($runs.Count - 1)) }
    else {
        # Ce qui n'a pas pu revenir reste dans le journal, pour une nouvelle tentative.
        $last.moves = @($moves | Where-Object { Test-Path -LiteralPath $_.to -PathType Leaf })
    }
    Save-TidyJournal $runs
    Write-PstStatus ok (L '{0} fichier(s) remis en place.' $done)
    if ($renamed) { Write-PstStatus info (L '{0} fichier(s) renommé(s) car le nom d''origine était repris.' $renamed) }
    if ($failed) { Write-PstStatus warn (L '{0} fichier(s) non déplacé(s) (ouverts ou protégés) : relancez « tidy -Undo ».' $failed) }
    Write-Host ''
    exit 0
}

# ── Analyse ──────────────────────────────────────────────────────────────────

$mode = $By.Trim().ToLowerInvariant()
if ($mode -in 'type', 'types', 'categorie', 'catégorie', 'category') { $mode = 'type' }
elseif ($mode -in 'date', 'mois', 'month') { $mode = 'date' }
else { Write-PstStatus err (L 'Mode inconnu : « {0} » (Type ou Date).' $By); exit 1 }
if ($Rest.Count) { Write-PstStatus err (L 'Argument inattendu : {0}' ($Rest -join ' ')); exit 1 }

if (-not $Path) { $Path = Get-DownloadsFolder }
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-PstStatus err (L 'Dossier introuvable : {0}' $Path); exit 1 }
$root = (Resolve-Path -LiteralPath $Path).ProviderPath
if (-not (Test-TidyRoot $root)) { Write-PstStatus err (L 'Dossier refusé par sécurité (racine ou dossier système) : {0}' $root); exit 1 }

$limit = $null
if ($OlderThan -gt 0) { $limit = (Get-Date).AddDays(-$OlderThan) }
$plan = New-Object System.Collections.ArrayList
$skip = @{ Partial = 0; InUse = 0; Hidden = 0; Recent = 0 }
try { $files = @((New-Object IO.DirectoryInfo $root).GetFiles()) }
catch { Write-PstStatus err (L 'Lecture impossible : {0}' $_.Exception.Message); exit 1 }

foreach ($f in $files) {
    if ($f.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System) -or $f.Name.StartsWith('.') -or $f.Name -ieq 'desktop.ini') { $skip.Hidden++; continue }
    if ($partialExt -contains $f.Extension.ToLowerInvariant()) { $skip.Partial++; continue }
    if ($limit -and $f.LastWriteTime -gt $limit) { $skip.Recent++; continue }
    if (Test-FileInUse $f.FullName) { $skip.InUse++; continue }
    if ($mode -eq 'date') { $key = $f.LastWriteTime.ToString('yyyy-MM'); $folder = $key }
    else { $key = Get-TidyCategory $f.Name; $folder = $categories[$key].Folder }
    [void]$plan.Add([pscustomobject]@{ Key = $key; Folder = $folder; File = $f })
}

$groups = @()
foreach ($grp in @($plan | Group-Object Key)) {
    $size = 0.0
    foreach ($p in $grp.Group) { $size += $p.File.Length }
    $groups += [pscustomobject]@{ Key = $grp.Name; Label = $grp.Group[0].Folder; Count = $grp.Count; Size = $size }
}
if ($mode -eq 'date') { $groups = @($groups | Sort-Object Key -Descending) }
else {
    $order = @($categories.Keys)
    $groups = @($groups | Sort-Object { [array]::IndexOf($order, $_.Key) })
}

if ($Json) {
    [ordered]@{
        Path = $root; By = $mode
        Groups = @($groups | ForEach-Object { [ordered]@{ Folder = $_.Label; Files = $_.Count; Bytes = $_.Size } })
        Moves = @($plan | ForEach-Object { [ordered]@{ From = $_.File.FullName; Folder = $_.Folder } })
        Skipped = [ordered]@{ Partial = $skip.Partial; InUse = $skip.InUse; Hidden = $skip.Hidden; Recent = $skip.Recent }
    } | ConvertTo-Json -Depth 5
    exit 0
}

$g = $script:Pst.Glyph
$subtitle = L 'par type'
if ($mode -eq 'date') { $subtitle = L 'par mois' }
if ($DryRun) { $subtitle += ' ' + $g.Dot + ' ' + (L 'simulation') }
Show-PstHeader -Tool 'tidy' -Subtitle $subtitle
Write-Host ('  ' + (Paint (Limit-PstText $root ((Get-PstWidth) - 10)) 'Title' -Bold))
Write-Host ''

$skipLines = @()
if ($skip.Partial) { $skipLines += L '{0} téléchargement(s) en cours ignoré(s)' $skip.Partial }
if ($skip.InUse) { $skipLines += L '{0} fichier(s) ouvert(s) ignoré(s)' $skip.InUse }
if ($skip.Recent) { $skipLines += L '{0} fichier(s) récent(s) ignoré(s) (moins de {1} jour(s))' $skip.Recent $OlderThan }
if ($skip.Hidden) { $skipLines += L '{0} fichier(s) caché(s) ou système ignoré(s)' $skip.Hidden }

if (-not $plan.Count) {
    Write-PstStatus ok (L 'Rien à ranger : aucun fichier libre au premier niveau.')
    foreach ($s in $skipLines) { Write-PstStatus info $s }
    Write-Host ''; exit 0
}

$total = 0.0
foreach ($grp in $groups) { $total += $grp.Size }
$firstCol = L 'Destination'
Format-PstBox -Title (L '{0} fichier(s) à ranger {1} {2}' $plan.Count $g.Dot (Format-PstSize $total)) -Lines (Format-TidyTable $groups $firstCol) | Write-PstLine
foreach ($s in $skipLines) { Write-PstStatus info $s }
Write-Host ''

if ($DryRun) { Write-PstStatus info (L 'Simulation : aucun fichier déplacé.'); Write-Host ''; exit 0 }
if (-not (Confirm-Tidy (L 'Ranger {0} fichier(s) dans {1} dossier(s) ?' $plan.Count $groups.Count) (L 'Session non interactive : ajoutez -Yes pour ranger.'))) {
    Write-PstStatus info (L 'Annulé, rien n''a été déplacé.'); exit 0
}

# ── Déplacement ──────────────────────────────────────────────────────────────

$run = [ordered]@{ date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); root = $root; by = $mode; moves = @(); created = @() }
$moves = New-Object System.Collections.ArrayList
$created = New-Object System.Collections.ArrayList
$moved = 0; $renamed = 0; $failed = 0
try {
    foreach ($p in $plan) {
        $dir = Join-Path $root $p.Folder
        try {
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                [void]$created.Add($dir)
            }
            $target = Get-FreeName $dir $p.File.Name
            [IO.File]::Move($p.File.FullName, $target)
            [void]$moves.Add([ordered]@{ from = $p.File.FullName; to = $target })
            $moved++
            if ((Split-Path -Leaf $target) -ne $p.File.Name) { $renamed++ }
        }
        catch { $failed++ }
    }
}
finally {
    # Le journal est écrit même si le rangement est interrompu.
    if ($moves.Count) {
        $run.moves = @($moves)
        $run.created = @($created)
        Save-TidyJournal (@(Get-TidyJournal) + @($run))
    }
}

$summary = @((Paint (L '{0} fichier(s) rangé(s)' $moved) 'Ok' -Bold))
if ($renamed) { $summary += Paint (L '{0} renommé(s) pour ne rien écraser' $renamed) 'Dim' }
if ($failed) { $summary += Paint (L '{0} non déplacé(s) (ouverts ou protégés)' $failed) 'Warn' }
$summary += Paint (L 'Annuler : tidy -Undo') 'Dim'
Format-PstBox -Title (L 'Rangement terminé') -Lines $summary -Width 52 -Color 'Ok' | Write-PstLine
Write-Host ''
if ($failed) { exit 1 }
exit 0
