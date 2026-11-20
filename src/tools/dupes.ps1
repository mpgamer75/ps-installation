<#
.SYNOPSIS
    dupes — trouve les fichiers en double et récupère l'espace perdu.
.DESCRIPTION
    Regroupe d'abord les fichiers par taille, puis calcule l'empreinte SHA256
    des seuls fichiers de même taille. Les groupes sont classés par espace
    gaspillé. En mode interactif, vous choisissez la copie à garder pour
    chaque groupe ; les autres partent à la Corbeille après confirmation.
    Les liens et jonctions ne sont pas suivis ; les dossiers inaccessibles
    sont comptés sans interrompre l'analyse.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path = '.',
    [string]$Min,
    [string[]]$Include,
    [string]$Keep = 'oldest',
    [ValidateRange(1, 1000)][int]$Top = 20,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'dupes'

if ($Help -or (Test-PstHelpArg (@($Path) + @($Rest)))) {
    Show-PstHelp -Name 'dupes' -Synopsis (L 'Trouve les fichiers en double (même contenu) et libère l''espace perdu.') `
        -Usage @((L 'dupes [dossier] [-Min <taille>] [-Include <motifs>] [-Keep oldest|newest|shortest] [-DryRun] [-Yes] [-Json]')) `
        -Options @(
            @((L 'dossier'), (L 'Dossier à analyser, sous-dossiers compris (défaut : dossier courant)')),
            @((L '-Min <taille>'), (L 'Taille minimale, ex. : 1MB, 500K, 2Go (défaut : 1 octet)')),
            @((L '-Include <motifs>'), (L 'Motifs de fichiers, ex. : *.jpg,*.png')),
            @((L '-Keep <règle>'), (L 'Copie gardée par défaut : oldest (plus ancienne), newest, shortest')),
            @('-Top <n>', (L 'Nombre de groupes affichés (défaut : 20)')),
            @('-DryRun', (L 'Affiche ce qui serait supprimé, sans rien toucher')),
            @('-Yes', (L 'Supprime sans question en gardant la copie par défaut')),
            @('-Json', (L 'Sortie JSON, pour les scripts (aucune suppression)'))
        ) `
        -Examples @('dupes', 'dupes D:\Photos -Include *.jpg,*.heic', 'dupes $HOME\Downloads -Min 1MB -DryRun', (L 'dupes . -Json | ask "lesquels supprimer ?"')) `
        -Notes @(
            (L 'Copie gardée par défaut : la plus ancienne, puis le chemin le plus court.'),
            (L 'Les fichiers supprimés partent à la Corbeille (suppression définitive hors Windows).')
        )
    exit 0
}

# ── Tailles ──────────────────────────────────────────────────────────────────

function ConvertFrom-DupesSize {
    # « 1MB », « 500K », « 2Go », « 1,5 Mo », « 1048576 » → octets ; $null si invalide.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = ($Text.Trim() -replace ',', '.' -replace '\s+', '').ToLowerInvariant()
    if ($t -notmatch '^(\d+(?:\.\d+)?)([kmgt]?)(?:b|o|io|ib|ob)?$') { return $null }
    $n = [double]$Matches[1]
    switch ($Matches[2]) {
        'k' { $n *= 1KB }
        'm' { $n *= 1MB }
        'g' { $n *= 1GB }
        't' { $n *= 1TB }
    }
    return [int64][Math]::Round($n)
}

$minBytes = 1
if ($Min) {
    $minBytes = ConvertFrom-DupesSize $Min
    if ($null -eq $minBytes) { Write-PstStatus err (L 'Taille invalide : « {0} » (ex. : 1MB, 500K).' $Min); exit 1 }
    if ($minBytes -lt 1) { $minBytes = 1 }
}
$rule = $Keep.Trim().ToLowerInvariant()
if ($rule -in 'ancien', 'ancienne', 'old') { $rule = 'oldest' }
elseif ($rule -in 'recent', 'récent', 'récente', 'new') { $rule = 'newest' }
elseif ($rule -in 'court', 'short') { $rule = 'shortest' }
if ($rule -notin 'oldest', 'newest', 'shortest') { Write-PstStatus err (L 'Règle inconnue : « {0} » (oldest, newest ou shortest).' $Keep); exit 1 }
if ($Rest.Count) { Write-PstStatus err (L 'Argument inattendu : {0}' ($Rest -join ' ')); exit 1 }
$patterns = @($Include | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-PstStatus err (L 'Dossier introuvable : {0}' $Path); exit 1 }
$root = (Resolve-Path -LiteralPath $Path).ProviderPath

# ── Parcours et empreintes ───────────────────────────────────────────────────

$stats = @{ Files = 0; Denied = 0; Unreadable = 0; Hashed = 0 }

function Get-DupesFiles {
    # Parcours itératif : pas d'arrêt sur accès refusé, liens et jonctions ignorés.
    param([string]$Start)
    $list = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($Start)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            $info = New-Object IO.DirectoryInfo $dir
            foreach ($f in $info.GetFiles()) {
                if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                if ($f.Length -lt $minBytes) { continue }
                if ($patterns.Count) {
                    $ok = $false
                    foreach ($p in $patterns) { if ($f.Name -like $p) { $ok = $true; break } }
                    if (-not $ok) { continue }
                }
                [void]$list.Add($f)
            }
            foreach ($d in $info.GetDirectories()) {
                if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($d.FullName)
            }
        }
        catch { $stats.Denied++ }
    }
    $stats.Files = $list.Count
    return , $list
}

function Get-DupesHash {
    param([string]$File)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '') }
        finally { $stream.Dispose() }
    }
    catch { return $null }
    finally { $sha.Dispose() }
}

function Select-DupesKeeper {
    # Index de la copie à garder selon la règle ; égalité départagée par le chemin le plus court.
    param([object[]]$Files, [string]$Rule)
    switch ($Rule) {
        'newest' { $sorted = @($Files | Sort-Object @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true }, @{ Expression = { $_.FullName.Length } }, FullName) }
        'shortest' { $sorted = @($Files | Sort-Object @{ Expression = { $_.FullName.Length } }, LastWriteTimeUtc, FullName) }
        default { $sorted = @($Files | Sort-Object LastWriteTimeUtc, @{ Expression = { $_.FullName.Length } }, FullName) }
    }
    return [array]::IndexOf($Files, $sorted[0])
}

$progress = $script:Pst.Ansi -and -not $Json
if ($progress) { Write-Host ("  $(Paint $script:Pst.Glyph.Pointer 'Accent') " + (L 'Analyse des fichiers...') + "$($script:Pst.Esc)[K`r") -NoNewline }
$all = Get-DupesFiles $root

$groups = New-Object System.Collections.ArrayList
$sameSize = @($all | Group-Object Length | Where-Object { $_.Count -gt 1 })
$toHash = 0
foreach ($s in $sameSize) { $toHash += $s.Count }
foreach ($s in $sameSize) {
    $byHash = @{}
    foreach ($f in $s.Group) {
        if ($progress) { Write-Host ("  $(Paint $script:Pst.Glyph.Pointer 'Accent') " + (L 'Empreintes : {0}/{1}' ($stats.Hashed + 1) $toHash) + "$($script:Pst.Esc)[K`r") -NoNewline }
        $stats.Hashed++
        $h = Get-DupesHash $f.FullName
        if (-not $h) { $stats.Unreadable++; continue }
        if (-not $byHash.ContainsKey($h)) { $byHash[$h] = New-Object System.Collections.ArrayList }
        [void]$byHash[$h].Add($f)
    }
    foreach ($h in $byHash.Keys) {
        $copies = @($byHash[$h] | Sort-Object FullName)
        if ($copies.Count -lt 2) { continue }
        $size = [double]$copies[0].Length
        [void]$groups.Add([pscustomobject]@{
                Hash = $h; Size = $size; Files = $copies; Wasted = $size * ($copies.Count - 1)
                Keep = (Select-DupesKeeper $copies $rule)
            })
    }
}
if ($progress) { Write-Host "$($script:Pst.Esc)[K" -NoNewline }
$groups = @($groups | Sort-Object @{ Expression = { $_.Wasted }; Descending = $true }, Hash)
$reclaim = 0.0
foreach ($grp in $groups) { $reclaim += $grp.Wasted }

if ($Json) {
    [ordered]@{
        Path = $root; FilesScanned = $stats.Files; Denied = $stats.Denied; Unreadable = $stats.Unreadable
        ReclaimableBytes = [int64]$reclaim; Groups = @($groups | ForEach-Object {
                $grp = $_
                [ordered]@{
                    Sha256 = $grp.Hash; Bytes = [int64]$grp.Size; Copies = $grp.Files.Count; WastedBytes = [int64]$grp.Wasted
                    Files = @(for ($i = 0; $i -lt $grp.Files.Count; $i++) {
                            [ordered]@{ Path = $grp.Files[$i].FullName; Modified = $grp.Files[$i].LastWriteTime.ToString('s'); Keep = ($i -eq $grp.Keep) }
                        })
                }
            })
    } | ConvertTo-Json -Depth 6
    exit 0
}

# ── Rapport ──────────────────────────────────────────────────────────────────

$g = $script:Pst.Glyph
$width = Get-PstWidth -Max 110
$subtitle = L 'doublons'
if ($DryRun) { $subtitle += " $($g.Dot) " + (L 'simulation') }
Show-PstHeader -Tool 'dupes' -Subtitle $subtitle
Write-Host ('  ' + (Paint (Limit-PstText $root ($width - 40)) 'Title' -Bold) + (Paint ("  $($g.Dot) " + (L '{0} fichier(s) examiné(s)' $stats.Files)) 'Dim'))
Write-Host ''

function Write-DupesWarnings {
    if ($stats.Denied) { Write-PstStatus warn (L '{0} dossier(s) inaccessible(s) ignoré(s).' $stats.Denied) }
    if ($stats.Unreadable) { Write-PstStatus warn (L '{0} fichier(s) illisible(s) ignoré(s) (ouverts ou protégés).' $stats.Unreadable) }
}

function Format-DupesPath {
    param([string]$Full, [int]$Max)
    $rel = $Full
    if ($rel.StartsWith($root)) { $rel = $rel.Substring($root.Length).TrimStart('\', '/') }
    if ($rel.Length -gt $Max) { $rel = $g.Ellipsis + $rel.Substring($rel.Length - $Max + 1) }
    return $rel
}

if (-not $groups.Count) {
    Write-PstStatus ok (L 'Aucun doublon trouvé.')
    Write-DupesWarnings
    Write-Host ''; exit 0
}

$pathW = [Math]::Max(24, $width - 30)
$shown = @($groups | Select-Object -First $Top)
foreach ($grp in $shown) {
    $title = L '{0} copies de {1} {2} {3} perdus' $grp.Files.Count (Format-PstSize $grp.Size) $g.Dot (Format-PstSize $grp.Wasted)
    $lines = @()
    for ($i = 0; $i -lt $grp.Files.Count; $i++) {
        $f = $grp.Files[$i]
        $date = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        if ($i -eq $grp.Keep) { $mark = (Paint $g.Ok 'Ok' -Bold) + ' ' + (Paint (Format-PstPad (L 'garder') 9) 'Ok') }
        else { $mark = (Paint $g.Err 'Err') + ' ' + (Paint (Format-PstPad (L 'supprimer') 9) 'Dim') }
        $lines += $mark + ' ' + (Paint $date 'Dim') + '  ' + (Format-DupesPath $f.FullName $pathW)
    }
    Format-PstBox -Title $title -Lines $lines -Width $width | Write-PstLine
}
if ($groups.Count -gt $shown.Count) { Write-Host (Paint ('  ' + (L '... et {0} autre(s) groupe(s) (-Top pour en voir davantage)' ($groups.Count - $shown.Count))) 'Dim') }
Write-Host ''
$copies = 0
foreach ($grp in $groups) { $copies += $grp.Files.Count - 1 }
Write-PstStatus info (L '{0} groupe(s) de doublons {1} {2} copie(s) en trop {1} {3} récupérables' $groups.Count $g.Dot $copies (Format-PstSize $reclaim))
Write-DupesWarnings
Write-Host ''

if ($DryRun) { Write-PstStatus info (L 'Simulation : aucun fichier supprimé.'); Write-Host ''; exit 0 }

# ── Choix et suppression ─────────────────────────────────────────────────────

if (-not $Yes) {
    if (-not (Test-PstInteractive)) { Write-PstStatus warn (L 'Session non interactive : ajoutez -Yes pour supprimer (copie par défaut gardée).'); Write-Host ''; exit 0 }
    $how = Read-PstChoice -Title (L 'Que faire des doublons ?') -Items @(
        (L 'Choisir la copie à garder, groupe par groupe'),
        (L 'Garder la copie proposée partout'),
        (L 'Ne rien supprimer')
    ) -Default 0
    if ($how -lt 0 -or $how -eq 2) { Write-PstStatus info (L 'Annulé, rien n''a été supprimé.'); exit 0 }
    if ($how -eq 0) {
        $n = 0
        foreach ($grp in $groups) {
            $n++
            Write-Host ''
            $items = @($grp.Files | ForEach-Object { Format-DupesPath $_.FullName ($pathW - 20) })
            $hints = @($grp.Files | ForEach-Object { $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') })
            $items += L 'Garder toutes les copies'
            $hints += ''
            $pick = Read-PstChoice -Title (L 'Groupe {0}/{1} {2} {3} : quelle copie garder ?' $n $groups.Count $g.Dot (Format-PstSize $grp.Size)) -Items $items -Hints $hints -Default $grp.Keep
            if ($pick -lt 0 -or $pick -ge $grp.Files.Count) { $grp.Keep = -1 } else { $grp.Keep = $pick }
        }
    }
}

$victims = New-Object System.Collections.ArrayList
$planned = 0.0
foreach ($grp in $groups) {
    if ($grp.Keep -lt 0) { continue }
    for ($i = 0; $i -lt $grp.Files.Count; $i++) {
        if ($i -ne $grp.Keep) { [void]$victims.Add(@{ File = $grp.Files[$i]; Keeper = $grp.Files[$grp.Keep] }); $planned += $grp.Size }
    }
}
if (-not $victims.Count) { Write-PstStatus info (L 'Rien à supprimer.'); Write-Host ''; exit 0 }

$useBin = $script:Pst.IsWindows
$verb = L 'Envoyer {0} fichier(s) ({1}) à la Corbeille ?' $victims.Count (Format-PstSize $planned)
if (-not $useBin) { $verb = L 'Supprimer définitivement {0} fichier(s) ({1}) ?' $victims.Count (Format-PstSize $planned) }
if (-not $Yes) {
    Write-Host ''
    if (-not (Read-PstConfirm $verb)) { Write-PstStatus info (L 'Annulé, rien n''a été supprimé.'); exit 0 }
}

if ($useBin) { try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch { $useBin = $false } }
$freed = 0.0; $removed = 0; $failed = 0
foreach ($v in $victims) {
    $f = $v.File
    # Sécurité : la copie gardée doit toujours exister, et le fichier ne doit pas avoir changé.
    $f.Refresh(); $v.Keeper.Refresh()
    if (-not $v.Keeper.Exists -or -not $f.Exists -or $f.Length -ne $v.Keeper.Length) { $failed++; continue }
    try {
        if ($useBin) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($f.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin') }
        else { [IO.File]::Delete($f.FullName) }
        $freed += $f.Length; $removed++
    }
    catch { $failed++ }
}

Write-Host ''
$summary = @((Paint (L '{0} fichier(s) supprimé(s) {1} {2} libérés' $removed $g.Dot (Format-PstSize $freed)) 'Ok' -Bold))
if ($useBin) { $summary += Paint (L 'Récupérables depuis la Corbeille.') 'Dim' }
if ($failed) { $summary += Paint (L '{0} fichier(s) conservé(s) (modifiés, ouverts ou protégés)' $failed) 'Warn' }
Format-PstBox -Title (L 'Doublons supprimés') -Lines $summary -Width 60 -Color 'Ok' | Write-PstLine
Write-Host ''
if ($failed -and -not $removed) { exit 1 }
exit 0
