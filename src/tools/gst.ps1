<#
.SYNOPSIS
    gst — tableau de bord Git du dépôt courant : branche, synchronisation, modifications, historique.
.DESCRIPTION
    Lecture seule : ne modifie jamais le dépôt. Nécessite git dans le PATH.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path = '.',
    [ValidateRange(1, 50)][int]$Commits = 6,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')

if ($Help -or (Test-PstHelpArg (@($Path) + @($Rest)))) {
    Show-PstHelp -Name 'gst' -Synopsis 'L''état d''un dépôt Git en un coup d''œil.' `
        -Usage @('gst [dossier] [-Commits <n>]') `
        -Options @(@('dossier', 'Dépôt à inspecter (défaut : dossier courant)'), @('-Commits <n>', 'Nombre de commits récents (défaut : 6)')) `
        -Examples @('gst', 'gst D:\Projets\api -Commits 12')
    exit 0
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-PstStatus err 'git est introuvable. Installation : winget install Git.Git'
    exit 1
}
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-PstStatus err "Dossier introuvable : $Path"; exit 1 }

function Invoke-Git {
    # Sans pagination ni couleurs, messages d'erreur ignorés. Les appelants enveloppent le résultat
    # dans @( ) : une seule ligne de sortie reviendrait sinon comme une simple chaîne.
    $out = & git -C $Path -c core.quotepath=false --no-pager @args 2>$null
    return @($out)
}

$top = (Invoke-Git rev-parse --show-toplevel) | Select-Object -First 1
if (-not $top) { Write-PstStatus info 'Ce dossier n''est pas dans un dépôt Git.'; exit 1 }

$g = $script:Pst.Glyph
$status = @(Invoke-Git status --porcelain=v2 --branch)
$branch = '(détachée)'; $upstream = ''; $ahead = 0; $behind = 0
$staged = @(); $unstaged = @(); $untracked = @(); $conflicts = @()
foreach ($line in $status) {
    if ($line -match '^# branch\.head (.+)$') { $branch = $Matches[1] }
    elseif ($line -match '^# branch\.upstream (.+)$') { $upstream = $Matches[1] }
    elseif ($line -match '^# branch\.ab \+(\d+) -(\d+)$') { $ahead = [int]$Matches[1]; $behind = [int]$Matches[2] }
    elseif ($line -match '^[12] (.)(.) ') {
        $x = $Matches[1]; $y = $Matches[2]
        $parts = $line -split ' '
        $skip = 8; if ($line.StartsWith('2')) { $skip = 9 }
        $file = (($parts[$skip..($parts.Count - 1)] -join ' ') -split "`t")[0]
        if ($x -ne '.') { $staged += [pscustomobject]@{ Code = $x; File = $file } }
        if ($y -ne '.') { $unstaged += [pscustomobject]@{ Code = $y; File = $file } }
    }
    elseif ($line -match '^u ') { $conflicts += (($line -split ' ')[10..100] -join ' ') }
    elseif ($line -match '^\? (.+)$') { $untracked += $Matches[1] }
}
if ($branch -eq '(detached)') { $branch = '(détachée)' }

$width = Get-PstWidth -Max 100
Show-PstHeader -Tool 'gst' -Subtitle (Split-Path -Leaf $top)

# Branche et synchronisation
$sync = Paint 'aucune branche distante suivie' 'Dim'
if ($upstream) {
    if ($ahead -eq 0 -and $behind -eq 0) { $sync = Paint "$($g.Ok) à jour" 'Ok' }
    else {
        $bits = @()
        if ($ahead) { $bits += Paint "$($g.Up)$ahead à pousser" 'Accent' }
        if ($behind) { $bits += Paint "$($g.Down)$behind à récupérer" 'Warn' }
        $sync = ($bits -join '  ')
    }
}
$stash = @(Invoke-Git stash list).Count
$head = @(
    ((Paint (Format-PstPad 'Branche' 10) 'Accent') + (Paint (Limit-PstText $branch ($width - 16)) 'Title' -Bold)),
    ((Paint (Format-PstPad 'Distant' 10) 'Accent') + $sync)
)
if ($stash) { $head += (Paint (Format-PstPad 'Remises' 10) 'Accent') + "$stash en attente (git stash list)" }
Format-PstBox -Lines $head -Width $width | Write-PstLine

# Modifications
function Format-Change {
    param([string]$Code, [string]$File, $Color)
    $label = switch ($Code) { 'M' { 'modifié ' } 'A' { 'ajouté  ' } 'D' { 'supprimé' } 'R' { 'renommé ' } 'C' { 'copié   ' } 'T' { 'type    ' } default { $Code.PadRight(8) } }
    return (Paint $label $Color) + '  ' + (Limit-PstText $File ($width - 18))
}
$changes = @()
foreach ($c in $conflicts) { $changes += (Paint 'CONFLIT ' 'Err' -Bold) + '  ' + (Limit-PstText $c ($width - 18)) }
if ($staged.Count) { $changes += Paint "Prêt à valider ($($staged.Count))" 'Ok' -Bold; foreach ($s in @($staged | Select-Object -First 12)) { $changes += '  ' + (Format-Change $s.Code $s.File 'Ok') } }
if ($unstaged.Count) { $changes += Paint "Non indexé ($($unstaged.Count))" 'Warn' -Bold; foreach ($s in @($unstaged | Select-Object -First 12)) { $changes += '  ' + (Format-Change $s.Code $s.File 'Warn') } }
if ($untracked.Count) { $changes += Paint "Non suivi ($($untracked.Count))" 'Dim' -Bold; foreach ($u in @($untracked | Select-Object -First 8)) { $changes += '  ' + (Paint 'nouveau ' 'Dim') + '  ' + (Limit-PstText $u ($width - 18)) } }
$hidden = [Math]::Max(0, $staged.Count - 12) + [Math]::Max(0, $unstaged.Count - 12) + [Math]::Max(0, $untracked.Count - 8)
if ($hidden) { $changes += Paint "... et $hidden autre(s)" 'Dim' }
if ($changes.Count -eq 0) { $changes = @(Paint "$($g.Ok) Arbre de travail propre" 'Ok') }
Format-PstBox -Title 'Modifications' -Lines $changes -Width $width | Write-PstLine

# Résumé chiffré du diff
$stat = @(Invoke-Git diff --shortstat HEAD)
if ($stat.Count -and $stat[0]) { Write-Host ('  ' + (Paint $stat[0].Trim() 'Dim')) }

# Historique
$sep = [string][char]31
$log = @(Invoke-Git log "-$Commits" "--pretty=format:%h$sep%cr$sep%an$sep%s")
if ($log.Count) {
    $rows = @()
    foreach ($entry in $log) {
        $f = $entry -split $sep
        if ($f.Count -lt 4) { continue }
        $rows += , @((Paint $f[0] 'Accent2'), (Limit-PstText $f[3] ($width - 52)), (Paint (Limit-PstText $f[2] 16) 'Dim'), (Paint (Limit-PstText $f[1] 16) 'Dim'))
    }
    Format-PstBox -Title 'Derniers commits' -Lines (Format-PstTable -Columns @(
            @{ Name = 'Commit'; Width = 9 }, @{ Name = 'Message'; Width = ($width - 52) }, @{ Name = 'Auteur'; Width = 16 }, @{ Name = 'Date'; Width = 16 }
        ) -Rows $rows) -Width $width | Write-PstLine
}
Write-Host ''
