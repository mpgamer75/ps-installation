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
Import-PstStrings 'gst'

if ($Help -or (Test-PstHelpArg (@($Path) + @($Rest)))) {
    Show-PstHelp -Name 'gst' -Synopsis (L 'L''état d''un dépôt Git en un coup d''œil.') `
        -Usage @(L 'gst [dossier] [-Commits <n>]') `
        -Options @(@((L 'dossier'), (L 'Dépôt à inspecter (défaut : dossier courant)')), @('-Commits <n>', (L 'Nombre de commits récents (défaut : 6)'))) `
        -Examples @('gst', (L 'gst D:\Projets\api -Commits 12'))
    exit 0
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-PstStatus err (L 'git est introuvable. Installation : winget install Git.Git')
    exit 1
}
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-PstStatus err (L 'Dossier introuvable : {0}' $Path); exit 1 }

function Invoke-Git {
    # Sans pagination ni couleurs, messages d'erreur ignorés. Les appelants enveloppent le résultat
    # dans @( ) : une seule ligne de sortie reviendrait sinon comme une simple chaîne.
    $out = & git -C $Path -c core.quotepath=false --no-pager @args 2>$null
    return @($out)
}

$top = (Invoke-Git rev-parse --show-toplevel) | Select-Object -First 1
if (-not $top) { Write-PstStatus info (L 'Ce dossier n''est pas dans un dépôt Git.'); exit 1 }

$g = $script:Pst.Glyph
$status = @(Invoke-Git status --porcelain=v2 --branch)
$branch = (L '(détachée)'); $upstream = ''; $ahead = 0; $behind = 0
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
if ($branch -eq '(detached)') { $branch = (L '(détachée)') }

$width = Get-PstWidth -Max 100
Show-PstHeader -Tool 'gst' -Subtitle (Split-Path -Leaf $top)

# Branche et synchronisation
$sync = Paint (L 'aucune branche distante suivie') 'Dim'
if ($upstream) {
    if ($ahead -eq 0 -and $behind -eq 0) { $sync = Paint (L '{0} à jour' $g.Ok) 'Ok' }
    else {
        $bits = @()
        if ($ahead) { $bits += Paint (L '{0}{1} à pousser' $g.Up $ahead) 'Accent' }
        if ($behind) { $bits += Paint (L '{0}{1} à récupérer' $g.Down $behind) 'Warn' }
        $sync = ($bits -join '  ')
    }
}
$stash = @(Invoke-Git stash list).Count
$head = @(
    ((Paint (Format-PstPad (L 'Branche') 10) 'Accent') + (Paint (Limit-PstText $branch ($width - 16)) 'Title' -Bold)),
    ((Paint (Format-PstPad (L 'Distant') 10) 'Accent') + $sync)
)
if ($stash) { $head += (Paint (Format-PstPad (L 'Remises') 10) 'Accent') + (L '{0} en attente (git stash list)' $stash) }
Format-PstBox -Lines $head -Width $width | Write-PstLine

# Modifications
function Format-Change {
    param([string]$Code, [string]$File, $Color)
    $label = switch ($Code) { 'M' { (L 'modifié').PadRight(8) } 'A' { (L 'ajouté').PadRight(8) } 'D' { (L 'supprimé').PadRight(8) } 'R' { (L 'renommé').PadRight(8) } 'C' { (L 'copié').PadRight(8) } 'T' { (L 'type').PadRight(8) } default { $Code.PadRight(8) } }
    return (Paint $label $Color) + '  ' + (Limit-PstText $File ($width - 18))
}
$changes = @()
foreach ($c in $conflicts) { $changes += (Paint (L 'CONFLIT').PadRight(8) 'Err' -Bold) + '  ' + (Limit-PstText $c ($width - 18)) }
if ($staged.Count) { $changes += Paint (L 'Prêt à valider ({0})' $staged.Count) 'Ok' -Bold; foreach ($s in @($staged | Select-Object -First 12)) { $changes += '  ' + (Format-Change $s.Code $s.File 'Ok') } }
if ($unstaged.Count) { $changes += Paint (L 'Non indexé ({0})' $unstaged.Count) 'Warn' -Bold; foreach ($s in @($unstaged | Select-Object -First 12)) { $changes += '  ' + (Format-Change $s.Code $s.File 'Warn') } }
if ($untracked.Count) { $changes += Paint (L 'Non suivi ({0})' $untracked.Count) 'Dim' -Bold; foreach ($u in @($untracked | Select-Object -First 8)) { $changes += '  ' + (Paint (L 'nouveau').PadRight(8) 'Dim') + '  ' + (Limit-PstText $u ($width - 18)) } }
$hidden = [Math]::Max(0, $staged.Count - 12) + [Math]::Max(0, $unstaged.Count - 12) + [Math]::Max(0, $untracked.Count - 8)
if ($hidden) { $changes += Paint (L '... et {0} autre(s)' $hidden) 'Dim' }
if ($changes.Count -eq 0) { $changes = @(Paint (L '{0} Arbre de travail propre' $g.Ok) 'Ok') }
Format-PstBox -Title (L 'Modifications') -Lines $changes -Width $width | Write-PstLine

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
    Format-PstBox -Title (L 'Derniers commits') -Lines (Format-PstTable -Columns @(
            @{ Name = 'Commit'; Width = 9 }, @{ Name = 'Message'; Width = ($width - 52) }, @{ Name = (L 'Auteur'); Width = 16 }, @{ Name = 'Date'; Width = 16 }
        ) -Rows $rows) -Width $width | Write-PstLine
}
Write-Host ''
