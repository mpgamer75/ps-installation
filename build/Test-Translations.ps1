<#
.SYNOPSIS
    Vérifie les traductions anglaises.
.DESCRIPTION
    Pour chaque fichier source, compare les textes passés à L avec son dictionnaire
    src/i18n/en/<nom>.psd1, et repère les textes français affichés sans passer par L.
        pwsh -File build/Test-Translations.ps1 [-Path src/tools/ask.ps1] [-Strict]
    -Strict : code de sortie 1 s'il manque une traduction (utilisé par la CI).
#>
[CmdletBinding()]
param([string[]]$Path, [switch]$Strict, [switch]$Quiet)
if ($Path) { $Path = @($Path | ForEach-Object { $_ -split "," } | Where-Object { $_ }) }

$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'src'
if (-not $Path) {
    $Path = @(Get-ChildItem -Path (Join-Path $src 'lib'), (Join-Path $src 'tools') -Filter '*.ps1' | ForEach-Object { $_.FullName })
    $Path += Join-Path $src 'setup.ps1'
}

function Get-DictionaryName {
    param([string]$File)
    return [IO.Path]::GetFileNameWithoutExtension($File)
}

# Mots français fréquents : repèrent un texte affiché qui aurait échappé à L.
$french = '(?i)(\b(le|la|les|des|une|est|pour|avec|sans|dans|sur|vos?|votre|aucun|fichiers?|dossier|introuvable|impossible|commande)\b|[éèêàùçô])'
$missingTotal = 0; $unwrappedTotal = 0
$common = @{}
$commonFile = Join-Path (Join-Path (Join-Path $src 'i18n') 'en') 'PsTools.psd1'
if (Test-Path $commonFile) {
    $block = [scriptblock]::Create([IO.File]::ReadAllText($commonFile).TrimStart([char]0xFEFF))
    try { $block.CheckRestrictedLanguage([string[]]@(), [string[]]@(), $false); $common = & $block } catch { $null = $_ }
}

foreach ($file in $Path) {
    $file = (Resolve-Path $file).Path
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
    $keys = New-Object 'System.Collections.Generic.HashSet[string]'
    $wrapped = New-Object 'System.Collections.Generic.HashSet[object]'
    foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'L' }, $true)) {
        $first = $call.CommandElements[1]
        if ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) { [void]$keys.Add($first.Value); [void]$wrapped.Add($first) }
        elseif ($first) { Write-Host "  ! $([IO.Path]::GetFileName($file)):$($first.Extent.StartLineNumber) : L attend un texte littéral (pas $($first.GetType().Name))" -ForegroundColor Yellow }
    }

    $name = Get-DictionaryName $file
    $dictFile = Join-Path (Join-Path (Join-Path $src 'i18n') 'en') "$name.psd1"
    $dict = @{}
    if (Test-Path $dictFile) {
        $block = [scriptblock]::Create([IO.File]::ReadAllText($dictFile).TrimStart([char]0xFEFF))
        try { $block.CheckRestrictedLanguage([string[]]@(), [string[]]@(), $false); $dict = & $block }
        catch { Write-Host "  × $name.psd1 : $($_.Exception.Message)" -ForegroundColor Red; $missingTotal++ }
    }
    # Les textes du dictionnaire commun (PsTools) sont disponibles partout.
    $missing = @($keys | Where-Object { -not $dict.ContainsKey($_) -and -not $common.ContainsKey($_) })
    $unused = @($dict.Keys | Where-Object { -not $keys.Contains([string]$_) })
    $badPlaceholders = @($keys | Where-Object { $dict.ContainsKey($_) } | Where-Object {
            $a = @([regex]::Matches($_, '\{\d+[^}]*\}') | ForEach-Object { ($_.Value -replace ':.*\}', '}') } | Sort-Object -Unique) -join ','
            $b = @([regex]::Matches([string]$dict[$_], '\{\d+[^}]*\}') | ForEach-Object { ($_.Value -replace ':.*\}', '}') } | Sort-Object -Unique) -join ','
            $a -ne $b
        })

    # Textes en dur : chaînes affichées (hors L, hors commentaires) qui ressemblent à du français.
    $unwrapped = @()
    foreach ($str in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)) {
        if ($wrapped.Contains($str)) { continue }
        $value = $str.Value
        if ($value -notmatch $french -or $value.Length -lt 4) { continue }
        if ($value -match '^[\w\.\-\\/:]+$') { continue }                       # chemins, identifiants
        $parentCall = $str.Parent
        while ($parentCall -and $parentCall -isnot [System.Management.Automation.Language.CommandAst]) { $parentCall = $parentCall.Parent }
        if ($parentCall -and $parentCall.GetCommandName() -in 'L', 'Write-Verbose', 'Write-Debug') { continue }
        if ($str.Extent.Text -match '^@?[''"]?\s*#') { continue }
        $unwrapped += "${name}:$($str.Extent.StartLineNumber) $($value.Substring(0, [Math]::Min(70, $value.Length)))"
    }

    $missingTotal += $missing.Count + $badPlaceholders.Count
    $unwrappedTotal += $unwrapped.Count
    if ($Quiet -and -not $missing.Count -and -not $badPlaceholders.Count) { continue }
    Write-Host ("{0,-22} {1,4} texte(s) · {2,3} manquant(s) · {3,3} inutilisé(s) · {4,3} en dur" -f $name, $keys.Count, $missing.Count, $unused.Count, $unwrapped.Count)
    foreach ($m in $missing) { Write-Host "    manquant : $m" -ForegroundColor Yellow }
    foreach ($m in $badPlaceholders) { Write-Host "    {0} différents : $m" -ForegroundColor Red }
    if (-not $Quiet) { foreach ($u in ($unwrapped | Select-Object -First 15)) { Write-Host "    en dur : $u" -ForegroundColor DarkGray } }
}
Write-Host ''
Write-Host "Total : $missingTotal traduction(s) manquante(s) ou incohérente(s), $unwrappedTotal texte(s) en dur à vérifier"
if ($Strict -and $missingTotal -gt 0) { exit 1 }
