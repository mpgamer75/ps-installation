<#
.SYNOPSIS
    calc — calculatrice et convertisseur du quotidien.
.DESCRIPTION
    Calculs (+ - * / ^ %, parenthèses, sqrt, round, abs, min, max...), pourcentages
    (« 15% de 80 », « 80 + 20% »), conversions d'unités (« 10 km en mi ») et de
    devises (« 100 EUR en USD »). L'expression est lue par un petit interpréteur
    dédié : rien n'est jamais exécuté comme du code PowerShell.
    Devises : taux de la BCE via api.frankfurter.dev (repli : cdn.jsdelivr.net),
    mis en cache une fois par jour dans le dossier de données ; hors ligne, les
    derniers taux connus sont utilisés.
#>
[CmdletBinding()]
param(
    [switch]$Copy,
    [switch]$Json,
    [switch]$Help,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][object[]]$Expression
)

. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib') 'PsTools.ps1')
Import-PstStrings 'calc'

# « calc 3,5 * 2 » sans guillemets : PowerShell transmet « 3,5 » comme un tableau.
$parts = @()
foreach ($item in @($Expression)) {
    if ($null -eq $item) { continue }
    if ($item -is [array]) { $parts += (@($item) -join ',') } else { $parts += [string]$item }
}

if ($Help -or (Test-PstHelpArg $parts)) {
    Show-PstHelp -Name 'calc' -Synopsis (L 'Calculatrice, pourcentages, conversions d''unités et de devises.') `
        -Usage @(
            (L 'calc "<expression>" [-Copy] [-Json]'),
            (L 'calc                         mode interactif (« ans » = dernier résultat)')
        ) `
        -Options @(
            @('-Copy', (L 'Copie le résultat dans le presse-papiers')),
            @('-Json', (L 'Sortie JSON, pour les scripts'))
        ) `
        -Examples @(
            (L 'calc "3,5 * 2 + sqrt(16)"'),
            (L 'calc "15% de 80"'),
            'calc "80 + 20%"',
            (L 'calc 10 km en mi'),
            (L 'calc 20 °C en °F'),
            (L 'calc 1,5 Go en Mo'),
            (L 'calc 100 EUR en USD')
        ) `
        -Notes @(
            (L 'Opérateurs : + - * / ^ % ( ) ; fonctions : sqrt, abs, round, floor, ceil, min, max, ln, log, exp.'),
            (L 'Virgule ou point décimal. Dans une fonction, séparez les arguments par « ; » : max(3,5; 2).'),
            (L 'Unités : longueur, masse, température, volume, vitesse, données (Ko = 1000 o, Kio = 1024 o), durée.'),
            (L 'Mettez l''expression entre guillemets si elle contient des parenthèses.'),
            (L 'Devises : taux BCE (api.frankfurter.dev), mis en cache chaque jour ; hors ligne, derniers taux connus.')
        )
    exit 0
}

# ── Nombres ──────────────────────────────────────────────────────────────────

function Get-OutCulture {
    # Culture de l'utilisateur si elle correspond à la langue choisie, sinon celle de la langue.
    $c = [Globalization.CultureInfo]::CurrentCulture
    if ($c.TwoLetterISOLanguageName -eq $script:Pst.Lang) { return $c }
    return (Get-PstCulture)
}
$script:OutCulture = Get-OutCulture

function Format-Number {
    # -Significant : chiffres significatifs conservés (12 pour un calcul, 6 pour une conversion).
    param([double]$Value, [int]$MaxDecimals = 10, [int]$Significant = 12, [switch]$Plain)
    $c = $script:OutCulture
    if ([double]::IsInfinity($Value) -or [double]::IsNaN($Value)) { return [string]$Value }
    $abs = [Math]::Abs($Value)
    if ($abs -ne 0 -and ($abs -ge 1e15 -or $abs -lt 1e-9)) { return $Value.ToString('G' + [Math]::Min($Significant, 10), $c) }
    $intDigits = 1
    if ($abs -ne 0) { $intDigits = [int][Math]::Floor([Math]::Log10($abs)) + 1 }
    $dec = [Math]::Max(0, [Math]::Min($MaxDecimals, $Significant - $intDigits))
    $rounded = [Math]::Round($Value, [Math]::Min($dec, 15))
    $int = '#,##0'
    if ($Plain) { $int = '0' }
    $fmt = $int
    if ($dec -gt 0) { $fmt = $int + '.' + ('#' * $dec) }
    $s = $rounded.ToString($fmt, $c)
    if ($s -eq '-0') { $s = '0' }
    return $s
}

function Format-Money {
    param([double]$Value, [switch]$Plain)
    if ([Math]::Abs($Value) -ge 1 -or $Value -eq 0) { $s = Format-Number ([Math]::Round($Value, 2)) -MaxDecimals 2 -Plain:$Plain }
    else { $s = Format-Number $Value -MaxDecimals 4 -Plain:$Plain }
    # Toujours deux décimales pour les montants courants.
    $sep = $script:OutCulture.NumberFormat.NumberDecimalSeparator
    if ([Math]::Abs($Value) -ge 1) {
        if (-not $s.Contains($sep)) { $s += $sep + '00' }
        elseif ($s.Length - $s.IndexOf($sep) -eq 2) { $s += '0' }
    }
    return $s
}

# ── Analyse lexicale ─────────────────────────────────────────────────────────

function New-Token { param([string]$T, $V) return [pscustomobject]@{ T = $T; V = $V } }

function Test-CallHasSemicolon {
    # Vrai si l'appel de fonction ouvert en $Start contient un « ; » à son propre niveau.
    param([string]$Text, [int]$Start)
    $depth = 0
    for ($k = $Start; $k -lt $Text.Length; $k++) {
        $c = $Text[$k]
        if ($c -eq '(') { $depth++ }
        elseif ($c -eq ')') { $depth--; if ($depth -eq 0) { return $false } }
        elseif ($c -eq ';' -and $depth -eq 1) { return $true }
    }
    return $false
}

function Get-Tokens {
    param([string]$Text)
    $tokens = New-Object System.Collections.ArrayList
    $calls = New-Object System.Collections.ArrayList   # une entrée par « ( » ouverte
    $spaces = @([char]' ', [char]0x00A0, [char]0x202F)
    $n = $Text.Length
    $i = 0
    while ($i -lt $n) {
        $ch = $Text[$i]
        if ([char]::IsWhiteSpace($ch)) { $i++; continue }
        if ([char]::IsDigit($ch) -or ($ch -eq '.' -and $i + 1 -lt $n -and [char]::IsDigit($Text[$i + 1]))) {
            $sb = New-Object System.Text.StringBuilder
            $hasDot = $false
            $groupLen = 0; $grouped = $false
            while ($i -lt $n) {
                $c = $Text[$i]
                if ([char]::IsDigit($c)) { [void]$sb.Append($c); $groupLen++; $i++; continue }
                # Un séparateur n'a de sens que suivi d'un chiffre, et jamais après la partie décimale.
                $nextDigit = ($i + 1 -lt $n -and [char]::IsDigit($Text[$i + 1]))
                if (-not $nextDigit -or $hasDot) { break }
                # Groupe de milliers : exactement trois chiffres après le séparateur.
                $three = $false
                if ($i + 3 -lt $n -and [char]::IsDigit($Text[$i + 2]) -and [char]::IsDigit($Text[$i + 3])) {
                    $three = ($i + 4 -ge $n) -or -not [char]::IsDigit($Text[$i + 4])
                }
                $groupOk = $three -and (($grouped -and $groupLen -eq 3) -or (-not $grouped -and $groupLen -le 3))
                if ($c -eq '.') { [void]$sb.Append('.'); $hasDot = $true; $i++; continue }
                if ($spaces -contains $c) {
                    if ($groupOk) { $grouped = $true; $groupLen = 0; $i++; continue }
                    break
                }
                if ($c -eq ',') {
                    $inCall = ($calls.Count -gt 0 -and $calls[$calls.Count - 1].Func)
                    if ($inCall -and -not $calls[$calls.Count - 1].Semi) { break }          # séparateur d'arguments
                    if ($script:Pst.Lang -eq 'en' -and $groupOk -and -not $inCall) { $grouped = $true; $groupLen = 0; $i++; continue }   # 1,000
                    [void]$sb.Append('.'); $hasDot = $true; $i++; continue                 # virgule décimale
                }
                break
            }
            if ($i -lt $n -and ($Text[$i] -eq 'e' -or $Text[$i] -eq 'E')) {
                $j = $i + 1
                if ($j -lt $n -and ($Text[$j] -eq '+' -or $Text[$j] -eq '-')) { $j++ }
                if ($j -lt $n -and [char]::IsDigit($Text[$j])) {
                    [void]$sb.Append('e'); [void]$sb.Append($Text.Substring($i + 1, $j - $i - 1))
                    $i = $j
                    while ($i -lt $n -and [char]::IsDigit($Text[$i])) { [void]$sb.Append($Text[$i]); $i++ }
                }
            }
            $value = [double]::Parse($sb.ToString(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture)
            [void]$tokens.Add((New-Token 'num' $value))
            continue
        }
        if ([char]::IsLetter($ch) -or $ch -eq '_' -or $ch -eq [char]0x03C0) {
            $start = $i
            while ($i -lt $n -and ([char]::IsLetterOrDigit($Text[$i]) -or $Text[$i] -eq '_')) { $i++ }
            $word = $Text.Substring($start, $i - $start).ToLowerInvariant()
            if ($word -in 'de', 'du', 'of', 'x') { [void]$tokens.Add((New-Token 'op' '*')); continue }
            if ($word -eq 'mod') { [void]$tokens.Add((New-Token 'op' '%')); continue }
            [void]$tokens.Add((New-Token 'id' $word))
            continue
        }
        switch ($ch) {
            '(' {
                $isCall = ($tokens.Count -gt 0 -and $tokens[$tokens.Count - 1].T -eq 'id')
                [void]$calls.Add(@{ Func = $isCall; Semi = ($isCall -and (Test-CallHasSemicolon $Text $i)) })
                [void]$tokens.Add((New-Token 'lp' '('))
            }
            ')' {
                if ($calls.Count -gt 0) { $calls.RemoveAt($calls.Count - 1) }
                [void]$tokens.Add((New-Token 'rp' ')'))
            }
            { $_ -eq ';' -or $_ -eq ',' } { [void]$tokens.Add((New-Token 'sep' $ch)) }
            { $_ -eq '+' -or $_ -eq '-' -or $_ -eq '/' -or $_ -eq '^' -or $_ -eq '%' -or $_ -eq '!' } { [void]$tokens.Add((New-Token 'op' ([string]$ch))) }
            '*' {
                if ($i + 1 -lt $n -and $Text[$i + 1] -eq '*') { [void]$tokens.Add((New-Token 'op' '^')); $i++ }
                else { [void]$tokens.Add((New-Token 'op' '*')) }
            }
            default { throw (L 'Caractère non reconnu : « {0} »' $ch) }
        }
        $i++
    }
    return , $tokens
}

# ── Analyse syntaxique et évaluation (descente récursive) ────────────────────

function Get-Peek { if ($script:Pos -lt $script:Tok.Count) { return $script:Tok[$script:Pos] }; return $null }
function Get-Next { $t = Get-Peek; $script:Pos++; return $t }
function Test-Op {
    param($Token, [string[]]$Ops)
    return ($null -ne $Token -and $Token.T -eq 'op' -and $Ops -contains [string]$Token.V)
}
function Format-TokenText {
    param($Token)
    if ($null -eq $Token) { return (L 'fin de l''expression') }
    if ($Token.T -eq 'num') { return (Format-Number $Token.V) }
    return [string]$Token.V
}
function Assert-Finite {
    param([double]$Value)
    if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value)) { throw (L 'Résultat non défini (hors du domaine de calcul).') }
    return $Value
}

function Read-Additive {
    $left = Read-Multiplicative
    while (Test-Op (Get-Peek) '+', '-') {
        $op = (Get-Next).V
        $right = Read-Multiplicative
        if ($right.P) {
            # « 80 + 20% » : pourcentage de la valeur de gauche.
            if ($op -eq '+') { $v = $left.V * (1 + $right.V) } else { $v = $left.V * (1 - $right.V) }
        }
        elseif ($op -eq '+') { $v = $left.V + $right.V }
        else { $v = $left.V - $right.V }
        $left = @{ V = $v; P = $false }
    }
    return $left
}

function Read-Multiplicative {
    $left = Read-Unary
    while (Test-Op (Get-Peek) '*', '/', '%') {
        $op = (Get-Next).V
        $right = Read-Unary
        switch ($op) {
            '*' { $v = $left.V * $right.V }
            '/' {
                if ($right.V -eq 0) { throw (L 'Division par zéro.') }
                $v = $left.V / $right.V
            }
            default {
                if ($right.V -eq 0) { throw (L 'Division par zéro.') }
                $v = $left.V - $right.V * [Math]::Floor($left.V / $right.V)
            }
        }
        $left = @{ V = $v; P = $false }
    }
    return $left
}

function Read-Unary {
    $t = Get-Peek
    if (Test-Op $t '-') { [void](Get-Next); $r = Read-Unary; return @{ V = - $r.V; P = $r.P } }
    if (Test-Op $t '+') { [void](Get-Next); return (Read-Unary) }
    return (Read-Power)
}

function Read-Power {
    $base = Read-Postfix
    if (Test-Op (Get-Peek) '^') {
        [void](Get-Next)
        $exp = Read-Unary
        return @{ V = (Assert-Finite ([Math]::Pow($base.V, $exp.V))); P = $false }
    }
    return $base
}

function Read-Postfix {
    $r = Read-Primary
    while ($true) {
        $t = Get-Peek
        if (Test-Op $t '%') {
            # « % » suivi d'un opérande : modulo (traité plus haut) ; sinon pourcentage.
            $after = $null
            if ($script:Pos + 1 -lt $script:Tok.Count) { $after = $script:Tok[$script:Pos + 1] }
            if ($null -ne $after -and $after.T -in 'num', 'id', 'lp') { break }
            [void](Get-Next)
            $r = @{ V = $r.V / 100; P = $true }
            continue
        }
        if (Test-Op $t '!') {
            [void](Get-Next)
            if ($r.V -lt 0 -or $r.V -ne [Math]::Floor($r.V) -or $r.V -gt 170) { throw (L 'Factorielle : entier entre 0 et 170 attendu.') }
            $f = 1.0
            for ($k = 2; $k -le $r.V; $k++) { $f *= $k }
            $r = @{ V = $f; P = $false }
            continue
        }
        break
    }
    return $r
}

function Read-Primary {
    $t = Get-Next
    if ($null -eq $t) { throw (L 'Expression incomplète.') }
    if ($t.T -eq 'num') { return @{ V = [double]$t.V; P = $false } }
    if ($t.T -eq 'lp') {
        $inner = Read-Additive
        $close = Get-Next
        if ($null -eq $close -or $close.T -ne 'rp') { throw (L 'Parenthèse fermante manquante.') }
        return $inner
    }
    if ($t.T -eq 'id') {
        $name = [string]$t.V
        if ((Get-Peek) -and (Get-Peek).T -eq 'lp') {
            [void](Get-Next)
            $values = @()
            if ((Get-Peek) -and (Get-Peek).T -eq 'rp') { [void](Get-Next) }
            else {
                while ($true) {
                    $values += (Read-Additive).V
                    $sep = Get-Next
                    if ($null -eq $sep) { throw (L 'Parenthèse fermante manquante.') }
                    if ($sep.T -eq 'rp') { break }
                    if ($sep.T -ne 'sep') { throw (L '« {0} » inattendu.' (Format-TokenText $sep)) }
                }
            }
            return @{ V = (Assert-Finite (Invoke-CalcFunction $name $values)); P = $false }
        }
        switch ($name) {
            { $_ -in 'pi', ([string][char]0x03C0) } { return @{ V = [Math]::PI; P = $false } }
            'e' { return @{ V = [Math]::E; P = $false } }
            'tau' { return @{ V = 2 * [Math]::PI; P = $false } }
            'ans' {
                if ($null -eq $script:Ans) { throw (L 'Aucun résultat précédent (« ans »).') }
                return @{ V = [double]$script:Ans; P = $false }
            }
        }
        throw (L 'Fonction ou nom inconnu : « {0} »' $name)
    }
    throw (L '« {0} » inattendu.' (Format-TokenText $t))
}

function Invoke-CalcFunction {
    param([string]$Name, [double[]]$Values)
    $count = @($Values).Count
    $one = {
        if ($count -ne 1) { throw (L '{0} attend un seul argument.' $Name) }
        return $Values[0]
    }
    switch ($Name) {
        { $_ -in 'sqrt', 'racine' } {
            $x = & $one
            if ($x -lt 0) { throw (L 'Racine carrée d''un nombre négatif.') }
            return [Math]::Sqrt($x)
        }
        'abs' { return [Math]::Abs((& $one)) }
        { $_ -in 'round', 'arrondi' } {
            if ($count -lt 1 -or $count -gt 2) { throw (L 'round attend 1 ou 2 arguments : round(x; décimales).') }
            $digits = 0
            if ($count -eq 2) { $digits = [int]$Values[1] }
            if ($digits -lt 0 -or $digits -gt 15) { throw (L 'Nombre de décimales entre 0 et 15.') }
            return [Math]::Round($Values[0], $digits, [MidpointRounding]::AwayFromZero)
        }
        { $_ -in 'floor', 'plancher' } { return [Math]::Floor((& $one)) }
        { $_ -in 'ceil', 'plafond' } { return [Math]::Ceiling((& $one)) }
        'min' {
            if ($count -eq 0) { throw (L '{0} attend au moins un argument.' $Name) }
            return (($Values | Measure-Object -Minimum).Minimum)
        }
        'max' {
            if ($count -eq 0) { throw (L '{0} attend au moins un argument.' $Name) }
            return (($Values | Measure-Object -Maximum).Maximum)
        }
        'ln' { return [Math]::Log((& $one)) }
        'log' {
            if ($count -eq 2) { return [Math]::Log($Values[0], $Values[1]) }
            return [Math]::Log10((& $one))
        }
        'exp' { return [Math]::Exp((& $one)) }
        'sin' { return [Math]::Sin((& $one)) }
        'cos' { return [Math]::Cos((& $one)) }
        'tan' { return [Math]::Tan((& $one)) }
    }
    throw (L 'Fonction ou nom inconnu : « {0} »' $Name)
}

function Invoke-Expr {
    # Évalue une expression arithmétique (texte) ; jamais Invoke-Expression.
    param([string]$Text)
    $clean = $Text.Trim().TrimEnd('=').Trim()
    $clean = $clean.Replace([string][char]0x2212, '-').Replace([string][char]0x00D7, '*').Replace([string][char]0x00F7, '/').Replace([string][char]0x00B7, '*')
    if (-not $clean) { throw (L 'Expression vide.') }
    $script:Tok = Get-Tokens $clean
    $script:Pos = 0
    $r = Read-Additive
    if ($script:Pos -lt $script:Tok.Count) {
        $t = $script:Tok[$script:Pos]
        if ($t.T -eq 'rp') { throw (L 'Parenthèse fermante en trop.') }
        throw (L '« {0} » inattendu.' (Format-TokenText $t))
    }
    return (Assert-Finite $r.V)
}

# ── Unités ───────────────────────────────────────────────────────────────────

$script:UnitDefs = @(
    # Catégorie, facteur vers l'unité de base, alias (le premier sert d'identifiant)
    @('length', 1e-9, 'nm'), @('length', 1e-6, 'µm', 'um'), @('length', 0.001, 'mm', 'millimètre', 'millimètres', 'millimeter', 'millimeters'),
    @('length', 0.01, 'cm', 'centimètre', 'centimètres', 'centimeter', 'centimeters'), @('length', 0.1, 'dm'),
    @('length', 1, 'm', 'mètre', 'mètres', 'metre', 'metres', 'meter', 'meters'),
    @('length', 1000, 'km', 'kilomètre', 'kilomètres', 'kilometer', 'kilometers', 'kilometre', 'kilometres'),
    @('length', 0.0254, 'in', 'inch', 'inches', 'pouce', 'pouces', '"'), @('length', 0.3048, 'ft', 'foot', 'feet', 'pied', 'pieds', "'"),
    @('length', 0.9144, 'yd', 'yard', 'yards'), @('length', 1609.344, 'mi', 'mile', 'miles'), @('length', 1852, 'nmi', 'mille marin', 'milles marins', 'nautical mile', 'nautical miles'),
    @('mass', 1e-6, 'mg', 'milligramme', 'milligrammes', 'milligram', 'milligrams'), @('mass', 0.001, 'g', 'gramme', 'grammes', 'gram', 'grams'),
    @('mass', 1, 'kg', 'kilo', 'kilos', 'kilogramme', 'kilogrammes', 'kilogram', 'kilograms'), @('mass', 1000, 't', 'tonne', 'tonnes', 'ton', 'tons'),
    @('mass', 0.45359237, 'lb', 'lbs', 'pound', 'pounds', 'livre', 'livres'), @('mass', 0.028349523125, 'oz', 'ounce', 'ounces', 'once', 'onces'),
    @('mass', 6.35029318, 'st', 'stone', 'stones'),
    @('temp', 0, 'C', '°C', 'celsius', 'degré celsius', 'degrés celsius'), @('temp', 0, 'F', '°F', 'fahrenheit', 'degré fahrenheit', 'degrés fahrenheit'), @('temp', 0, 'K', 'kelvin', 'kelvins'),
    @('volume', 0.001, 'ml', 'mL', 'millilitre', 'millilitres', 'milliliter', 'milliliters'), @('volume', 0.01, 'cl', 'cL', 'centilitre', 'centilitres'), @('volume', 0.1, 'dl', 'dL'),
    @('volume', 1, 'l', 'L', 'litre', 'litres', 'liter', 'liters'), @('volume', 100, 'hl', 'hL', 'hectolitre', 'hectolitres'),
    @('volume', 1000, 'm3', 'm³', 'mètre cube', 'mètres cubes', 'cubic meter', 'cubic meters'), @('volume', 0.001, 'cm3', 'cm³', 'cc'),
    @('volume', 3.785411784, 'gal', 'gallon', 'gallons'), @('volume', 0.946352946, 'qt', 'quart', 'quarts'), @('volume', 0.473176473, 'pt', 'pint', 'pints', 'pinte', 'pintes'),
    @('volume', 0.2365882365, 'cup', 'cups', 'tasse', 'tasses'), @('volume', 0.0295735295625, 'floz', 'fl oz', 'fl.oz'),
    @('volume', 0.015, 'cs', 'cuillère à soupe', 'cuillères à soupe', 'tbsp'), @('volume', 0.005, 'càc', 'cuillère à café', 'cuillères à café', 'tsp'),
    @('speed', 1, 'm/s', 'mps'), @('speed', (1000 / 3600), 'km/h', 'kmh', 'kph', 'km/hr'), @('speed', 0.44704, 'mph', 'mi/h'),
    @('speed', 0.514444444, 'kn', 'kt', 'nœud', 'nœuds', 'noeud', 'noeuds', 'knot', 'knots'), @('speed', 0.3048, 'ft/s', 'fps'),
    @('data', 1, 'o', 'B', 'octet', 'octets', 'byte', 'bytes'), @('data', 0.125, 'bit', 'bits', 'b'),
    @('data', 1e3, 'Ko', 'kB', 'KB', 'ko', 'kb'), @('data', 1e6, 'Mo', 'MB', 'mo'), @('data', 1e9, 'Go', 'GB', 'go', 'gb'), @('data', 1e12, 'To', 'TB', 'to', 'tb'), @('data', 1e15, 'Po', 'PB'),
    @('data', 1024, 'Kio', 'KiB', 'kio', 'kib'), @('data', 1048576, 'Mio', 'MiB', 'mio', 'mib'), @('data', 1073741824, 'Gio', 'GiB', 'gio', 'gib'), @('data', 1099511627776, 'Tio', 'TiB', 'tio', 'tib'),
    @('data', 125, 'kbit', 'Kbit', 'kbps'), @('data', 125000, 'Mbit', 'Mb', 'mbit', 'Mbps'), @('data', 125000000, 'Gbit', 'Gb', 'gbit', 'Gbps'),
    @('time', 0.001, 'ms', 'milliseconde', 'millisecondes', 'millisecond', 'milliseconds'), @('time', 1, 's', 'sec', 'seconde', 'secondes', 'second', 'seconds'),
    @('time', 60, 'min', 'mn', 'minute', 'minutes'), @('time', 3600, 'h', 'hr', 'hrs', 'heure', 'heures', 'hour', 'hours'),
    @('time', 86400, 'j', 'd', 'jour', 'jours', 'day', 'days'), @('time', 604800, 'sem', 'semaine', 'semaines', 'wk', 'week', 'weeks'),
    @('time', 2629746, 'mois', 'month', 'months'), @('time', 31556952, 'an', 'ans', 'année', 'années', 'a', 'y', 'yr', 'year', 'years')
)

# Recherche sensible à la casse d'abord (Mb ≠ MB), puis insensible.
$script:UnitExact = New-Object 'System.Collections.Generic.Dictionary[string,object]'
$script:UnitLower = New-Object 'System.Collections.Generic.Dictionary[string,object]'
foreach ($def in $script:UnitDefs) {
    $unit = [pscustomobject]@{ Cat = $def[0]; Factor = [double]$def[1]; Id = $def[2] }
    foreach ($alias in $def[2..($def.Count - 1)]) {
        if (-not $script:UnitExact.ContainsKey($alias)) { $script:UnitExact[$alias] = $unit }
        $low = $alias.ToLowerInvariant()
        if (-not $script:UnitLower.ContainsKey($low)) { $script:UnitLower[$low] = $unit }
    }
}

function Resolve-Unit {
    param([string]$Text)
    $t = $Text.Trim().TrimEnd('.')
    $t = $t -replace '^°\s*', '°' -replace '\s+', ' '
    if ($script:UnitExact.ContainsKey($t)) { return $script:UnitExact[$t] }
    $low = $t.ToLowerInvariant()
    if ($script:UnitLower.ContainsKey($low)) { return $script:UnitLower[$low] }
    return $null
}

function Resolve-Currency {
    param([string]$Text)
    $t = $Text.Trim()
    switch ($t.ToLowerInvariant()) {
        { $_ -in '€', 'euro', 'euros' } { return 'EUR' }
        { $_ -in '$', 'us$', 'dollar', 'dollars' } { return 'USD' }
        { $_ -in '£', 'sterling' } { return 'GBP' }
        { $_ -in '¥', 'yen', 'yens' } { return 'JPY' }
        { $_ -in 'fr', 'chf' } { return 'CHF' }
    }
    if ($t -match '^[A-Za-z]{3}$') { return $t.ToUpperInvariant() }
    return $null
}

function Get-CategoryName {
    param([string]$Cat)
    switch ($Cat) {
        'length' { return (L 'longueur') }
        'mass' { return (L 'masse') }
        'temp' { return (L 'température') }
        'volume' { return (L 'volume') }
        'speed' { return (L 'vitesse') }
        'data' { return (L 'données') }
        'time' { return (L 'durée') }
        'currency' { return (L 'devise') }
    }
    return $Cat
}

function ConvertTo-Kelvin {
    param([double]$Value, [string]$Id)
    switch ($Id) { 'C' { return $Value + 273.15 } 'F' { return ($Value - 32) * 5 / 9 + 273.15 } }
    return $Value
}
function ConvertFrom-Kelvin {
    param([double]$Value, [string]$Id)
    switch ($Id) { 'C' { return $Value - 273.15 } 'F' { return ($Value - 273.15) * 9 / 5 + 32 } }
    return $Value
}

function Convert-UnitValue {
    param([double]$Value, $From, $To)
    if ($From.Cat -eq 'temp') { return (ConvertFrom-Kelvin (ConvertTo-Kelvin $Value $From.Id) $To.Id) }
    return ($Value * $From.Factor / $To.Factor)
}

# ── Devises ──────────────────────────────────────────────────────────────────

$script:RatesUrl = 'https://api.frankfurter.dev/v1/latest?base=EUR'
$script:FallbackUrl = 'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/eur.json'
# Réservé aux tests : un chemin de fichier (réponse enregistrée) ou « offline ».
if ($env:PSTOOLS_CALC_RATES_URL) { $script:RatesUrl = $env:PSTOOLS_CALC_RATES_URL }
if ($env:PSTOOLS_CALC_FALLBACK_URL) { $script:FallbackUrl = $env:PSTOOLS_CALC_FALLBACK_URL }

function Invoke-JsonSource {
    param([string]$Url)
    if ($Url -eq 'offline') { throw (New-Object System.Net.WebException 'offline') }
    if (Test-Path -LiteralPath $Url -PathType Leaf) { $text = [IO.File]::ReadAllText($Url, [Text.Encoding]::UTF8) }
    else {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }
        $ProgressPreference = 'SilentlyContinue'
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $text = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    }
    return ($text.TrimStart([char]0xFEFF) | ConvertFrom-Json)
}

function Get-NetErrorText {
    param($ErrorRecord)
    $code = 0
    try { if ($ErrorRecord.Exception.Response) { $code = [int]$ErrorRecord.Exception.Response.StatusCode } } catch { $code = 0 }
    if ($code -eq 429) { return (L 'trop de requêtes (HTTP 429), réessayez plus tard') }
    if ($code -gt 0) { return (L 'erreur HTTP {0}' $code) }
    return (L 'pas de connexion Internet ou serveur injoignable')
}

function ConvertFrom-FrankfurterJson {
    # { "base": "EUR", "date": "...", "rates": { "USD": 1.09, ... } }
    param($Data)
    $rates = @{ EUR = 1.0 }
    foreach ($p in $Data.rates.PSObject.Properties) { $rates[[string]$p.Name.ToUpperInvariant()] = [double]$p.Value }
    return @{ Date = [string]$Data.date; Rates = $rates }
}

function ConvertFrom-FallbackJson {
    # { "date": "...", "eur": { "usd": 1.09, ... } }
    param($Data)
    $rates = @{ EUR = 1.0 }
    foreach ($p in $Data.eur.PSObject.Properties) {
        if ($p.Value -is [double] -or $p.Value -is [int] -or $p.Value -is [long] -or $p.Value -is [decimal]) { $rates[[string]$p.Name.ToUpperInvariant()] = [double]$p.Value }
    }
    return @{ Date = [string]$Data.date; Rates = $rates }
}

function Get-Rates {
    # Taux (base EUR) : cache du jour, sinon réseau, sinon derniers taux connus.
    param([string[]]$Codes)
    $file = Join-Path (Get-PstDataDir) 'calc-rates.json'
    $cache = Read-PstJsonFile $file
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $hasAll = {
        param($Table)
        if (-not ($Table -is [hashtable])) { return $false }
        foreach ($c in $Codes) { if (-not $Table.ContainsKey($c)) { return $false } }
        return $true
    }
    $cacheOk = ($cache -is [hashtable]) -and (& $hasAll $cache.rates)
    if ($cacheOk -and $cache.fetched -eq $today) {
        return @{ Rates = $cache.rates; Date = [string]$cache.date; Source = [string]$cache.source; Stale = $false; Reason = '' }
    }

    $fresh = $null; $reason = ''
    try { $fresh = ConvertFrom-FrankfurterJson (Invoke-JsonSource $script:RatesUrl); $fresh.Source = 'frankfurter' }
    catch { $reason = Get-NetErrorText $_ }
    if (-not $fresh -or -not (& $hasAll $fresh.Rates)) {
        try {
            $alt = ConvertFrom-FallbackJson (Invoke-JsonSource $script:FallbackUrl)
            if ($fresh) { foreach ($k in @($alt.Rates.Keys)) { if (-not $fresh.Rates.ContainsKey($k)) { $fresh.Rates[$k] = $alt.Rates[$k] } } }
            else { $fresh = $alt; $fresh.Source = 'fawazahmed0' }
        }
        catch { if (-not $reason) { $reason = Get-NetErrorText $_ } }
    }
    if ($fresh) {
        Write-PstJsonFile $file ([ordered]@{ fetched = $today; date = $fresh.Date; source = $fresh.Source; rates = $fresh.Rates })
        foreach ($c in $Codes) { if (-not $fresh.Rates.ContainsKey($c)) { throw (L 'Devise inconnue : {0}' $c) } }
        return @{ Rates = $fresh.Rates; Date = $fresh.Date; Source = $fresh.Source; Stale = $false; Reason = '' }
    }
    if ($cacheOk) {
        return @{ Rates = $cache.rates; Date = [string]$cache.date; Source = [string]$cache.source; Stale = $true; Reason = $reason }
    }
    if ($cache -is [hashtable] -and $cache.rates -is [hashtable]) {
        foreach ($c in $Codes) { if (-not $cache.rates.ContainsKey($c)) { throw (L 'Devise inconnue (ou taux absent du cache) : {0}' $c) } }
    }
    throw (L 'Taux de change indisponibles : {0}. Aucun taux en cache.' $reason)
}

function Format-RateDate {
    param([string]$Date)
    try { return ([DateTime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)).ToString((L 'd MMMM yyyy'), (Get-PstCulture)) }
    catch { return $Date }
}

# ── Calcul complet ───────────────────────────────────────────────────────────

function Split-Conversion {
    # « <valeur> <unité> en|to|in <unité> » ; plusieurs découpages possibles (« 10 in to cm »).
    param([string]$Text)
    foreach ($m in [regex]::Matches($Text, '\s+(en|to|in|vers|->|=>|' + [char]0x2192 + ')(?=\s)', 'IgnoreCase')) {
        $left = $Text.Substring(0, $m.Index).Trim()
        $right = $Text.Substring($m.Index + $m.Length).Trim()
        $lm = [regex]::Match($left, '^(?<v>.*[\d\)])\s*(?<u>[^\d\s()+*/^%;,.\-][^()]*?)$')
        if (-not $lm.Success -or -not $right) { continue }
        $fromText = $lm.Groups['u'].Value.Trim()
        if (((Resolve-Unit $fromText) -or (Resolve-Currency $fromText)) -and ((Resolve-Unit $right) -or (Resolve-Currency $right))) {
            return @{ Value = $lm.Groups['v'].Value; From = $fromText; To = $right }
        }
    }
    return $null
}

function Invoke-Calc {
    param([string]$Text)
    $conv = Split-Conversion $Text
    if (-not $conv) {
        $v = Invoke-Expr $Text
        return [ordered]@{ Kind = 'number'; Input = $Text.Trim(); Value = $v; Unit = ''; Text = (Format-Number $v); Plain = (Format-Number $v -Plain); Note = ''; Stale = $false }
    }
    $value = Invoke-Expr $conv.Value
    $from = Resolve-Unit $conv.From
    $to = Resolve-Unit $conv.To
    if ($from -and $to) {
        if ($from.Cat -ne $to.Cat) {
            throw (L 'Unités incompatibles : « {0} » ({1}) et « {2} » ({3}).' $conv.From (Get-CategoryName $from.Cat) $conv.To (Get-CategoryName $to.Cat))
        }
        $r = Convert-UnitValue $value $from $to
        $note = ''
        if ($from.Cat -eq 'data' -and (($from.Id -cmatch 'io$') -xor ($to.Id -cmatch 'io$'))) {
            $note = L 'Ko, Mo, Go = puissances de 1000 ; Kio, Mio, Gio = puissances de 1024.'
        }
        return [ordered]@{ Kind = 'unit'; Input = $Text.Trim(); Value = $r; Unit = $conv.To; Text = ((Format-Number $r -Significant 6) + ' ' + $conv.To); Plain = (Format-Number $r -Significant 6 -Plain); Note = $note; Stale = $false }
    }
    $fc = Resolve-Currency $conv.From
    $tc = Resolve-Currency $conv.To
    if ($from -or $to -or -not $fc -or -not $tc) {
        $fromCat = 'currency'; if ($from) { $fromCat = $from.Cat }
        $toCat = 'currency'; if ($to) { $toCat = $to.Cat }
        throw (L 'Unités incompatibles : « {0} » ({1}) et « {2} » ({3}).' $conv.From (Get-CategoryName $fromCat) $conv.To (Get-CategoryName $toCat))
    }
    $rates = Get-Rates @($fc, $tc)
    $rate = [double]$rates.Rates[$tc] / [double]$rates.Rates[$fc]
    $r = $value * $rate
    $note = L '1 {0} = {1} {2} · taux du {3}' $fc (Format-Number $rate -MaxDecimals 6) $tc (Format-RateDate $rates.Date)
    return [ordered]@{
        Kind = 'currency'; Input = $Text.Trim(); Value = [Math]::Round($r, 4); Unit = $tc; Text = ((Format-Money $r) + ' ' + $tc); Plain = (Format-Money $r -Plain)
        Note = $note; Stale = [bool]$rates.Stale; Rate = $rate; RatesDate = $rates.Date; Source = $rates.Source; Reason = $rates.Reason
    }
}

function Write-CalcResult {
    param($Result)
    Write-Host ('  ' + (Paint $Result.Input 'Dim') + (Paint '  =  ' 'Accent') + (Paint $Result.Text 'Title' -Bold))
    if ($Result.Note) { Write-Host ('  ' + (Paint $Result.Note 'Dim')) }
    if ($Result.Stale) { Write-PstStatus warn (L 'Hors ligne ({0}) : derniers taux connus, du {1}.' $Result.Reason (Format-RateDate $Result.RatesDate)) }
}

function Copy-CalcResult {
    param($Result)
    try {
        Set-Clipboard -Value $Result.Plain -ErrorAction Stop
        Write-PstStatus ok (L 'Copié dans le presse-papiers : {0}' $Result.Plain)
    }
    catch { Write-PstStatus warn (L 'Presse-papiers indisponible : {0}' $_.Exception.Message) }
}

$script:Ans = $null

# ── Mode interactif ou entrée redirigée ──────────────────────────────────────

if ($parts.Count -eq 0) {
    if (-not (Test-PstInteractive)) {
        $lines = @($input | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
        if ($lines.Count -eq 0) {
            Write-PstStatus err (L 'Aucune expression. Exemple : calc "2 + 2" (calc -Help pour l''aide).')
            exit 1
        }
        $failed = $false
        $results = @()
        foreach ($line in $lines) {
            try { $r = Invoke-Calc $line; $script:Ans = $r.Value; $results += $r; if (-not $Json) { Write-CalcResult $r } }
            catch { $failed = $true; Write-PstStatus err ("$($line.Trim()) : " + $_.Exception.Message) }
        }
        if ($Json) { ConvertTo-Json -InputObject @($results) -Depth 4 }
        if ($failed) { exit 1 }
        exit 0
    }
    Show-PstHeader -Tool 'calc' -Subtitle (L 'mode interactif')
    Write-Host ('  ' + (Paint (L 'Un calcul par ligne ; « ans » reprend le dernier résultat. Ligne vide ou « q » pour quitter.') 'Dim'))
    Write-Host ''
    while ($true) {
        $line = Read-Host ('  ' + (Paint 'calc' 'Accent' -Bold))
        if ($null -eq $line -or -not $line.Trim() -or $line.Trim() -in 'q', 'quit', 'exit', 'quitter', 'sortir') { break }
        try {
            $r = Invoke-Calc $line
            $script:Ans = $r.Value
            Write-CalcResult $r
            if ($Copy) { Copy-CalcResult $r }
        }
        catch { Write-PstStatus err $_.Exception.Message }
        Write-Host ''
    }
    exit 0
}

# ── Calcul unique ────────────────────────────────────────────────────────────

try { $result = Invoke-Calc ($parts -join ' ') }
catch {
    if ($Json) { [ordered]@{ Input = ($parts -join ' '); Error = $_.Exception.Message } | ConvertTo-Json }
    else { Write-PstStatus err $_.Exception.Message }
    exit 1
}

if ($Json) {
    $result | ConvertTo-Json -Depth 4
    if ($Copy) { Copy-CalcResult $result | Out-Null }
    exit 0
}
Write-Host ''
Write-CalcResult $result
if ($Copy) { Copy-CalcResult $result }
Write-Host ''
exit 0
