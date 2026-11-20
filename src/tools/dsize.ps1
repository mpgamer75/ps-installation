<#
.SYNOPSIS
    dsize — où est passé l'espace disque ? (équivalent de « du -sh * | sort -h »)
.DESCRIPTION
    Mesure la taille de chaque élément d'un dossier. Les dossiers inaccessibles
    sans droits administrateur sont comptés à part, sans interrompre l'analyse.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path = '.',
    [ValidateRange(1, 200)][int]$Top = 15,
    [switch]$Files,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'dsize'

if ($Help -or (Test-PstHelpArg (@($Path) + @($Rest)))) {
    Show-PstHelp -Name 'dsize' -Synopsis (L 'Classe le contenu d''un dossier par taille.') `
        -Usage @(L 'dsize [dossier] [-Top <n>] [-Files] [-Json]') `
        -Options @(
            @((L 'dossier'), (L 'Dossier à analyser (défaut : dossier courant)')),
            @('-Top <n>', (L 'Nombre de lignes affichées (défaut : 15)')),
            @('-Files', (L 'Liste les plus gros fichiers, tous sous-dossiers confondus')),
            @('-Json', (L 'Sortie JSON, pour les scripts'))
        ) `
        -Examples @('dsize', (L 'dsize C:\Users\moi -Top 25'), (L 'dsize D:\Projets -Files'))
    exit 0
}

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-PstStatus err (L 'Dossier introuvable : {0}' $Path)
    exit 1
}
$root = (Resolve-Path -LiteralPath $Path).ProviderPath

$stats = @{ Denied = 0; Files = 0 }
$biggest = New-Object System.Collections.ArrayList

function Measure-Tree {
    # Somme itérative : pas de récursion, pas d'arrêt sur accès refusé,
    # les liens et jonctions ne sont pas suivis (évite les doubles comptes).
    param([string]$Start)
    $size = 0.0
    $count = 0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Start)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            $entry = New-Object IO.DirectoryInfo $dir
            foreach ($f in $entry.GetFiles()) {
                $size += $f.Length
                $count++
                if ($Files) { Add-Biggest $f }
            }
            foreach ($d in $entry.GetDirectories()) {
                if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $stack.Push($d.FullName)
            }
        }
        catch { $stats.Denied++ }
    }
    $stats.Files += $count
    return @{ Size = $size; Count = $count }
}

function Add-Biggest {
    # Conserve uniquement les -Top plus gros fichiers rencontrés.
    param($File)
    if ($biggest.Count -ge $Top -and $File.Length -le $biggest[$biggest.Count - 1].Size) { return }
    [void]$biggest.Add([pscustomobject]@{ Name = $File.FullName; Size = [double]$File.Length; Count = 1; IsDir = $false })
    $sorted = @($biggest | Sort-Object Size -Descending | Select-Object -First $Top)
    $biggest.Clear()
    $biggest.AddRange($sorted)
}

$interactive = (Test-PstInteractive) -and $script:Pst.Ansi -and -not $Json
$items = New-Object System.Collections.ArrayList
$rootInfo = New-Object IO.DirectoryInfo $root
$looseSize = 0.0
$looseCount = 0

try {
    foreach ($f in $rootInfo.GetFiles()) {
        $stats.Files++
        if ($Files) { Add-Biggest $f }
        else { [void]$items.Add([pscustomobject]@{ Name = $f.Name; Size = [double]$f.Length; Count = 1; IsDir = $false }) }
        $looseSize += $f.Length; $looseCount++
    }
    foreach ($d in $rootInfo.GetDirectories()) {
        if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ($interactive) { Write-Host ("  $(Paint $script:Pst.Glyph.Pointer 'Accent') " + (L 'Analyse : {0}' (Limit-PstText $d.Name 50)) + "$($script:Pst.Esc)[K`r") -NoNewline }
        $m = Measure-Tree $d.FullName
        [void]$items.Add([pscustomobject]@{ Name = $d.Name; Size = $m.Size; Count = $m.Count; IsDir = $true })
    }
}
catch {
    Write-PstStatus err (L 'Lecture impossible : {0}' $_.Exception.Message)
    exit 1
}
if ($interactive) { Write-Host "$($script:Pst.Esc)[K" -NoNewline }

$total = $looseSize
foreach ($i in $items) { if ($i.IsDir) { $total += $i.Size } }

if ($Files) { $ranked = @($biggest | Sort-Object Size -Descending) }
else { $ranked = @($items | Sort-Object Size -Descending | Select-Object -First $Top) }

if ($Json) {
    [ordered]@{ Path = $root; TotalBytes = $total; Files = $stats.Files; Denied = $stats.Denied; Items = @($ranked | ForEach-Object { [ordered]@{ Name = $_.Name; Bytes = $_.Size; Files = $_.Count; Directory = $_.IsDir } }) } |
        ConvertTo-Json -Depth 4
    exit 0
}

$g = $script:Pst.Glyph
$width = Get-PstWidth -Max 100
$mode = L 'contenu'
if ($Files) { $mode = L 'plus gros fichiers' }
Show-PstHeader -Tool 'dsize' -Subtitle $mode
Write-Host ('  ' + (Paint (Limit-PstText $root ($width - 30)) 'Title' -Bold) + (Paint ('  ' + (L '{0} {1} {0} {2} fichier(s)' $g.Dot (Format-PstSize $total) $stats.Files)) 'Dim'))
Write-Host ''

if ($ranked.Count -eq 0) { Write-PstStatus info (L 'Dossier vide.'); Write-Host ''; exit 0 }

$nameW = [Math]::Max(20, $width - 50)
$rows = @()
foreach ($r in $ranked) {
    $pct = 0
    if ($total -gt 0) { $pct = $r.Size / $total * 100 }
    $name = $r.Name
    if ($Files -and $name.StartsWith($root)) { $name = $name.Substring($root.Length).TrimStart('\', '/') }
    if ($name.Length -gt $nameW) { $name = $g.Ellipsis + $name.Substring($name.Length - $nameW + 1) }
    if ($r.IsDir) { $name = Paint ($name) 'Accent' }
    $rows += , @((Format-PstSize $r.Size), (Format-PstBar $pct 18 -Color 'Accent2'), ('{0,5:N1} %' -f $pct), $name)
}
Format-PstTable -Columns @(
    @{ Name = (L 'Taille'); Width = 10; Right = $true }, @{ Name = ''; Width = 18 }, @{ Name = (L 'Part'); Width = 7; Right = $true }, @{ Name = (L 'Nom'); Width = $nameW }
) -Rows $rows | ForEach-Object { Write-Host "  $_" }

$hidden = $items.Count - $ranked.Count
Write-Host ''
if (-not $Files -and $hidden -gt 0) { Write-Host (Paint ('  ' + (L '... et {0} autre(s) élément(s) plus petits (-Top pour en voir davantage)' $hidden)) 'Dim') }
if ($stats.Denied -gt 0) {
    if (Test-PstAdmin) { Write-PstStatus warn (L '{0} dossier(s) inaccessible(s) non comptabilisé(s)' $stats.Denied) }
    else { Write-PstStatus warn (L '{0} dossier(s) inaccessible(s) non comptabilisé(s) (un terminal administrateur en lira davantage)' $stats.Denied) }
}
Write-Host ''
