<#
.SYNOPSIS
    loc — radiographie d'un projet : lignes de code par langage et notes TODO/FIXME.
.DESCRIPTION
    Équivalent léger de « cloc » / « tokei ». Ignore les dépendances et dossiers
    générés (node_modules, .git, bin, obj, dist...). Lecture seule.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Path = '.',
    [switch]$Todo,
    [switch]$Json,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'loc'

if ($Help -or (Test-PstHelpArg (@($Path) + @($Rest)))) {
    Show-PstHelp -Name 'loc' -Synopsis (L 'Mesure un projet : langages, lignes de code, notes en suspens.') `
        -Usage @(L 'loc [dossier] [-Todo] [-Json]') `
        -Options @(@((L 'dossier'), (L 'Projet à analyser (défaut : dossier courant)')), @('-Todo', (L 'Liste les TODO, FIXME, HACK et XXX avec leur emplacement')), @('-Json', (L 'Sortie JSON, pour les scripts'))) `
        -Examples @('loc', (L 'loc D:\Projets\api'), 'loc -Todo')
    exit 0
}

if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Write-PstStatus err (L 'Dossier introuvable : {0}' $Path); exit 1 }
$root = (Resolve-Path -LiteralPath $Path).ProviderPath

$languages = @{
    '.ps1' = 'PowerShell'; '.psm1' = 'PowerShell'; '.psd1' = 'PowerShell'; '.py' = 'Python'; '.js' = 'JavaScript'; '.mjs' = 'JavaScript'; '.cjs' = 'JavaScript'
    '.jsx' = 'JavaScript'; '.ts' = 'TypeScript'; '.tsx' = 'TypeScript'; '.cs' = 'C#'; '.java' = 'Java'; '.kt' = 'Kotlin'; '.go' = 'Go'; '.rs' = 'Rust'
    '.c' = 'C'; '.h' = 'C / C++ (en-têtes)'; '.cpp' = 'C++'; '.cc' = 'C++'; '.hpp' = 'C / C++ (en-têtes)'; '.rb' = 'Ruby'; '.php' = 'PHP'; '.swift' = 'Swift'
    '.html' = 'HTML'; '.htm' = 'HTML'; '.css' = 'CSS'; '.scss' = 'Sass'; '.less' = 'Less'; '.vue' = 'Vue'; '.svelte' = 'Svelte'; '.sql' = 'SQL'
    '.sh' = 'Shell'; '.bash' = 'Shell'; '.bat' = 'Batch'; '.cmd' = 'Batch'; '.json' = 'JSON'; '.yml' = 'YAML'; '.yaml' = 'YAML'; '.toml' = 'TOML'
    '.xml' = 'XML'; '.md' = 'Markdown'; '.lua' = 'Lua'; '.dart' = 'Dart'; '.r' = 'R'; '.tf' = 'Terraform'
}
$comments = @{
    'PowerShell' = '#'; 'Python' = '#'; 'Shell' = '#'; 'Ruby' = '#'; 'YAML' = '#'; 'TOML' = '#'; 'R' = '#'; 'Terraform' = '#'
    'SQL' = '--'; 'Lua' = '--'; 'Batch' = 'rem '
}
$ignoredDirs = @('.git', '.hg', '.svn', 'node_modules', 'bower_components', 'vendor', 'dist', 'build', 'out', 'bin', 'obj', 'target', '.venv', 'venv', '__pycache__', '.next', '.nuxt', '.idea', '.vs', 'coverage', 'packages')
$ignoredFiles = @('package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'composer.lock', 'Cargo.lock')

$totals = @{}
$notes = New-Object System.Collections.ArrayList
$stack = New-Object System.Collections.Stack
$stack.Push($root)
while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    try {
        $entry = New-Object IO.DirectoryInfo $dir
        foreach ($d in $entry.GetDirectories()) {
            if ($ignoredDirs -contains $d.Name -or ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $stack.Push($d.FullName)
        }
        foreach ($f in $entry.GetFiles()) {
            $lang = $languages[$f.Extension.ToLower()]
            if (-not $lang -or $ignoredFiles -contains $f.Name -or $f.Length -gt 5MB -or $f.Name -like '*.min.*') { continue }
            if (-not $totals.ContainsKey($lang)) { $totals[$lang] = @{ Files = 0; Code = 0; Comment = 0; Blank = 0 } }
            $t = $totals[$lang]
            $t.Files++
            $marker = $comments[$lang]
            if (-not $marker) { $marker = '//' }
            $number = 0
            foreach ($line in [IO.File]::ReadLines($f.FullName)) {
                $number++
                $trimmed = $line.Trim()
                if (-not $trimmed) { $t.Blank++ }
                elseif ($trimmed.StartsWith($marker, [StringComparison]::OrdinalIgnoreCase) -or $trimmed.StartsWith('/*') -or $trimmed.StartsWith('*') -or $trimmed.StartsWith('<!--')) { $t.Comment++ }
                else { $t.Code++ }
                # Uniquement dans un commentaire : le mot-clé suit directement un marqueur (#, //, --, /*, *, <!--).
                if ($trimmed -cmatch '(?:#|//|--|/\*|<!--|^\*)\s*(TODO|FIXME|HACK|XXX)\b[:\s]*(.*)$' -and $lang -notin 'JSON', 'Markdown') {
                    [void]$notes.Add([pscustomobject]@{ Tag = $Matches[1]; File = $f.FullName.Substring($root.Length).TrimStart('\', '/'); Line = $number; Text = $Matches[2].Trim() })
                }
            }
        }
    }
    catch { $null = $_ }
}

$rows = @($totals.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Language = $_.Key; Files = $_.Value.Files; Code = $_.Value.Code; Comment = $_.Value.Comment; Blank = $_.Value.Blank }
    } | Sort-Object Code -Descending)
$sumCode = 0; $sumFiles = 0
foreach ($r in $rows) { $sumCode += $r.Code; $sumFiles += $r.Files }

if ($Json) {
    [ordered]@{ Path = $root; Files = $sumFiles; Code = $sumCode; Languages = @($rows); Notes = @($notes) } | ConvertTo-Json -Depth 4
    exit 0
}

$g = $script:Pst.Glyph
$width = Get-PstWidth -Max 100
Show-PstHeader -Tool 'loc' -Subtitle (Split-Path -Leaf $root)

if ($rows.Count -eq 0) { Write-PstStatus info (L 'Aucun fichier de code reconnu dans ce dossier.'); Write-Host ''; exit 0 }

if ($Todo) {
    if ($notes.Count -eq 0) { Write-PstStatus ok (L 'Aucune note TODO / FIXME en suspens.'); Write-Host ''; exit 0 }
    foreach ($n in $notes) {
        $color = 'Warn'
        if ($n.Tag -eq 'FIXME' -or $n.Tag -eq 'XXX') { $color = 'Err' }
        Write-Host ('  ' + (Paint (Format-PstPad $n.Tag 6) $color -Bold) + (Paint (Limit-PstText "$($n.File):$($n.Line)" 38) 'Accent') + '  ' + (Limit-PstText $n.Text ([Math]::Max(10, $width - 52))))
    }
    Write-Host ''
    Write-Host (Paint ('  ' + (L '{0} note(s)' $notes.Count)) 'Dim')
    Write-Host ''
    exit 0
}

Write-Host ('  ' + (Paint (L '{0:N0} lignes de code' $sumCode) 'Title' -Bold) + (Paint (' ' + (L '{0} {1} fichier(s) {0} {2} langage(s) {0} {3} note(s) TODO/FIXME' $g.Dot $sumFiles $rows.Count $notes.Count)) 'Dim'))
Write-Host ''
$table = @()
foreach ($r in $rows) {
    $pct = 0
    if ($sumCode -gt 0) { $pct = $r.Code / $sumCode * 100 }
    $label = $r.Language
    if ($label -eq 'C / C++ (en-têtes)') { $label = L 'C / C++ (en-têtes)' }
    $table += , @((Paint $label 'Accent'), [string]$r.Files, ('{0:N0}' -f $r.Code), ('{0:N0}' -f $r.Comment), ('{0:N0}' -f $r.Blank), (Format-PstBar $pct 20 -Color 'Accent2'), ('{0,5:N1} %' -f $pct))
}
Format-PstTable -Columns @(
    @{ Name = (L 'Langage'); Width = 20 }, @{ Name = (L 'Fichiers'); Width = 8; Right = $true }, @{ Name = 'Code'; Width = 9; Right = $true },
    @{ Name = (L 'Comment.'); Width = 9; Right = $true }, @{ Name = (L 'Vides'); Width = 8; Right = $true }, @{ Name = ''; Width = 20 }, @{ Name = (L 'Part'); Width = 7; Right = $true }
) -Rows $table | ForEach-Object { Write-Host "  $_" }
Write-Host ''
if ($notes.Count) { Write-Host (Paint ('  ' + (L 'loc -Todo pour lister les {0} note(s) en suspens' $notes.Count)) 'Dim'); Write-Host '' }
