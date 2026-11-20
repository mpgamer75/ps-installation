# ─────────────────────────────────────────────────────────────────────────────
#  ps-tools — bibliothèque partagée (interface, couleurs, utilitaires)
#  Chargée par chaque outil :  . "$PSScriptRoot\..\lib\PsTools.ps1"
#  Compatible Windows PowerShell 5.1 et PowerShell 7+.
# ─────────────────────────────────────────────────────────────────────────────

$script:Pst = @{
    Version   = '2.0.0'
    Repo      = 'mpgamer75/ps-installation'
    Esc       = [string][char]27
    # PSTOOLS_TEST_WINDOWS : réservé aux tests, pour exercer le rendu hors Windows avec des données simulées.
    IsWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or [bool]$IsWindows -or [bool]$env:PSTOOLS_TEST_WINDOWS
    Ansi      = $false
    Glyph     = @{}
    Theme     = @{
        Accent  = @(86, 182, 255)
        Accent2 = @(178, 132, 255)
        Ok      = @(80, 220, 140)
        Warn    = @(255, 190, 80)
        Err     = @(255, 95, 110)
        Dim     = @(125, 133, 150)
        Title   = @(240, 244, 255)
    }
}

function Initialize-PstConsole {
    # Détecte les capacités du terminal : séquences ANSI et jeu de glyphes.
    $ansi = $false
    try { $ansi = [bool]$Host.UI.SupportsVirtualTerminal } catch { $ansi = $false }
    try { if ([Console]::IsOutputRedirected) { $ansi = $false } } catch { $ansi = $false }
    if ($env:NO_COLOR) { $ansi = $false }
    if ($env:PSTOOLS_FORCE_COLOR) { $ansi = $true }
    $script:Pst.Ansi = $ansi

    if ($env:PSTOOLS_ASCII) {
        $script:Pst.Glyph = @{
            H = '-'; V = '|'; TL = '+'; TR = '+'; BL = '+'; BR = '+'
            Full = '#'; Empty = '.'; Ok = 'v'; Err = 'x'; Warn = '!'; Info = '*'
            Pointer = '>'; Dot = '-'; Up = '^'; Down = 'v'; Ellipsis = '~'
            On = '[x]'; Off = '[ ]'; Lock = '[admin]'
            Spark = @('_', '_', '.', '.', '-', '-', '=', '#')
        }
    }
    else {
        $script:Pst.Glyph = @{
            H = '─'; V = '│'; TL = '╭'; TR = '╮'; BL = '╰'; BR = '╯'
            Full = '█'; Empty = '░'; Ok = '√'; Err = '×'; Warn = '!'; Info = '•'
            Pointer = '►'; Dot = '·'; Up = '↑'; Down = '↓'; Ellipsis = '…'
            On = '[■]'; Off = '[ ]'; Lock = '[admin]'
            Spark = @('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█')
        }
    }
}

# ── Couleurs ─────────────────────────────────────────────────────────────────

function Paint {
    # Retourne le texte coloré (ou brut si le terminal ne gère pas l'ANSI).
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Text = '',
        [Parameter(Position = 1)]$Color = $null,
        [switch]$Bold
    )
    if (-not $script:Pst.Ansi -or $Text.Length -eq 0) { return $Text }
    $rgb = $null
    if ($Color -is [string]) { $rgb = $script:Pst.Theme[$Color] }
    elseif ($Color) { $rgb = $Color }
    $codes = @()
    if ($Bold) { $codes += '1' }
    if ($rgb) { $codes += ('38;2;{0};{1};{2}' -f [int]$rgb[0], [int]$rgb[1], [int]$rgb[2]) }
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
    $i = 0
    $value = [Math]::Abs($Bytes)
    while ($value -ge 1024 -and $i -lt $units.Count - 1) { $value /= 1024; $i++ }
    if ($i -eq 0) { return ('{0:N0} {1}' -f $value, $units[$i]) }
    return ('{0:N1} {1}' -f $value, $units[$i])
}

function Format-PstDuration {
    param([TimeSpan]$Span)
    if ($Span.TotalSeconds -lt 0) { $Span = $Span.Negate() }
    if ($Span.TotalDays -ge 1) { return ('{0}j {1}h {2:00}m' -f [int][Math]::Floor($Span.TotalDays), $Span.Hours, $Span.Minutes) }
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
    param([string]$Title = '', [string[]]$Lines = @(), [int]$Width = 0, $Color = 'Dim')
    $g = $script:Pst.Glyph
    if ($Width -le 0) {
        $Width = (Get-PstVisibleLength $Title) + 6
        foreach ($l in $Lines) { $Width = [Math]::Max($Width, (Get-PstVisibleLength $l) + 4) }
    }
    $inner = $Width - 2
    $out = @()
    if ($Title) {
        $rest = [Math]::Max($inner - (Get-PstVisibleLength $Title) - 3, 0)
        $out += (Paint ($g.TL + $g.H + ' ') $Color) + (Paint $Title 'Title' -Bold) + (Paint (' ' + ($g.H * $rest) + $g.TR) $Color)
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
    $out += Paint $head.TrimEnd() 'Dim'
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
    param([string]$Tagline = 'La boîte à outils du terminal Windows')
    Get-PstBanner | Write-PstLine
    $mode = 'utilisateur'
    if (Test-PstAdmin) { $mode = 'administrateur' }
    Write-Host ('  ' + (Paint $Tagline 'Title') + (Paint ("  $($script:Pst.Glyph.Dot)  v$($script:Pst.Version)  $($script:Pst.Glyph.Dot)  mode $mode") 'Dim'))
    Write-Host ''
}

function Get-PstHeaderLine {
    # Bandeau compact affiché en tête de chaque outil.
    param([string]$Tool, [string]$Subtitle = '', [int]$Width = 0)
    if ($Width -le 0) { $Width = Get-PstWidth }
    $g = $script:Pst.Glyph
    $left = (Format-PstGradient "$($g.Pointer)_ ps-tools" -Bold) + (Paint " / " 'Dim') + (Paint $Tool 'Title' -Bold)
    if ($Subtitle) { $left += Paint "  $($g.Dot) $Subtitle" 'Dim' }
    $mode = 'utilisateur'
    $modeColor = 'Dim'
    if (Test-PstAdmin) { $mode = 'admin'; $modeColor = 'Warn' }
    $right = (Paint "v$($script:Pst.Version) $($g.Dot) " 'Dim') + (Paint $mode $modeColor)
    $gap = $Width - (Get-PstVisibleLength $left) - (Get-PstVisibleLength $right)
    if ($gap -lt 2) { return $left }
    return $left + (' ' * $gap) + $right
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
    Show-PstHeader -Tool $Name -Subtitle 'aide'
    Write-Host "  $Synopsis"
    Write-Host ''
    if ($Usage.Count) {
        Write-Host ('  ' + (Paint 'UTILISATION' 'Accent' -Bold))
        foreach ($u in $Usage) { Write-Host "    $u" }
        Write-Host ''
    }
    if ($Options.Count) {
        Write-Host ('  ' + (Paint 'OPTIONS' 'Accent' -Bold))
        $w = 0
        foreach ($o in $Options) { $w = [Math]::Max($w, ([string]$o[0]).Length) }
        foreach ($o in $Options) { Write-Host ('    ' + (Paint (([string]$o[0]).PadRight($w)) 'Title') + '  ' + (Paint ([string]$o[1]) 'Dim')) }
        Write-Host ''
    }
    if ($Examples.Count) {
        Write-Host ('  ' + (Paint 'EXEMPLES' 'Accent' -Bold))
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
    $hint = '[o/N]'
    if ($DefaultYes) { $hint = '[O/n]' }
    $answer = Read-Host ("  $(Paint '?' 'Accent' -Bold) $Question $hint")
    if ([string]::IsNullOrWhiteSpace($answer)) { return [bool]$DefaultYes }
    return ($answer.Trim() -match '^(o|oui|y|yes)$')
}

function Read-PstChoice {
    # Menu à flèches. Retourne l'index choisi, ou -1 si annulé (Échap).
    param([string]$Title, [string[]]$Items, [int]$Default = 0)
    $g = $script:Pst.Glyph
    if ($Title) { Write-Host ("  $(Paint '?' 'Accent' -Bold) " + (Paint $Title 'Title' -Bold)) }

    if (-not $script:Pst.Ansi -or -not (Test-PstInteractive)) {
        for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ("    {0}. {1}" -f ($i + 1), $Items[$i]) }
        if (-not (Test-PstInteractive)) { return $Default }
        $answer = Read-Host '  Votre choix'
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Items.Count) { return ([int]$answer - 1) }
        return -1
    }

    $e = $script:Pst.Esc
    $index = [Math]::Max(0, [Math]::Min($Default, $Items.Count - 1))
    Write-Host "$e[?25l" -NoNewline
    try {
        while ($true) {
            for ($i = 0; $i -lt $Items.Count; $i++) {
                if ($i -eq $index) { Write-Host ("    $(Paint $g.Pointer 'Accent') " + (Paint $Items[$i] 'Title' -Bold) + "$e[K") }
                else { Write-Host ("      " + (Paint $Items[$i] 'Dim') + "$e[K") }
            }
            Write-Host ((Paint "    $($g.Up)$($g.Down) naviguer $($g.Dot) Entrée valider $($g.Dot) Échap annuler" 'Dim') + "$e[K")
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
            $answer = Read-Host '  Numéros séparés par des virgules (Entrée = sélection proposée, 0 = annuler)'
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
                if ($i -eq $index) { $cursor = (Paint $g.Pointer 'Accent') + ' ' }
                if ($locked[$i]) { $line = (Paint " -  $($Items[$i])" 'Dim') }
                elseif ($state[$i]) { $line = (Paint $g.On 'Ok') + ' ' + $Items[$i] }
                else { $line = (Paint $g.Off 'Dim') + ' ' + $Items[$i] }
                Write-Host ("    $cursor$line$e[K")
            }
            Write-Host ((Paint "    $($g.Up)$($g.Down) naviguer $($g.Dot) Espace cocher $($g.Dot) A tout $($g.Dot) Entrée valider $($g.Dot) Échap annuler" 'Dim') + "$e[K")
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
    param([string]$Message = 'Appuyez sur une touche pour continuer...')
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
    Write-PstStatus err "$Tool nécessite Windows."
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
        Write-PstStatus warn "Élévation annulée ou impossible : $($_.Exception.Message)"
        return $false
    }
}

Initialize-PstConsole
