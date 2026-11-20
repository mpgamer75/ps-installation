# ─────────────────────────────────────────────────────────────────────────────
#  ps-tools — bibliothèque partagée (interface, couleurs, utilitaires)
#  Chargée par chaque outil :  . "$PSScriptRoot\..\lib\PsTools.ps1"
#  Compatible Windows PowerShell 5.1 et PowerShell 7+.
# ─────────────────────────────────────────────────────────────────────────────

$script:Pst = @{
    Version   = '2.4.0'
    Repo      = 'mpgamer75/ps-installation'
    Esc       = [string][char]27
    # PSTOOLS_TEST_WINDOWS : réservé aux tests, pour exercer le rendu hors Windows avec des données simulées.
    IsWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or [bool]$IsWindows -or [bool]$env:PSTOOLS_TEST_WINDOWS
    Ansi      = $false
    Glyph     = @{}
    Theme     = @{}
    ThemeName = 'cyan'
    Lang      = 'fr'
    # Dossier de la bibliothèque (vide quand elle est chargée depuis le web par l'amorce).
    LibDir    = $PSScriptRoot
}
$script:PstStrings = @{}       # toutes les traductions (repli)
$script:PstStringSets = @{}    # une table par dictionnaire : le contexte de chaque fichier prime

# Palettes : chaque outil n'utilise que ces sept rôles de couleur.
$script:PstThemes = [ordered]@{
    # Rôles : Accent, Accent2, Ok, Warn, Err, Dim, Title (texte) ; Secondary (texte secondaire) ;
    # Border (cadres) ; Selected (fond de la ligne choisie) ; Surface / Raised (fonds des panneaux).
    cyan  = @{ Label = 'Cyan'; Hint = 'défaut · panneaux sombres, accent cyan'
        Accent = @(34, 211, 238); Accent2 = @(167, 139, 250); Ok = @(52, 211, 153); Warn = @(251, 191, 36); Err = @(248, 113, 113)
        Dim = @(100, 116, 139); Title = @(230, 241, 255); Secondary = @(159, 178, 204); Border = @(56, 70, 99); Selected = @(32, 50, 81); Surface = @(13, 18, 32); Raised = @(18, 26, 43) }
    nuit  = @{ Label = 'Nuit'; Hint = 'bleu et violet, fond sombre'
        Accent = @(86, 182, 255); Accent2 = @(178, 132, 255); Ok = @(80, 220, 140); Warn = @(255, 190, 80); Err = @(255, 95, 110)
        Dim = @(125, 133, 150); Title = @(240, 244, 255); Secondary = @(170, 178, 196); Border = @(80, 88, 110); Selected = @(38, 46, 74); Surface = @(16, 18, 28); Raised = @(24, 27, 40) }
    ocean = @{ Label = 'Océan'; Hint = 'turquoise et bleu, fond sombre'
        Accent = @(64, 200, 224); Accent2 = @(96, 140, 255); Ok = @(70, 220, 170); Warn = @(255, 200, 90); Err = @(255, 100, 120)
        Dim = @(120, 140, 160); Title = @(230, 245, 255); Secondary = @(160, 185, 205); Border = @(60, 92, 112); Selected = @(22, 58, 74); Surface = @(8, 22, 30); Raised = @(14, 32, 42) }
    ambre = @{ Label = 'Ambre'; Hint = 'tons chauds, fond sombre'
        Accent = @(255, 176, 59); Accent2 = @(255, 122, 89); Ok = @(170, 220, 110); Warn = @(255, 214, 102); Err = @(255, 92, 82)
        Dim = @(150, 140, 125); Title = @(255, 242, 224); Secondary = @(205, 190, 168); Border = @(110, 92, 70); Selected = @(70, 52, 30); Surface = @(24, 18, 12); Raised = @(34, 26, 18) }
    clair = @{ Label = 'Clair'; Hint = 'pour les terminaux à fond blanc'
        Accent = @(0, 105, 190); Accent2 = @(125, 60, 200); Ok = @(0, 135, 70); Warn = @(175, 100, 0); Err = @(200, 35, 55)
        Dim = @(105, 112, 128); Title = @(25, 30, 40); Secondary = @(70, 78, 95); Border = @(170, 178, 192); Selected = @(214, 228, 245); Surface = @(248, 250, 252); Raised = @(238, 242, 247) }
    mono  = @{ Label = 'Mono'; Hint = 'nuances de gris, sobre'
        Accent = @(215, 215, 215); Accent2 = @(175, 175, 175); Ok = @(200, 200, 200); Warn = @(235, 235, 235); Err = @(255, 255, 255)
        Dim = @(120, 120, 120); Title = @(250, 250, 250); Secondary = @(185, 185, 185); Border = @(95, 95, 95); Selected = @(60, 60, 60); Surface = @(20, 20, 20); Raised = @(30, 30, 30) }
}

function Get-PstThemeText {
    # Nom et description d'un thème dans la langue choisie : @{ Label; Hint }.
    param([string]$Name)
    switch ($Name) {
        'cyan' { return @{ Label = 'Cyan'; Hint = (L 'défaut · panneaux sombres, accent cyan') } }
        'nuit' { return @{ Label = (L 'Nuit'); Hint = (L 'bleu et violet, fond sombre') } }
        'ocean' { return @{ Label = (L 'Océan'); Hint = (L 'turquoise et bleu, fond sombre') } }
        'ambre' { return @{ Label = (L 'Ambre'); Hint = (L 'tons chauds, fond sombre') } }
        'clair' { return @{ Label = (L 'Clair'); Hint = (L 'pour les terminaux à fond blanc') } }
        'mono' { return @{ Label = 'Mono'; Hint = (L 'nuances de gris, sobre') } }
    }
    return @{ Label = $Name; Hint = '' }
}

function Set-PstTheme {
    # Applique une palette pour la session en cours (sans l'enregistrer).
    param([string]$Name)
    if (-not $Name -or -not $script:PstThemes.Contains($Name)) { $Name = 'cyan' }
    $script:Pst.ThemeName = $Name
    $script:Pst.Theme = $script:PstThemes[$Name]
}

function Initialize-PstConsole {
    # Détecte les capacités du terminal : séquences ANSI et jeu de glyphes.
    $ansi = $false
    try { $ansi = [bool]$Host.UI.SupportsVirtualTerminal } catch { $ansi = $false }
    try { if ([Console]::IsOutputRedirected) { $ansi = $false } } catch { $ansi = $false }
    if ($env:NO_COLOR) { $ansi = $false }
    if ($env:PSTOOLS_FORCE_COLOR) { $ansi = $true }
    $script:Pst.Ansi = $ansi

    $theme = $env:PSTOOLS_THEME
    if (-not $theme) { try { $theme = [string](Get-PstConfig).theme } catch { $theme = $null } }
    Set-PstTheme $theme

    $script:Pst.Lang = Get-PstLanguage
    Import-PstStrings 'PsTools'

    if ($env:PSTOOLS_ASCII) {
        $script:Pst.Glyph = @{
            H = '-'; V = '|'; TL = '+'; TR = '+'; BL = '+'; BR = '+'
            Full = '#'; Empty = '.'; Ok = 'v'; Err = 'x'; Warn = '!'; Info = '*'
            Pointer = '>'; Dot = '-'; Up = '^'; Down = 'v'; Ellipsis = '~'
            On = '[x]'; Off = '[ ]'; Lock = '[admin]'; Bullet = '*'; Hollow = 'o'; Sep = '|'
            Spark = @('_', '_', '.', '.', '-', '-', '=', '#')
        }
    }
    else {
        $script:Pst.Glyph = @{
            H = '─'; V = '│'; TL = '╭'; TR = '╮'; BL = '╰'; BR = '╯'
            Full = '█'; Empty = '░'; Ok = '√'; Err = '×'; Warn = '!'; Info = '•'
            Pointer = '►'; Dot = '·'; Up = '↑'; Down = '↓'; Ellipsis = '…'
            On = '[■]'; Off = '[ ]'; Lock = '[admin]'; Bullet = '●'; Hollow = '○'; Sep = '│'
            Spark = @('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█')
        }
        # Windows Terminal, VS Code et les terminaux Unix ont une police de secours pour ✓ ✗ ▸ ;
        # l'ancienne console Windows (conhost + Consolas) garde √ × ►.
        if ($env:WT_SESSION -or $env:TERM_PROGRAM -or -not $script:Pst.IsWindows -or $env:PSTOOLS_RICH) {
            $script:Pst.Glyph.Ok = '✓'; $script:Pst.Glyph.Err = '✗'; $script:Pst.Glyph.Pointer = '▸'
        }
    }
}

# ── Couleurs ─────────────────────────────────────────────────────────────────

function Paint {
    # Retourne le texte coloré (ou brut si le terminal ne gère pas l'ANSI).
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Text = '',
        [Parameter(Position = 1)]$Color = $null,
        [switch]$Bold,
        $Bg = $null
    )
    if (-not $script:Pst.Ansi -or $Text.Length -eq 0) { return $Text }
    $rgb = $null
    if ($Color -is [string]) { $rgb = $script:Pst.Theme[$Color] }
    elseif ($Color) { $rgb = $Color }
    $back = $null
    if ($Bg -is [string]) { $back = $script:Pst.Theme[$Bg] } elseif ($Bg) { $back = $Bg }
    $codes = @()
    if ($Bold) { $codes += '1' }
    if ($rgb) { $codes += ('38;2;{0};{1};{2}' -f [int]$rgb[0], [int]$rgb[1], [int]$rgb[2]) }
    if ($back) { $codes += ('48;2;{0};{1};{2}' -f [int]$back[0], [int]$back[1], [int]$back[2]) }
    if ($codes.Count -eq 0) { return $Text }
    $e = $script:Pst.Esc
    return ('{0}[{1}m{2}{0}[0m' -f $e, ($codes -join ';'), $Text)
}

function Format-PstGradient {
    # Dégradé horizontal entre deux couleurs ; -Span fixe la largeur de référence.
    param([string]$Text, $From = 'Accent', $To = 'Accent2', [int]$Span = 0, [switch]$Bold)
    if (-not $script:Pst.Ansi) { return $Text }
    if ($From -is [string]) { $From = $script:Pst.Theme[$From] }
    if ($To -is [string]) { $To = $script:Pst.Theme[$To] }
    if ($Span -le 1) { $Span = [Math]::Max($Text.Length, 2) }
    $e = $script:Pst.Esc
    $sb = New-Object System.Text.StringBuilder
    if ($Bold) { [void]$sb.Append("$e[1m") }
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($ch -eq ' ') { [void]$sb.Append(' '); continue }
        $t = [Math]::Min($i / ($Span - 1), 1)
        $r = [int]($From[0] + ($To[0] - $From[0]) * $t)
        $g = [int]($From[1] + ($To[1] - $From[1]) * $t)
        $b = [int]($From[2] + ($To[2] - $From[2]) * $t)
        [void]$sb.Append("$e[38;2;$r;$g;${b}m$ch")
    }
    [void]$sb.Append("$e[0m")
    return $sb.ToString()
}

function Get-PstLevelColor {
    # Vert / orange / rouge selon un pourcentage d'utilisation.
    param([double]$Percent, [double]$Warn = 70, [double]$Crit = 90)
    if ($Percent -ge $Crit) { return 'Err' }
    if ($Percent -ge $Warn) { return 'Warn' }
    return 'Ok'
}

# ── Mise en forme de texte ───────────────────────────────────────────────────

function Get-PstVisibleLength {
    param([AllowEmptyString()][string]$Text = '')
    return ($Text -replace "$([char]27)\[[0-9;?]*[A-Za-z]", '').Length
}

function Format-PstPad {
    # Complète à la largeur visible voulue (les codes couleur ne comptent pas).
    param([AllowEmptyString()][string]$Text = '', [int]$Width, [switch]$Right)
    $missing = $Width - (Get-PstVisibleLength $Text)
    if ($missing -le 0) { return $Text }
    if ($Right) { return (' ' * $missing) + $Text }
    return $Text + (' ' * $missing)
}

function Limit-PstText {
    # Tronque un texte brut avec une ellipse.
    param([AllowEmptyString()][string]$Text = '', [int]$Width)
    if ($Width -le 0) { return '' }
    if ($Text.Length -le $Width) { return $Text }
    if ($Width -eq 1) { return $script:Pst.Glyph.Ellipsis }
    return $Text.Substring(0, $Width - 1) + $script:Pst.Glyph.Ellipsis
}

function Format-PstSize {
    param([double]$Bytes)
    $units = 'o', 'Ko', 'Mo', 'Go', 'To', 'Po'
    if ($script:Pst.Lang -eq 'en') { $units = 'B', 'KB', 'MB', 'GB', 'TB', 'PB' }
    $i = 0
    $value = [Math]::Abs($Bytes)
    while ($value -ge 1024 -and $i -lt $units.Count - 1) { $value /= 1024; $i++ }
    if ($i -eq 0) { return ('{0:N0} {1}' -f $value, $units[$i]) }
    return ('{0:N1} {1}' -f $value, $units[$i])
}

function Format-PstDuration {
    param([TimeSpan]$Span)
    if ($Span.TotalSeconds -lt 0) { $Span = $Span.Negate() }
    $day = 'j'
    if ($script:Pst.Lang -eq 'en') { $day = 'd' }
    if ($Span.TotalDays -ge 1) { return ('{0}{3} {1}h {2:00}m' -f [int][Math]::Floor($Span.TotalDays), $Span.Hours, $Span.Minutes, $day) }
    if ($Span.TotalHours -ge 1) { return ('{0}h {1:00}m' -f $Span.Hours, $Span.Minutes) }
    if ($Span.TotalMinutes -ge 1) { return ('{0}m {1:00}s' -f $Span.Minutes, $Span.Seconds) }
    return ('{0}s' -f $Span.Seconds)
}

function Format-PstBar {
    # Barre de progression colorée selon le niveau (ou -Color imposée).
    param([double]$Percent, [int]$Width = 24, $Color = $null)
    if ([double]::IsNaN($Percent)) { $Percent = 0 }
    $Percent = [Math]::Max(0, [Math]::Min(100, $Percent))
    $filled = [int][Math]::Round($Percent * $Width / 100)
    if ($Percent -gt 0 -and $filled -eq 0) { $filled = 1 }
    if (-not $Color) { $Color = Get-PstLevelColor $Percent }
    $g = $script:Pst.Glyph
    return (Paint ($g.Full * $filled) $Color) + (Paint ($g.Empty * ($Width - $filled)) 'Dim')
}

function Format-PstSparkline {
    # Mini-graphique d'historique ; les valeurs $null (pertes) deviennent des trous.
    param([object[]]$Values = @(), [int]$Width = 20, [double]$Max = 0)
    $spark = $script:Pst.Glyph.Spark
    $list = @($Values)
    if ($list.Count -gt $Width) { $list = $list[($list.Count - $Width)..($list.Count - 1)] }
    if ($Max -le 0) {
        foreach ($v in $list) { if ($null -ne $v -and [double]$v -gt $Max) { $Max = [double]$v } }
    }
    if ($Max -le 0) { $Max = 1 }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(' ' * ($Width - $list.Count))
    foreach ($v in $list) {
        if ($null -eq $v) { [void]$sb.Append(' '); continue }
        $idx = [int][Math]::Floor(([Math]::Min([double]$v, $Max) / $Max) * ($spark.Count - 1))
        [void]$sb.Append($spark[$idx])
    }
    return $sb.ToString()
}

function Format-PstBox {
    # Encadré à coins arrondis ; retourne les lignes prêtes à afficher.
    param([string]$Title = '', [string[]]$Lines = @(), [int]$Width = 0, $Color = 'Border')
    $g = $script:Pst.Glyph
    if ($Width -le 0) {
        $Width = (Get-PstVisibleLength $Title) + 6
        foreach ($l in $Lines) { $Width = [Math]::Max($Width, (Get-PstVisibleLength $l) + 4) }
    }
    $inner = $Width - 2
    $out = @()
    if ($Title) {
        $Title = $Title.ToUpper()
        $rest = [Math]::Max($inner - (Get-PstVisibleLength $Title) - 3, 0)
        $titleColor = 'Accent'
        if ($Color -ne 'Border' -and $Color -ne 'Dim') { $titleColor = $Color }
        $out += (Paint ($g.TL + $g.H + ' ') $Color) + (Paint $Title $titleColor -Bold) + (Paint (' ' + ($g.H * $rest) + $g.TR) $Color)
    }
    else {
        $out += Paint ($g.TL + ($g.H * $inner) + $g.TR) $Color
    }
    foreach ($l in $Lines) {
        $out += (Paint $g.V $Color) + ' ' + (Format-PstPad $l ($inner - 2)) + ' ' + (Paint $g.V $Color)
    }
    $out += Paint ($g.BL + ($g.H * $inner) + $g.BR) $Color
    return $out
}

function Format-PstTable {
    # Tableau simple. Colonnes : @{ Name; Width; Right }. Lignes : tableaux de chaînes.
    param([hashtable[]]$Columns, [object[]]$Rows = @())
    $out = @()
    $head = ''
    foreach ($c in $Columns) { $head += (Format-PstPad $c.Name $c.Width -Right:([bool]$c.Right)) + '  ' }
    $out += Paint $head.TrimEnd() 'Accent' -Bold
    foreach ($row in $Rows) {
        $line = ''
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $cell = [string]@($row)[$i]
            $line += (Format-PstPad $cell $Columns[$i].Width -Right:([bool]$Columns[$i].Right)) + '  '
        }
        $out += $line.TrimEnd()
    }
    return $out
}

# ── Sortie ───────────────────────────────────────────────────────────────────

function Write-PstLine {
    param([Parameter(ValueFromPipeline = $true)][AllowEmptyString()][string]$Text = '')
    process { Write-Host $Text }
}

function Write-PstStatus {
    param(
        [Parameter(Position = 0)][ValidateSet('ok', 'warn', 'err', 'info', 'step')][string]$Level = 'info',
        [Parameter(Position = 1)][string]$Message
    )
    $g = $script:Pst.Glyph
    switch ($Level) {
        'ok'   { $mark = Paint $g.Ok 'Ok' -Bold }
        'warn' { $mark = Paint $g.Warn 'Warn' -Bold }
        'err'  { $mark = Paint $g.Err 'Err' -Bold }
        'step' { $mark = Paint $g.Pointer 'Accent' }
        default { $mark = Paint $g.Info 'Accent2' }
    }
    Write-Host ("  $mark $Message")
}

function Get-PstWidth {
    param([int]$Max = 100, [int]$Min = 60)
    $w = 80
    try { $w = $Host.UI.RawUI.WindowSize.Width } catch { $w = 80 }
    if (-not $w -or $w -le 0) { $w = 80 }
    return [Math]::Max($Min, [Math]::Min($Max, $w - 1))
}

function Get-PstBanner {
    # Logo original ps-tools : un prompt « >_ » suivi du nom en lettres pleines.
    if ($env:PSTOOLS_ASCII) {
        return @('', '   >_  P S - T O O L S', '')
    }
    $art = @(
        ' ██▄         █████▄ ▄█████       ██████ ▄████▄ ▄████▄ ██     ▄█████'
        '  ▀██▄       ██  ██ ██             ██   ██  ██ ██  ██ ██     ██    '
        '    ▀██▄     █████▀ ▀████▄ ▄▄▄▄    ██   ██  ██ ██  ██ ██     ▀████▄'
        '  ▄██▀       ██         ██         ██   ██  ██ ██  ██ ██         ██'
        ' ██▀  ▄▄▄▄▄  ██     █████▀         ██   ▀████▀ ▀████▀ ██████ █████▀'
    )
    $span = 0
    foreach ($l in $art) { $span = [Math]::Max($span, $l.Length) }
    $out = @('')
    foreach ($l in $art) { $out += Format-PstGradient $l -Span $span }
    return $out
}

function Show-PstBanner {
    param([string]$Tagline)
    if (-not $Tagline) { $Tagline = L 'La boîte à outils du terminal Windows' }
    Get-PstBanner | Write-PstLine
    $mode = L 'mode utilisateur'
    if (Test-PstAdmin) { $mode = L 'mode administrateur' }
    Write-Host ('  ' + (Paint $Tagline 'Title') + (Paint ("  $($script:Pst.Glyph.Dot)  v$($script:Pst.Version)  $($script:Pst.Glyph.Dot)  $mode") 'Dim'))
    Write-Host ''
}

function Get-PstHeaderLine {
    # Bandeau compact affiché en tête de chaque outil.
    param([string]$Tool, [string]$Subtitle = '', [int]$Width = 0)
    if ($Width -le 0) { $Width = Get-PstWidth }
    $g = $script:Pst.Glyph
    # Style « barre de titre » : ▸ ps-tools │ OUTIL · précision           ● mode
    $left = (Paint "$($g.Pointer) " 'Accent') + (Paint 'ps-tools' 'Title' -Bold) + (Paint " $($g.Sep) " 'Border') + (Paint $Tool.ToUpper() 'Accent' -Bold)
    if ($Subtitle) { $left += Paint "  $($g.Dot) $Subtitle" 'Secondary' }
    $mode = L 'utilisateur'
    $modeColor = 'Ok'
    if (Test-PstAdmin) { $mode = L 'admin'; $modeColor = 'Warn' }
    $right = (Paint "v$($script:Pst.Version)  " 'Dim') + (Paint $g.Bullet $modeColor) + ' ' + (Paint $mode 'Secondary')
    $gap = $Width - (Get-PstVisibleLength $left) - (Get-PstVisibleLength $right)
    if ($gap -lt 2) { return $left }
    return $left + (' ' * $gap) + $right
}

function Format-PstKeyBar {
    # Barre « KEYS » : @(@('↑↓', 'naviguer'), @('Entrée', 'valider')) ; -Bar ajoute le fond.
    param([object[]]$Keys, [switch]$Bar, [int]$Width = 0)
    $g = $script:Pst.Glyph
    if ($Keys.Count -and $Keys[0] -is [string]) { $Keys = , $Keys }   # une seule paire
    if ($Bar -and $script:Pst.Ansi) {
        $plain = ' ' + (L 'TOUCHES') + '  ' + (($Keys | ForEach-Object { "$($_[0]) $($_[1])" }) -join " $($g.Sep) ")
        if ($Width -gt 0) { $plain = Format-PstPad (Limit-PstText $plain $Width) $Width }
        return (Paint $plain 'Title' -Bold -Bg 'Selected')
    }
    $parts = @($Keys | ForEach-Object { (Paint $_[0] 'Accent') + ' ' + (Paint $_[1] 'Dim') })
    return ((Paint (L 'TOUCHES') 'Dim' -Bold) + '  ' + ($parts -join (Paint " $($g.Sep) " 'Border')))
}

function Show-PstHeader {
    param([string]$Tool, [string]$Subtitle = '')
    Write-Host ''
    Write-Host (' ' + (Get-PstHeaderLine -Tool $Tool -Subtitle $Subtitle -Width ((Get-PstWidth) - 1)))
    Write-Host ''
}

function Show-PstHelp {
    # Aide homogène pour tous les outils.
    param(
        [string]$Name, [string]$Synopsis, [string[]]$Usage = @(),
        [object[]]$Options = @(), [string[]]$Examples = @(), [string[]]$Notes = @()
    )
    Show-PstHeader -Tool $Name -Subtitle (L 'aide')
    Write-Host "  $Synopsis"
    Write-Host ''
    if ($Usage.Count) {
        Write-Host ('  ' + (Paint (L 'UTILISATION') 'Accent' -Bold))
        foreach ($u in $Usage) { Write-Host "    $u" }
        Write-Host ''
    }
    if ($Options.Count) {
        Write-Host ('  ' + (Paint (L 'OPTIONS') 'Accent' -Bold))
        $w = 0
        foreach ($o in $Options) { $w = [Math]::Max($w, ([string]$o[0]).Length) }
        foreach ($o in $Options) { Write-Host ('    ' + (Paint (([string]$o[0]).PadRight($w)) 'Title') + '  ' + (Paint ([string]$o[1]) 'Dim')) }
        Write-Host ''
    }
    if ($Examples.Count) {
        Write-Host ('  ' + (Paint (L 'EXEMPLES') 'Accent' -Bold))
        foreach ($x in $Examples) { Write-Host ('    ' + (Paint $x 'Ok')) }
        Write-Host ''
    }
    foreach ($n in $Notes) { Write-Host ('  ' + (Paint $n 'Dim')) }
    if ($Notes.Count) { Write-Host '' }
}

function Test-PstHelpArg {
    # Vrai si l'utilisateur a demandé l'aide façon Unix (--help, -h, /?).
    param([object[]]$Arguments = @())
    foreach ($a in $Arguments) {
        if (@('--help', '-h', '/?', '-?', 'help') -contains [string]$a) { return $true }
    }
    return $false
}

# ── Écran plein (outils temps réel) ──────────────────────────────────────────

function Start-PstScreen {
    # Bascule sur l'écran alternatif et masque le curseur.
    if ($script:Pst.Ansi) { Write-Host "$($script:Pst.Esc)[?1049h$($script:Pst.Esc)[?25l$($script:Pst.Esc)[H" -NoNewline }
    else { try { Clear-Host } catch { $null = $_ } }
    try { [Console]::TreatControlCAsInput = $true } catch { $null = $_ }
}

function Stop-PstScreen {
    try { [Console]::TreatControlCAsInput = $false } catch { $null = $_ }
    if ($script:Pst.Ansi) { Write-Host "$($script:Pst.Esc)[?25h$($script:Pst.Esc)[?1049l" -NoNewline }
}

function Write-PstFrame {
    # Redessine tout l'écran sans scintillement.
    param([string[]]$Lines)
    if ($script:Pst.Ansi) {
        $e = $script:Pst.Esc
        $max = 0
        try { $max = $Host.UI.RawUI.WindowSize.Height - 1 } catch { $max = 0 }
        if ($max -gt 0 -and $Lines.Count -gt $max) { $Lines = $Lines[0..($max - 1)] }
        Write-Host ("$e[H" + ($Lines -join "$e[K`n") + "$e[K$e[J") -NoNewline
    }
    else {
        try { Clear-Host } catch { $null = $_ }
        $Lines | Write-PstLine
    }
}

# ── Saisie ───────────────────────────────────────────────────────────────────

function Test-PstInteractive {
    try { return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) }
    catch { return $false }
}

function Read-PstKey {
    # Attend une touche au plus -TimeoutMs millisecondes ; $null si aucune.
    param([int]$TimeoutMs = 1000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) }
            Start-Sleep -Milliseconds 40
        }
    }
    catch {
        $rest = ($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($rest -gt 0) { Start-Sleep -Milliseconds ([int]$rest) }
    }
    return $null
}

function Test-PstQuitKey {
    param($Key)
    if ($null -eq $Key) { return $false }
    if ($Key.Key -eq 'Q' -or $Key.Key -eq 'Escape') { return $true }
    if ($Key.Key -eq 'C' -and ($Key.Modifiers -band [ConsoleModifiers]::Control)) { return $true }
    return $false
}

function Read-PstConfirm {
    param([string]$Question, [switch]$DefaultYes)
    if (-not (Test-PstInteractive)) { return [bool]$DefaultYes }
    # Pas de dictionnaire ici : « [o/N] » et « [O/n] » ne diffèrent que par la casse.
    $yes = 'o'; if ($script:Pst.Lang -eq 'en') { $yes = 'y' }
    $hint = "[$yes/N]"
    if ($DefaultYes) { $hint = "[$($yes.ToUpper())/n]" }
    $answer = Read-Host ("  $(Paint '?' 'Accent' -Bold) $Question $hint")
    if ([string]::IsNullOrWhiteSpace($answer)) { return [bool]$DefaultYes }
    return ($answer.Trim() -match '^(o|oui|y|yes|ok)$')
}

function Read-PstChoice {
    # Menu à flèches. Retourne l'index choisi, ou -1 si annulé (Échap).
    # -Hints : courte précision affichée en gris après chaque entrée.
    param([string]$Title, [string[]]$Items, [int]$Default = 0, [string[]]$Hints = @())
    $g = $script:Pst.Glyph
    if ($Title) { Write-Host ("  $(Paint '?' 'Accent' -Bold) " + (Paint $Title 'Title' -Bold)) }
    $labelWidth = 0
    foreach ($item in $Items) { $labelWidth = [Math]::Max($labelWidth, (Get-PstVisibleLength $item)) }
    $hintOf = {
        param([int]$i)
        if ($i -ge $Hints.Count -or -not $Hints[$i]) { return '' }
        $h = $Hints[$i]
        if ($h.Contains($script:Pst.Esc)) { return '  ' + $h }
        return '  ' + (Paint $h 'Dim')
    }

    if (-not $script:Pst.Ansi -or -not (Test-PstInteractive)) {
        for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host (("    {0}. " -f ($i + 1)) + (Format-PstPad $Items[$i] $labelWidth) + (& $hintOf $i)) }
        if (-not (Test-PstInteractive)) { return $Default }
        $answer = Read-Host ('  ' + (L 'Votre choix'))
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Items.Count) { return ([int]$answer - 1) }
        return -1
    }

    $e = $script:Pst.Esc
    $index = [Math]::Max(0, [Math]::Min($Default, $Items.Count - 1))
    $barWidth = 0
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $w = $labelWidth + 4
        if ($i -lt $Hints.Count -and $Hints[$i]) { $w += 2 + (Get-PstVisibleLength $Hints[$i]) }
        $barWidth = [Math]::Max($barWidth, $w + 1)
    }
    $barWidth = [Math]::Min($barWidth, (Get-PstWidth -Max 120) - 4)
    Write-Host "$e[?25l" -NoNewline
    try {
        while ($true) {
            for ($i = 0; $i -lt $Items.Count; $i++) {
                $label = Format-PstPad $Items[$i] $labelWidth
                if ($i -eq $index) {
                    # Ligne choisie : barre pleine largeur sur fond « Selected ».
                    $hint = ''
                    if ($i -lt $Hints.Count -and $Hints[$i]) { $hint = '  ' + ($Hints[$i] -replace "$e\[[0-9;]*m", '') }
                    $bar = Format-PstPad " $($g.Pointer) $label$hint " ([Math]::Max(40, $barWidth))
                    Write-Host ('  ' + (Paint $bar 'Title' -Bold -Bg 'Selected') + "$e[K")
                }
                else { Write-Host ("     " + (Paint $label 'Secondary') + (& $hintOf $i) + "$e[K") }
            }
            Write-Host ('    ' + (Format-PstKeyBar @(@("$($g.Up)$($g.Down)", (L 'naviguer')), @((L 'Entrée'), (L 'valider')), @((L 'Échap'), (L 'annuler')))) + "$e[K")
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $index = ($index - 1 + $Items.Count) % $Items.Count }
                'DownArrow' { $index = ($index + 1) % $Items.Count }
                'Enter'     { return $index }
                'Escape'    { return -1 }
                default {
                    $n = 0
                    if ([int]::TryParse([string]$key.KeyChar, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return ($n - 1) }
                }
            }
            Write-Host "$e[$($Items.Count + 1)A" -NoNewline
        }
    }
    finally { Write-Host "$e[?25h" -NoNewline }
}

function Read-PstMultiChoice {
    # Cases à cocher. Retourne les index cochés (tableau), ou $null si annulé.
    param([string]$Title, [string[]]$Items, [bool[]]$Selected, [bool[]]$Disabled)
    $g = $script:Pst.Glyph
    $count = $Items.Count
    $state = New-Object 'bool[]' $count
    $locked = New-Object 'bool[]' $count
    for ($i = 0; $i -lt $count; $i++) {
        if ($Disabled -and $Disabled[$i]) { $locked[$i] = $true }
        elseif ($Selected -and $Selected[$i]) { $state[$i] = $true }
    }
    if ($Title) { Write-Host ("  $(Paint '?' 'Accent' -Bold) " + (Paint $Title 'Title' -Bold)) }

    if (-not $script:Pst.Ansi -or -not (Test-PstInteractive)) {
        for ($i = 0; $i -lt $count; $i++) {
            $mark = $g.Off
            if ($locked[$i]) { $mark = ' - ' } elseif ($state[$i]) { $mark = $g.On }
            Write-Host ("    {0,2}. {1} {2}" -f ($i + 1), $mark, $Items[$i])
        }
        if (Test-PstInteractive) {
            $answer = Read-Host ('  ' + (L 'Numéros séparés par des virgules (Entrée = sélection proposée, 0 = annuler)'))
            if ($answer.Trim() -eq '0') { return $null }
            if (-not [string]::IsNullOrWhiteSpace($answer)) {
                for ($i = 0; $i -lt $count; $i++) { $state[$i] = $false }
                foreach ($part in ($answer -split '[,; ]+')) {
                    if ($part -match '^\d+$' -and [int]$part -ge 1 -and [int]$part -le $count -and -not $locked[[int]$part - 1]) { $state[[int]$part - 1] = $true }
                }
            }
        }
        return @(0..($count - 1) | Where-Object { $state[$_] })
    }

    $e = $script:Pst.Esc
    $index = 0
    Write-Host "$e[?25l" -NoNewline
    try {
        while ($true) {
            for ($i = 0; $i -lt $count; $i++) {
                $cursor = '  '
                if ($i -eq $index) { $cursor = (Paint $g.Pointer 'Accent' -Bold) + ' ' }
                if ($locked[$i]) { $line = (Paint " -  $($Items[$i])" 'Dim') }
                elseif ($state[$i]) { $line = (Paint $g.On 'Ok') + ' ' + $Items[$i] }
                else { $line = (Paint $g.Off 'Dim') + ' ' + $Items[$i] }
                Write-Host ("    $cursor$line$e[K")
            }
            Write-Host ('    ' + (Format-PstKeyBar @(@("$($g.Up)$($g.Down)", (L 'naviguer')), @((L 'Espace'), (L 'cocher')), @('A', (L 'tout')), @((L 'Entrée'), (L 'valider')), @((L 'Échap'), (L 'annuler')))) + "$e[K")
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $index = ($index - 1 + $count) % $count }
                'DownArrow' { $index = ($index + 1) % $count }
                'Spacebar'  { if (-not $locked[$index]) { $state[$index] = -not $state[$index] } }
                'A' {
                    $all = $true
                    for ($i = 0; $i -lt $count; $i++) { if (-not $locked[$i] -and -not $state[$i]) { $all = $false } }
                    for ($i = 0; $i -lt $count; $i++) { if (-not $locked[$i]) { $state[$i] = -not $all } }
                }
                'Enter'  { return @(0..($count - 1) | Where-Object { $state[$_] }) }
                'Escape' { return $null }
            }
            Write-Host "$e[$($count + 1)A" -NoNewline
        }
    }
    finally { Write-Host "$e[?25h" -NoNewline }
}

function Wait-PstKey {
    param([string]$Message)
    if (-not $Message) { $Message = L 'Appuyez sur une touche pour continuer...' }
    if (-not (Test-PstInteractive)) { return }
    Write-Host ''
    Write-Host ('  ' + (Paint $Message 'Dim')) -NoNewline
    try { $null = [Console]::ReadKey($true) } catch { $null = $_ }
    Write-Host ''
}

# ── Système ──────────────────────────────────────────────────────────────────

function Test-PstAdmin {
    if ($null -ne $script:Pst.IsAdmin) { return $script:Pst.IsAdmin }
    $admin = $false
    try {
        if ($script:Pst.IsWindows) {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $admin = (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        else { $admin = ((& id -u) -eq '0') }
    }
    catch { $admin = $false }
    $script:Pst.IsAdmin = $admin
    return $admin
}

function Get-PstDataDir {
    # Données par utilisateur (rappels, préférences), quel que soit le mode d'installation.
    if ($env:PSTOOLS_DATA) { $dir = $env:PSTOOLS_DATA }
    elseif ($script:Pst.IsWindows -and $env:LOCALAPPDATA) { $dir = Join-Path (Join-Path $env:LOCALAPPDATA 'ps-tools') 'data' }
    else { $dir = Join-Path (Join-Path (Join-Path $HOME '.local') 'share') 'ps-tools' }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Assert-PstWindows {
    # Arrête proprement les outils qui dépendent d'API Windows.
    param([string]$Tool)
    if ($script:Pst.IsWindows) { return }
    Write-PstStatus err (L '{0} nécessite Windows.' $Tool)
    exit 1
}

function Start-PstElevated {
    # Relance un outil dans une fenêtre administrateur (invite UAC).
    param([string]$ScriptPath, [string[]]$Arguments = @())
    $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $ScriptPath)) + $Arguments
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $list | Out-Null
        return $true
    }
    catch {
        Write-PstStatus warn (L 'Élévation annulée ou impossible : {0}' $_.Exception.Message)
        return $false
    }
}

# ── Intégration au profil PowerShell ─────────────────────────────────────────

function Get-PstProfilePaths {
    # Profils « tous hôtes » de l'utilisateur, pour Windows PowerShell 5.1 et PowerShell 7.
    if ($env:PSTOOLS_PROFILE) { return @($env:PSTOOLS_PROFILE) }
    if (-not $script:Pst.IsWindows) { return @($PROFILE.CurrentUserAllHosts) }
    $documents = [Environment]::GetFolderPath('MyDocuments')
    if (-not $documents) { return @($PROFILE.CurrentUserAllHosts) }
    $paths = @((Join-Path (Join-Path $documents 'WindowsPowerShell') 'profile.ps1'))
    $core = Join-Path $documents 'PowerShell'
    if ($PSVersionTable.PSVersion.Major -ge 6 -or (Test-Path -LiteralPath $core) -or (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        $paths += Join-Path $core 'profile.ps1'
    }
    return $paths
}

function Read-PstProfile {
    # Retourne @{ Text; Encoding } en respectant l'encodage d'origine du fichier.
    param([string]$File)
    $encoding = New-Object System.Text.UTF8Encoding $true
    $text = ''
    if (Test-Path -LiteralPath $File) {
        $reader = New-Object IO.StreamReader $File, ([Text.Encoding]::Default), $true
        try { $text = $reader.ReadToEnd(); $encoding = $reader.CurrentEncoding } finally { $reader.Dispose() }
    }
    return @{ Text = $text; Encoding = $encoding }
}

function Remove-PstProfileBlock {
    param([string]$Text)
    return [regex]::Replace($Text, '(?s)\r?\n?# >>> ps-tools >>>.*?# <<< ps-tools <<<\r?\n?', "`r`n").Trim("`r", "`n")
}

function Test-PstShell {
    # Vrai si l'intégration est installée : bloc dans un profil, ou profil Windows Terminal dédié.
    if ($env:LOCALAPPDATA -and (Test-Path -LiteralPath (Get-PstTerminalFragmentPath))) { return $true }
    foreach ($file in (Get-PstProfilePaths)) {
        if ((Test-Path -LiteralPath $file) -and (Read-PstProfile $file).Text -match '# >>> ps-tools >>>') { return $true }
    }
    return $false
}

function Get-PstShellBlock {
    param([string]$AppRoot)
    $script = Join-Path (Join-Path $AppRoot 'shell') 'PsTools.Shell.ps1'
    return (@(
            '# >>> ps-tools >>>'
            '# Chargement de ps-tools dans le shell (retrait : pst shell off)'
            "`$pstShellScript = '$($script -replace "'", "''")'"
            'if (Test-Path -LiteralPath $pstShellScript) { . $pstShellScript }'
            'Remove-Variable pstShellScript -ErrorAction SilentlyContinue'
            '# <<< ps-tools <<<'
        ) -join "`r`n")
}

function Remove-PstShellBlockFrom {
    # Retire notre bloc d'un profil ; supprime le fichier s'il ne contenait que lui.
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return $false }
    $current = Read-PstProfile $File
    if ($current.Text -notmatch '# >>> ps-tools >>>') { return $false }
    $body = Remove-PstProfileBlock $current.Text
    if ($body.Trim()) { [IO.File]::WriteAllText($File, $body + "`r`n", $current.Encoding) }
    else { Remove-Item -LiteralPath $File -Force }
    return $true
}

function Enable-PstShell {
    # Ajoute (ou met à jour) le bloc de chargement dans chaque profil qui peut réellement
    # se charger. Retourne @{ Written = fichiers modifiés ; Blocked = profils refusés }.
    # Un profil bloqué ne reçoit pas le bloc (et en est retiré) : jamais d'erreur rouge au démarrage.
    param([string]$AppRoot, [switch]$NoProbe)
    $block = Get-PstShellBlock $AppRoot
    $result = @{ Written = @(); Blocked = @() }
    foreach ($file in (Get-PstProfilePaths)) {
        if (-not $NoProbe -and -not (Test-PstProfileLoadable $file)) {
            $null = Remove-PstShellBlockFrom $file
            $result.Blocked += $file
            continue
        }
        $current = Read-PstProfile $file
        $body = Remove-PstProfileBlock $current.Text
        if ($body) { $body += "`r`n`r`n" }
        $dir = Split-Path -Parent $file
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($file, $body + $block + "`r`n", $current.Encoding)
        $result.Written += $file
    }
    return $result
}

function Disable-PstShell {
    $changed = @()
    foreach ($file in (Get-PstProfilePaths)) { if (Remove-PstShellBlockFrom $file) { $changed += $file } }
    return $changed
}

function Get-PstEffectivePolicy {
    # Stratégie d'exécution réellement appliquée aux profils (hors portée Processus,
    # que les lanceurs ps-tools forcent à Bypass pour eux-mêmes).
    if (-not $script:Pst.IsWindows) { return 'Unrestricted' }
    try {
        foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
            $value = [string](Get-ExecutionPolicy -Scope $scope -ErrorAction Stop)
            if ($value -and $value -ne 'Undefined') { return $value }
        }
    }
    catch { return 'Unknown' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { return 'RemoteSigned' }
    return 'Restricted'
}

# ── Langue ───────────────────────────────────────────────────────────────────
# Le texte français sert de clé : L 'Texte {0}' $valeur affiche la traduction
# anglaise (dictionnaires i18n/en/<nom>.psd1) ou, à défaut, le français.

function Get-PstLanguage {
    # Ordre : PSTOOLS_LANG, réglage enregistré, langue de Windows (fr*, sinon en).
    $lang = $env:PSTOOLS_LANG
    if (-not $lang) { try { $lang = [string](Get-PstConfig).language } catch { $lang = $null } }
    if (-not $lang) {
        $lang = 'en'
        try { if ((Get-Culture).TwoLetterISOLanguageName -eq 'fr' -or (Get-UICulture).TwoLetterISOLanguageName -eq 'fr') { $lang = 'fr' } } catch { $null = $_ }
    }
    if ($lang -notin 'fr', 'en') { $lang = 'en' }
    return $lang
}

function Get-PstI18nPath {
    param([string]$Name)
    if (-not $script:Pst.LibDir) { return $null }
    return (Join-Path (Join-Path (Join-Path (Split-Path -Parent $script:Pst.LibDir) 'i18n') 'en') "$Name.psd1")
}

function Import-PstStrings {
    # Charge un dictionnaire anglais. -Text : contenu déjà lu (amorce depuis le web).
    param([string]$Name, [string]$Text)
    if ($script:Pst.Lang -eq 'fr' -or $script:PstStringSets.ContainsKey($Name)) { return }
    if (-not $Text) {
        $file = Get-PstI18nPath $Name
        if (-not $file -or -not (Test-Path -LiteralPath $file)) { return }
        $Text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    }
    try {
        # Fichier de données uniquement : le langage restreint interdit toute commande.
        $block = [scriptblock]::Create($Text.TrimStart([char]0xFEFF))
        $block.CheckRestrictedLanguage([string[]]@(), [string[]]@(), $false)
        $table = & $block
        $own = @{}
        foreach ($entry in $table.GetEnumerator()) {
            $own[[string]$entry.Key] = [string]$entry.Value
            if (-not $script:PstStrings.ContainsKey([string]$entry.Key)) { $script:PstStrings[[string]$entry.Key] = [string]$entry.Value }
        }
        $script:PstStringSets[$Name] = $own
    }
    catch { $null = $_ }
}

function L {
    # Traduit (si la langue est l'anglais) puis remplit les {0}, {1}...
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Text, [Parameter(Position = 1, ValueFromRemainingArguments = $true)][object[]]$Values)
    $out = $Text
    if ($script:Pst.Lang -ne 'fr') {
        # Ordre : dictionnaire du fichier appelant (ex. ask.ps1 -> ask), puis dictionnaire commun, puis tous.
        $caller = $MyInvocation.ScriptName
        $own = $null
        if ($caller) { $own = $script:PstStringSets[[IO.Path]::GetFileNameWithoutExtension($caller)] }
        $common = $script:PstStringSets['PsTools']
        if ($own -is [hashtable] -and $own.ContainsKey($Text)) { $out = $own[$Text] }
        elseif ($common -is [hashtable] -and $common.ContainsKey($Text)) { $out = $common[$Text] }
        elseif ($script:PstStrings.ContainsKey($Text)) { $out = $script:PstStrings[$Text] }
    }
    # Pas de « if ($Values) » : un tableau d'un seul 0 serait évalué comme faux.
    if ($null -ne $Values -and $Values.Count -gt 0) { return ($out -f $Values) }
    return $out
}

function Get-PstCulture {
    # Culture d'affichage des dates (noms de jours et de mois) selon la langue choisie.
    if ($script:Pst.Lang -eq 'en') { return [Globalization.CultureInfo]::GetCultureInfo('en-US') }
    return [Globalization.CultureInfo]::GetCultureInfo('fr-FR')
}

function Set-PstLanguage {
    param([string]$Lang)
    if ($Lang -notin 'fr', 'en') { $Lang = 'en' }
    $script:Pst.Lang = $Lang
    $script:PstStrings = @{}
    $loaded = @($script:PstStringSets.Keys)
    $script:PstStringSets = @{}
    foreach ($name in $loaded) { Import-PstStrings $name }
}


# ── Configuration et secrets ─────────────────────────────────────────────────
# config.json : préférences (thème, assistant IA, intégration au shell).
# secrets.json : clés d'API, chiffrées pour le compte Windows courant (DPAPI).

function ConvertTo-PstHashtable {
    # Convertit récursivement le résultat de ConvertFrom-Json (PowerShell 5.1 et 7).
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $table = @{}
        foreach ($p in $Value.PSObject.Properties) { $table[[string]$p.Name] = ConvertTo-PstHashtable $p.Value }
        return $table
    }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) { return , @($Value | ForEach-Object { ConvertTo-PstHashtable $_ }) }
    return $Value
}

function Merge-PstHashtable {
    # Recouvre $Base par $Override, clé par clé, sans perdre les valeurs par défaut.
    param([hashtable]$Base, [hashtable]$Override)
    # GetEnumerator plutôt que .Keys : une entrée nommée « keys » (réglage du shell)
    # masquerait sinon la propriété. Clés converties en [string] pour que ConvertTo-Json
    # accepte ensuite la table.
    foreach ($key in @($Override.GetEnumerator() | ForEach-Object { [string]$_.Key })) {
        if ($Base[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) { Merge-PstHashtable $Base[$key] $Override[$key] | Out-Null }
        else { $Base[$key] = $Override[$key] }
    }
    return $Base
}

function Read-PstJsonFile {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    try {
        $raw = [IO.File]::ReadAllText($File, [Text.Encoding]::UTF8)
        if (-not $raw.Trim()) { return $null }
        return (ConvertTo-PstHashtable ($raw | ConvertFrom-Json))
    }
    catch { return $null }
}

function Write-PstJsonFile {
    param([string]$File, $Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 8
    [IO.File]::WriteAllText($File, $json, (New-Object Text.UTF8Encoding $false))
}

function Get-PstConfig {
    # Toujours une configuration complète : valeurs par défaut recouvertes par config.json.
    $config = @{
        theme    = 'cyan'
        language = ''
        ai    = @{ provider = ''; model = ''; effort = 'low'; budget = 0; baseUrl = ''; prices = @{} }
        shell = @{ prompt = $true; keys = $true; aliases = $true; remedy = ''; trustedHost = ''; previousPolicy = '' }
    }
    $saved = Read-PstJsonFile (Join-Path (Get-PstDataDir) 'config.json')
    if ($saved -is [hashtable]) { $config = Merge-PstHashtable $config $saved }
    return $config
}

function Save-PstConfig {
    param([hashtable]$Config)
    Write-PstJsonFile (Join-Path (Get-PstDataDir) 'config.json') $Config
}

function Set-PstSecret {
    # Enregistre (ou efface avec une valeur vide) une clé, chiffrée pour ce compte Windows.
    # La clé arrive en clair (saisie masquée puis vérifiée auprès du service) : elle n'est
    # écrite sur disque qu'après chiffrement DPAPI par ConvertFrom-SecureString.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '')]
    param([string]$Name, [string]$Value)
    $file = Join-Path (Get-PstDataDir) 'secrets.json'
    $secrets = Read-PstJsonFile $file
    if ($secrets -isnot [hashtable]) { $secrets = @{} }
    if ([string]::IsNullOrEmpty($Value)) { $secrets.Remove($Name) }
    else { $secrets[$Name] = ConvertFrom-SecureString -SecureString (ConvertTo-SecureString -String $Value -AsPlainText -Force) }
    Write-PstJsonFile $file $secrets
}

function Get-PstSecret {
    param([string]$Name)
    $secrets = Read-PstJsonFile (Join-Path (Get-PstDataDir) 'secrets.json')
    if ($secrets -isnot [hashtable] -or -not $secrets[$Name]) { return $null }
    try {
        $secure = ConvertTo-SecureString -String ([string]$secrets[$Name]) -ErrorAction Stop
        return (New-Object System.Net.NetworkCredential '', $secure).Password
    }
    catch { return $null }   # chiffrée par un autre compte ou une autre machine
}

# ── Composants d'assistant (wizard) ──────────────────────────────────────────

function Format-PstWrap {
    # Coupe un texte en lignes de largeur visible maximale.
    param([string]$Text, [int]$Width = 72)
    $lines = @()
    foreach ($paragraph in ($Text -split "`n")) {
        $line = ''
        foreach ($word in ($paragraph -split ' ')) {
            if (-not $line) { $line = $word }
            elseif ((Get-PstVisibleLength $line) + 1 + (Get-PstVisibleLength $word) -le $Width) { $line += ' ' + $word }
            else { $lines += $line; $line = $word }
        }
        $lines += $line
    }
    return $lines
}

function Show-PstWizardFrame {
    # Écran d'étape : logo compact, fil d'Ariane des étapes, titre et explication.
    param([string[]]$Steps, [int]$Current, [string]$Title, [string]$Text = '', [string]$Caption)
    if (-not $Caption) { $Caption = L 'assistant d''installation' }
    $g = $script:Pst.Glyph
    $interactive = (Test-PstInteractive) -and $script:Pst.Ansi
    if ($interactive) { try { Clear-Host } catch { $null = $_ } }
    $width = Get-PstWidth -Max 90
    Write-Host ''
    Write-Host (' ' + (Paint "$($g.Pointer) " 'Accent') + (Paint 'ps-tools' 'Title' -Bold) + (Paint " $($g.Sep) " 'Border') + (Paint $Caption.ToUpper() 'Accent' -Bold) + (Paint "   v$($script:Pst.Version)" 'Dim'))
    Write-Host ''

    if ($Steps.Count -gt 1) {
        $done = '●'; $here = '◉'; $todo = '○'
        if ($env:PSTOOLS_ASCII) { $done = '*'; $here = '>'; $todo = 'o' }
        $parts = @()
        for ($i = 0; $i -lt $Steps.Count; $i++) {
            if ($i -lt $Current) { $parts += (Paint $done 'Ok') + ' ' + (Paint $Steps[$i] 'Secondary') }
            elseif ($i -eq $Current) { $parts += Paint " $here $($Steps[$i]) " 'Accent' -Bold -Bg 'Selected' }
            else { $parts += (Paint $todo 'Dim') + ' ' + (Paint $Steps[$i] 'Dim') }
        }
        $trail = ' ' + ($parts -join (Paint " $($g.H) " 'Dim'))
        if ((Get-PstVisibleLength $trail) -gt $width) {
            $trail = ' ' + (Paint (L 'Étape {0}/{1}' ($Current + 1) $Steps.Count) 'Accent' -Bold) + (Paint "  $($g.Dot)  $($Steps[$Current])" 'Dim')
        }
        Write-Host $trail
        Write-Host (' ' + (Paint ($g.H * ($width - 2)) 'Border'))
        Write-Host ''
    }
    Write-Host ('  ' + (Paint $Title 'Title' -Bold))
    if ($Text) {
        foreach ($line in (Format-PstWrap $Text ($width - 6))) { Write-Host ('  ' + (Paint $line 'Dim')) }
    }
    Write-Host ''
}

function Read-PstText {
    # Saisie de texte, avec valeur par défaut, masquage et validation.
    # Retourne $null si la saisie est abandonnée (session non interactive).
    param([string]$Prompt, [string]$Default = '', [switch]$Secret, [scriptblock]$Validate, [string]$ErrorMessage = 'Valeur invalide.')
    if (-not (Test-PstInteractive)) { return $Default }
    while ($true) {
        $label = "  $(Paint '?' 'Accent' -Bold) $Prompt"
        if ($Default -and -not $Secret) { $label += (Paint " ($Default)" 'Dim') }
        if ($Secret) {
            $secure = Read-Host $label -AsSecureString
            $value = (New-Object System.Net.NetworkCredential '', $secure).Password
        }
        else { $value = Read-Host $label }
        if ($null -eq $value) { return $null }
        $value = $value.Trim()
        if (-not $value) { $value = $Default }
        if (-not $Validate -or (& $Validate $value)) { return $value }
        Write-PstStatus err $ErrorMessage
    }
}

function Show-PstSpinner {
    # Affiche « … » pendant une opération courte ; renvoie le résultat du bloc.
    param([string]$Message, [scriptblock]$Action)
    if ($script:Pst.Ansi -and (Test-PstInteractive)) { Write-Host ("  " + (Paint "$($script:Pst.Glyph.Info) $Message..." 'Dim')) -NoNewline }
    try { return (& $Action) }
    finally { if ($script:Pst.Ansi -and (Test-PstInteractive)) { Write-Host "`r$($script:Pst.Esc)[K" -NoNewline } }
}

# ── Emplacement du profil et stratégie d'exécution ───────────────────────────
# Le profil PowerShell vit dans « Documents ». En entreprise, ce dossier est
# souvent redirigé vers un partage réseau (\\serveur\...) : avec la stratégie
# RemoteSigned, Windows exige alors une signature et refuse de charger le profil.
# On ne se fie donc pas à la stratégie affichée : on teste le chargement réel.

function Get-PstProfileLocation {
    # Retourne @{ Path; IsNetwork; Unc; Server } pour un fichier de profil.
    param([string]$File)
    $unc = $null
    if ($File -like '\\*') { $unc = $File }
    elseif ($script:Pst.IsWindows -and $File -match '^([A-Za-z]):') {
        try {
            $drive = Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction Stop
            if ($drive.DisplayRoot -like '\\*') { $unc = $drive.DisplayRoot.TrimEnd('\') + $File.Substring(2) }
        }
        catch { $null = $_ }
    }
    $server = $null
    if ($unc) { $server = @($unc.TrimStart('\') -split '\\')[0] }
    return @{ Path = $File; IsNetwork = [bool]$unc; Unc = $unc; Server = $server }
}

function Get-PstShellExecutable {
    # Exécutable qui charge ce profil : Windows PowerShell 5.1 ou PowerShell 7.
    param([string]$File)
    if (-not $script:Pst.IsWindows -or $env:PSTOOLS_PROFILE) { return (Get-Process -Id $PID).Path }
    if ($File -match '[\\/]WindowsPowerShell[\\/]') {
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
        return $null
    }
    $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh) { return $pwsh.Source }
    return $null
}

function Test-PstProfileLoadable {
    # Vrai si PowerShell acceptera de charger un script situé dans le dossier de ce profil.
    param([string]$File)
    if ($env:PSTOOLS_TEST_PROFILE_BLOCKED) { return $false }   # réservé aux tests
    $exe = Get-PstShellExecutable $File
    if (-not $exe) { return $true }                              # ce shell n'est pas installé : rien à tester
    $dir = Split-Path -Parent $File
    $createdDir = $false
    $probe = Join-Path $dir (".ps-tools-probe-" + [Guid]::NewGuid().ToString('N') + '.ps1')
    # Les lanceurs ps-tools tournent en « Bypass », et cette préférence se transmet aux
    # processus enfants : on la retire pour tester la stratégie réelle de l'utilisateur.
    $savedPolicy = $env:PSExecutionPolicyPreference
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null; $createdDir = $true }
        [IO.File]::WriteAllText($probe, "'pst-probe-ok'", [Text.Encoding]::ASCII)
        Remove-Item Env:PSExecutionPolicyPreference -ErrorAction SilentlyContinue
        $output = (& $exe -NoLogo -NoProfile -NonInteractive -Command ". '$($probe -replace "'", "''")'" 2>&1 | Out-String)
        return ($output -match 'pst-probe-ok')
    }
    catch { return $false }
    finally {
        if ($savedPolicy) { $env:PSExecutionPolicyPreference = $savedPolicy }
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        if ($createdDir) { Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue }
    }
}

function Get-PstZoneKey {
    # Clé du registre (zones Internet de l'utilisateur) correspondant à un serveur.
    param([string]$Server)
    $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap'
    if ($Server -match '^\d{1,3}(\.\d{1,3}){3}$') { return @{ Key = "$base\Ranges\ps-tools"; Range = $Server } }
    $labels = @($Server.ToLower() -split '\.' | Where-Object { $_ })
    if ($labels.Count -le 2) { return @{ Key = "$base\Domains\$($labels -join '.')" } }
    $domain = ($labels[($labels.Count - 2)..($labels.Count - 1)]) -join '.'
    $sub = ($labels[0..($labels.Count - 3)]) -join '.'
    return @{ Key = "$base\Domains\$domain\$sub" }
}

function Grant-PstShareTrust {
    # Classe le serveur de fichiers en « Intranet local » pour ce compte : ses scripts
    # sont alors traités comme locaux par RemoteSigned. Aucun droit administrateur requis.
    param([string]$Server)
    $zone = Get-PstZoneKey $Server
    New-Item -Path $zone.Key -Force | Out-Null
    if ($zone.Range) { New-ItemProperty -Path $zone.Key -Name ':Range' -Value $zone.Range -PropertyType String -Force | Out-Null }
    New-ItemProperty -Path $zone.Key -Name 'file' -Value 1 -PropertyType DWord -Force | Out-Null
}

function Revoke-PstShareTrust {
    param([string]$Server)
    if (-not $Server) { return }
    $zone = Get-PstZoneKey $Server
    if (-not (Test-Path -LiteralPath $zone.Key)) { return }
    Remove-ItemProperty -Path $zone.Key -Name 'file' -ErrorAction SilentlyContinue
    if ($zone.Range) { Remove-Item -Path $zone.Key -Force -ErrorAction SilentlyContinue }
    elseif (@((Get-Item -LiteralPath $zone.Key).GetValueNames()).Count -eq 0 -and @(Get-ChildItem -LiteralPath $zone.Key).Count -eq 0) {
        Remove-Item -Path $zone.Key -Force -ErrorAction SilentlyContinue
    }
}

function Set-PstUserPolicy {
    # Change la stratégie d'exécution de l'utilisateur courant (sans droits administrateur).
    param([string]$Policy)
    try { Set-ExecutionPolicy -ExecutionPolicy $Policy -Scope CurrentUser -Force -ErrorAction Stop }
    catch {
        # Message attendu quand la session courante tourne déjà en Bypass : le réglage est bien enregistré.
        if ("$($_.FullyQualifiedErrorId)" -notmatch 'ExecutionPolicyOverride') { throw }
    }
}

function Test-PstWindowsTerminal {
    if (-not $script:Pst.IsWindows -or -not $env:LOCALAPPDATA) { return $false }
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) { return $true }
    return [bool](Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages') -Filter 'Microsoft.WindowsTerminal*' -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-PstTerminalFragmentPath {
    return (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\ps-tools\ps-tools.json')
}

function Set-PstTerminalProfile {
    # Ajoute à Windows Terminal un profil « PowerShell · ps-tools » qui charge l'intégration
    # depuis l'installation locale, sans passer par le profil PowerShell (réseau).
    param([string]$ShellScript)
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $icon = 'ms-appx:///ProfileIcons/{61c54bbd-c2c6-5271-96e7-009a87ff44bf}.png'
    $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh) { $exe = $pwsh.Source; $icon = 'ms-appx:///ProfileIcons/pwsh.png' }
    $fragment = [ordered]@{
        profiles = @([ordered]@{
                guid              = '{5e3f1c2a-7b8d-4e6f-9a0b-1c2d3e4f5a6b}'
                name              = 'PowerShell · ps-tools'
                commandline       = "`"$exe`" -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -Command `". '$($ShellScript -replace "'", "''")'`""
                startingDirectory = '%USERPROFILE%'
                icon              = $icon
            })
    }
    $file = Get-PstTerminalFragmentPath
    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Write-PstJsonFile $file $fragment
    return $file
}

function Remove-PstTerminalProfile {
    if (-not $env:LOCALAPPDATA) { return $false }
    $dir = Split-Path -Parent (Get-PstTerminalFragmentPath)
    if (-not (Test-Path -LiteralPath $dir)) { return $false }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    return $true
}

Initialize-PstConsole
