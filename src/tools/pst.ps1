<#
.SYNOPSIS
    pst — tableau de bord et gestionnaire de ps-tools : outils, réglages, diagnostic, mise à jour.
.DESCRIPTION
    Sans argument, dans un terminal interactif : tableau de bord plein écran
    (onglets par catégorie, liste des outils, fiche détaillée, lancement direct).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [switch]$Yes,
    [switch]$Purge,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$appRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $appRoot 'lib') 'PsTools.ps1')
. (Join-Path (Join-Path $appRoot 'lib') 'PsTools.AI.ps1')
. (Join-Path (Join-Path $appRoot 'lib') 'PsTools.Wizard.ps1')
Import-PstStrings 'pst'
$g = $script:Pst.Glyph

# ── Données ──────────────────────────────────────────────────────────────────

function Get-Manifest {
    # Installé : app\manifest.json. Depuis le dépôt : manifest.json à la racine.
    foreach ($candidate in (Join-Path $appRoot 'manifest.json'), (Join-Path (Split-Path -Parent $appRoot) 'manifest.json')) {
        if (Test-Path -LiteralPath $candidate) {
            try { return (Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $null = $_ }
        }
    }
    return $null
}

function Get-InstallInfo {
    $file = Join-Path $appRoot 'install.json'
    if (Test-Path -LiteralPath $file) {
        try { return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $null = $_ }
    }
    return $null
}

function Get-InstalledTools {
    $manifest = Get-Manifest
    if ($null -eq $manifest) { return @() }
    return @($manifest.tools | Where-Object { Test-Path -LiteralPath (Join-Path $PSScriptRoot "$($_.name).ps1") })
}

function Get-ToolDescription {
    param($Tool)
    if ($script:Pst.Lang -eq 'en' -and $Tool.description_en) { return [string]$Tool.description_en }
    return [string]$Tool.description
}

function Get-CategoryLabel {
    # Les catégories du manifeste sont en français ; libellé affiché selon la langue.
    param([string]$Category)
    switch ($Category) {
        'Tout' { return (L 'Tout') }
        'Au quotidien' { return (L 'Au quotidien') }
        'Code' { return 'Code' }
        'Système' { return (L 'Système') }
        'Fichiers' { return (L 'Fichiers') }
        'Réseau' { return (L 'Réseau') }
        'IA' { return (L 'IA') }
        'Gestion' { return (L 'Gestion') }
    }
    return $Category
}

$script:CategoryOrder = @('Au quotidien', 'IA', 'Code', 'Fichiers', 'Système', 'Réseau', 'Gestion')

function Sort-ByCategory {
    param($Tools)
    return @($Tools | Sort-Object { $i = [array]::IndexOf($script:CategoryOrder, [string]$_.category); if ($i -lt 0) { 99 } else { $i } }, name)
}

# ── Accueil (texte) ──────────────────────────────────────────────────────────

function Show-ToolList {
    $tools = Sort-ByCategory @(Get-InstalledTools)
    $nameWidth = 0
    foreach ($t in $tools) { $nameWidth = [Math]::Max($nameWidth, $t.name.Length) }
    foreach ($category in @($tools | ForEach-Object { $_.category } | Select-Object -Unique)) {
        Write-Host ('  ' + (Paint (Get-CategoryLabel $category).ToUpper() 'Accent' -Bold))
        foreach ($t in @($tools | Where-Object { $_.category -eq $category })) {
            $tag = ''
            if ($t.admin -eq 'optionnel') { $tag = Paint ("  $($g.Dot) " + (L 'plus complet en admin')) 'Warn' }
            Write-Host ('    ' + (Paint $t.name.PadRight($nameWidth) 'Title' -Bold) + '  ' + (Paint (Get-ToolDescription $t) 'Secondary') + $tag)
        }
        Write-Host ''
    }
}

function Show-Home {
    Show-PstBanner
    Show-ToolList
    $rows = @(
        @('<commande> -Help', (L 'aide détaillée d''un outil')),
        @('pst', (L 'tableau de bord (dans un terminal interactif)')),
        @('pst setup', (L 'réglages : langue, apparence, shell, assistant IA')),
        @('pst keys', (L 'aide-mémoire des raccourcis')),
        @('pst shell on', (L 'invite, raccourcis et commandes façon Unix')),
        @('pst doctor', (L 'vérifie l''installation')),
        @('pst update', (L 'installe la dernière version')),
        @('pst-uninstall', (L 'désinstalle ps-tools'))
    )
    foreach ($r in $rows) { Write-Host ('  ' + (Paint (Format-PstPad $r[0] 18) 'Ok') + (Paint $r[1] 'Dim')) }
    Write-Host ''
}

# ── Tableau de bord plein écran (style « panneaux » : onglets, liste, fiche) ──

function Get-StatusItems {
    # Bandeau d'état : ● intégration au shell, ● assistant IA, budget, tâches du jour.
    $items = @()
    $shell = Test-PstShell
    $items += @{ On = $shell; Text = $(if ($shell) { L 'shell intégré' } else { L 'shell non intégré' }) }
    try {
        $ai = Get-PstAiSettings
        $provider = Get-PstAiProvider $ai.Provider
        $hasKey = [bool](Get-PstAiKey $ai.Provider).Key -or -not $provider.KeyRequired
        if ($hasKey) {
            $items += @{ On = $true; Text = "$($provider.Label) $($g.Dot) $($ai.Model)" }
            if ($ai.Budget -gt 0) {
                $pct = [Math]::Round((Get-PstAiMonthCost) / $ai.Budget * 100)
                $items += @{ On = ($pct -lt 100); Text = (L 'budget IA {0} %' $pct) }
            }
        }
        else { $items += @{ On = $false; Text = (L 'IA non configurée') } }
    }
    catch { $null = $_ }
    $todo = Read-PstJsonFile (Join-Path (Get-PstDataDir) 'todo.json')
    if ($todo) {
        # todo.json : tableau de tâches { text, done, due (aaaa-mm-jj) }.
        $open = @(@($todo) | ForEach-Object { $_ } | Where-Object { $_ -is [hashtable] -and -not $_.done })
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $due = @($open | Where-Object { $_.due -and [string]$_.due -le $today })
        if ($due.Count) { $items += @{ On = $true; Text = (L '{0} tâche(s) pour aujourd''hui' $due.Count) } }
        elseif ($open.Count) { $items += @{ On = $true; Text = (L '{0} tâche(s) ouverte(s)' $open.Count) } }
    }
    return $items
}

function Get-HubFrame {
    param($State)
    $width = Get-PstWidth -Max 160 -Min 60
    $height = 30
    try { $height = [Math]::Max(18, $Host.UI.RawUI.WindowSize.Height - 1) } catch { $height = 30 }
    $lines = New-Object System.Collections.Generic.List[string]

    # 1. Titre
    $mode = L 'utilisateur'; $modeColor = 'Ok'
    if (Test-PstAdmin) { $mode = L 'admin'; $modeColor = 'Warn' }
    $left = ' ' + (Paint "$($g.Pointer) " 'Accent') + (Paint "ps-tools $($script:Pst.Version)" 'Accent' -Bold) + (Paint "  $($g.Sep)  " 'Border') + (Paint (L 'la boîte à outils du terminal') 'Secondary')
    $right = (Paint $g.Bullet $modeColor) + ' ' + (Paint $mode 'Secondary') + ' '
    $lines.Add($left + (' ' * [Math]::Max(1, $width - (Get-PstVisibleLength $left) - (Get-PstVisibleLength $right))) + $right)

    # 2. Onglets numérotés
    # Onglets « 1 Tout 26 » ; sans les compteurs si la largeur manque.
    $withCounts = $true
    foreach ($attempt in 1, 2) {
        $tabs = ' '
        for ($i = 0; $i -lt $State.Tabs.Count; $i++) {
            $name = Get-CategoryLabel $State.Tabs[$i]
            $count = ''
            if ($withCounts) { $count = " $($State.Counts[$i])" }
            if ($i -eq $State.Tab) { $tabs += (Paint " $($i + 1) $name$count " 'Accent' -Bold -Bg 'Selected') + ' ' }
            else { $tabs += (Paint " $($i + 1) " 'Accent') + (Paint $name 'Secondary') + (Paint "$count " 'Dim') + ' ' }
        }
        if ((Get-PstVisibleLength $tabs) -le $width) { break }
        $withCounts = $false
    }
    $lines.Add($tabs)
    $lines.Add(' ' + (Paint ($g.H * ($width - 2)) 'Border'))

    # 3. Panneaux : liste (gauche) + fiche (droite), ou liste seule si l'écran est étroit
    $bodyHeight = $height - $lines.Count - 3
    $listWidth = [Math]::Min(30, [Math]::Max(22, [int]($width * 0.28)))
    $split = $width -ge 90
    if (-not $split) { $listWidth = $width - 2 }
    $visible = $State.Visible
    $rows = [Math]::Max(3, $bodyHeight - 2)
    if ($State.Index -lt $State.Scroll) { $State.Scroll = $State.Index }
    if ($State.Index -ge $State.Scroll + $rows) { $State.Scroll = $State.Index - $rows + 1 }
    $listLines = @()
    for ($r = 0; $r -lt $rows; $r++) {
        $k = $State.Scroll + $r
        if ($k -ge $visible.Count) { $listLines += ''; continue }
        $t = $visible[$k]
        $name = Limit-PstText $t.name ($listWidth - 8)
        if ($k -eq $State.Index) { $listLines += Paint (Format-PstPad " $($g.Pointer) $name" ($listWidth - 4)) 'Title' -Bold -Bg 'Selected' }
        else {
            $badge = ''
            if ($t.admin -eq 'optionnel') { $badge = Paint '◆' 'Warn' }
            $listLines += '   ' + (Paint (Format-PstPad $name ($listWidth - 8)) 'Secondary') + $badge
        }
    }
    if ($visible.Count -eq 0) { $listLines[0] = Paint ('  ' + (L 'Aucun outil ne correspond.')) 'Dim' }
    $listTitle = L 'outils'
    if ($State.Filter) { $listTitle = "/ $($State.Filter)" }
    $listBox = Format-PstBox -Title $listTitle -Lines $listLines -Width $listWidth

    if ($split) {
        $detailWidth = $width - $listWidth - 2
        $detail = @()
        if ($visible.Count) {
            $t = $visible[$State.Index]
            $inner = $detailWidth - 4
            foreach ($l in (Format-PstWrap (Get-ToolDescription $t) $inner)) { $detail += (Paint $l 'Title') }
            $detail += ''
            $meta = (Paint (L 'Catégorie') 'Dim') + ' ' + (Paint (Get-CategoryLabel $t.category) 'Accent2')
            if ($t.admin -eq 'optionnel') { $meta += (Paint "   $($g.Dot)   " 'Border') + (Paint (L 'plus complet en administrateur') 'Warn') }
            elseif ($t.admin -eq 'non') { $meta += (Paint "   $($g.Dot)   " 'Border') + (Paint (L 'sans droits administrateur') 'Ok') }
            $detail += $meta
            $detail += ''
            $detail += Paint (L 'EXEMPLES') 'Accent' -Bold
            $examples = @($t.examples)
            if (-not $examples.Count) { $examples = @("$($t.name) -Help") }
            foreach ($ex in $examples) { $detail += '  ' + (Paint '›' 'Accent') + ' ' + (Paint (Limit-PstText $ex ($inner - 4)) 'Ok') }
            $detail += ''
            $detail += Paint (L 'ACTIONS') 'Accent' -Bold
            $detail += '  ' + (Paint (L 'Entrée') 'Accent') + '  ' + (Paint (L 'lancer (avec ou sans arguments)') 'Secondary')
            $detail += '  ' + (Paint 'h' 'Accent') + '       ' + (Paint (L 'aide complète de l''outil') 'Secondary')
        }
        while ($detail.Count -lt $rows) { $detail += '' }
        $detail = @($detail | Select-Object -First $rows)
        $detailTitle = ''
        if ($visible.Count) { $detailTitle = $visible[$State.Index].name }
        $detailBox = Format-PstBox -Title $detailTitle -Lines $detail -Width $detailWidth
        for ($r = 0; $r -lt $listBox.Count; $r++) { $lines.Add(' ' + $listBox[$r] + ' ' + $detailBox[$r]) }
    }
    else {
        foreach ($l in $listBox) { $lines.Add(' ' + $l) }
    }

    # 4. Barre de touches et bandeau d'état
    if ($State.Filtering) {
        $lines.Add((Paint (Format-PstPad (' / ' + (L 'filtrer :') + " $($State.Filter)_   " + (L 'Entrée garder · Échap effacer')) $width) 'Title' -Bold -Bg 'Selected'))
    }
    else {
        $lines.Add((Format-PstKeyBar -Bar -Width $width @(
                    @("$($g.Up)$($g.Down)", (L 'choisir')), @((L 'Entrée'), (L 'lancer')), @('1-9', (L 'onglet')), @('/', (L 'filtrer')),
                    @('s', (L 'réglages')), @('u', (L 'conso IA')), @('k', (L 'raccourcis')), @('d', (L 'diagnostic')), @('q', (L 'quitter')))))
    }
    $status = ' ' + $State.Message
    foreach ($item in (Get-StatusItems)) {
        $dot = Paint $g.Bullet $(if ($item.On) { 'Ok' } else { 'Dim' }) -Bg 'Raised'
        $status += (Paint " $($g.Sep) " 'Border' -Bg 'Raised') + $dot + (Paint " $($item.Text)" 'Secondary' -Bg 'Raised')
    }
    $pad = $width - (Get-PstVisibleLength $status)
    if ($pad -gt 0) { $status += Paint (' ' * $pad) $null -Bg 'Raised' }
    $lines.Add((Paint ' ' $null -Bg 'Raised') + $status.Substring(1))
    return $lines.ToArray()
}

function Get-ToolArguments {
    # Découpe la saisie de l'utilisateur en arguments, guillemets compris.
    param([string]$Text)
    $list = @()
    if (-not $Text.Trim()) { return $list }
    $errors = $null
    foreach ($token in [System.Management.Automation.PSParser]::Tokenize($Text, [ref]$errors)) {
        if ($token.Type -in 'CommandArgument', 'String', 'Number', 'CommandParameter', 'Command', 'Variable', 'Member', 'Generic') { $list += [string]$token.Content }
    }
    return $list
}

function Invoke-HubTool {
    # Lance un outil dans un processus séparé (un « exit » de l'outil ne ferme pas le tableau de bord).
    param($Tool, [switch]$HelpOnly)
    Stop-PstScreen
    Write-Host ''
    Write-Host (' ' + (Paint "$($g.Pointer) " 'Accent') + (Paint $Tool.name 'Title' -Bold) + (Paint "  $($g.Dot) $(Get-ToolDescription $Tool)" 'Secondary'))
    $arguments = @()
    if ($HelpOnly) { $arguments = @('-Help') }
    else {
        $examples = @($Tool.examples)
        if ($examples.Count) { Write-Host (Paint ('   ' + (L 'ex. :') + ' ' + ($examples[0] -replace "^$([regex]::Escape($Tool.name))\s*", '')) 'Dim') }
        $hint = L 'Arguments (Entrée = aucun)'
        if ($Tool.args -eq 'required') { $hint = L 'Arguments' }
        $typed = Read-Host ("  $(Paint '?' 'Accent' -Bold) $($Tool.name) $(Paint $hint 'Dim')")
        if ($Tool.args -eq 'required' -and -not $typed.Trim()) { $arguments = @('-Help') }
        else { $arguments = Get-ToolArguments $typed }
    }
    $shell = (Get-Process -Id $PID).Path
    & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "$($Tool.name).ps1") @arguments
    $code = $LASTEXITCODE
    Write-Host ''
    $message = L 'Entrée : retour au tableau de bord · Q : quitter'
    Write-Host ('  ' + (Paint $message 'Dim')) -NoNewline
    $key = $null
    try { $key = [Console]::ReadKey($true) } catch { $null = $_ }
    Write-Host ''
    if ($key -and (Test-PstQuitKey $key)) { return 'quit' }
    Start-PstScreen
    if ($code) { return (L '« {0} » terminé (code {1}).' $Tool.name $code) }
    return (L '« {0} » terminé.' $Tool.name)
}

function Invoke-HubAction {
    # Lance une commande de pst (réglages, diagnostic...) puis revient.
    param([string[]]$Arguments)
    Stop-PstScreen
    $shell = (Get-Process -Id $PID).Path
    & $shell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @Arguments
    Write-Host ''
    Write-Host ('  ' + (Paint (L 'Entrée : retour au tableau de bord · Q : quitter') 'Dim')) -NoNewline
    $key = $null
    try { $key = [Console]::ReadKey($true) } catch { $null = $_ }
    if ($key -and (Test-PstQuitKey $key)) { return 'quit' }
    # Les réglages ont pu changer : thème et langue relus.
    Set-PstTheme ([string](Get-PstConfig).theme)
    Set-PstLanguage (Get-PstLanguage)
    Start-PstScreen
    return (L 'Prêt.')
}

function Show-Hub {
    $all = @(Sort-ByCategory @(Get-InstalledTools | Where-Object { $_.name -ne 'pst' }))
    $categories = @($script:CategoryOrder | Where-Object { $c = $_; @($all | Where-Object { $_.category -eq $c }).Count })
    $state = @{ Tabs = @('Tout') + $categories; Tab = 0; Index = 0; Scroll = 0; Filter = ''; Filtering = $false; Message = (L 'Prêt.'); Visible = @(); Counts = @() }
    $state.Counts = @($state.Tabs | ForEach-Object { $c = $_; if ($c -eq 'Tout') { $all.Count } else { @($all | Where-Object { $_.category -eq $c }).Count } })
    $refresh = {
        $pool = $all
        if ($state.Tab -gt 0) { $cat = $state.Tabs[$state.Tab]; $pool = @($all | Where-Object { $_.category -eq $cat }) }
        if ($state.Filter) {
            $f = $state.Filter
            $pool = @($pool | Where-Object { $_.name -like "*$f*" -or (Get-ToolDescription $_) -like "*$f*" -or [string]$_.description -like "*$f*" })
        }
        $state.Visible = @($pool)
        if ($state.Index -ge $state.Visible.Count) { $state.Index = [Math]::Max(0, $state.Visible.Count - 1) }
    }
    & $refresh
    Start-PstScreen
    try {
        while ($true) {
            Write-PstFrame (Get-HubFrame $state)
            $key = [Console]::ReadKey($true)
            if ($state.Filtering) {
                switch ($key.Key) {
                    'Escape' { $state.Filter = ''; $state.Filtering = $false }
                    'Enter' { $state.Filtering = $false }
                    'Backspace' { if ($state.Filter.Length) { $state.Filter = $state.Filter.Substring(0, $state.Filter.Length - 1) } }
                    'UpArrow' { $state.Index = [Math]::Max(0, $state.Index - 1) }
                    'DownArrow' { $state.Index = [Math]::Min([Math]::Max(0, $state.Visible.Count - 1), $state.Index + 1) }
                    default { if ($key.KeyChar -and -not [char]::IsControl($key.KeyChar)) { $state.Filter += $key.KeyChar; $state.Index = 0 } }
                }
                & $refresh
                continue
            }
            $char = [string]$key.KeyChar
            if (Test-PstQuitKey $key) { break }
            switch ($key.Key) {
                'UpArrow' { $state.Index = [Math]::Max(0, $state.Index - 1); continue }
                'DownArrow' { $state.Index = [Math]::Min([Math]::Max(0, $state.Visible.Count - 1), $state.Index + 1); continue }
                'PageUp' { $state.Index = [Math]::Max(0, $state.Index - 10); continue }
                'PageDown' { $state.Index = [Math]::Min([Math]::Max(0, $state.Visible.Count - 1), $state.Index + 10); continue }
                'Home' { $state.Index = 0; continue }
                'End' { $state.Index = [Math]::Max(0, $state.Visible.Count - 1); continue }
                'LeftArrow' { $state.Tab = ($state.Tab - 1 + $state.Tabs.Count) % $state.Tabs.Count; $state.Index = 0; & $refresh; continue }
                'RightArrow' { $state.Tab = ($state.Tab + 1) % $state.Tabs.Count; $state.Index = 0; & $refresh; continue }
                'Tab' {
                    if ($key.Modifiers -band [ConsoleModifiers]::Shift) { $state.Tab = ($state.Tab - 1 + $state.Tabs.Count) % $state.Tabs.Count }
                    else { $state.Tab = ($state.Tab + 1) % $state.Tabs.Count }
                    $state.Index = 0; & $refresh; continue
                }
                'Enter' {
                    if ($state.Visible.Count) {
                        $r = Invoke-HubTool $state.Visible[$state.Index]
                        if ($r -eq 'quit') { return }
                        $state.Message = $r
                    }
                    continue
                }
            }
            switch -CaseSensitive -Regex ($char) {
                '^[1-9]$' { $n = [int]$char - 1; if ($n -lt $state.Tabs.Count) { $state.Tab = $n; $state.Index = 0; & $refresh } }
                '^/$' { $state.Filtering = $true; $state.Filter = '' }
                '^j$' { $state.Index = [Math]::Min([Math]::Max(0, $state.Visible.Count - 1), $state.Index + 1) }
                '^k$' { $r = Invoke-HubAction @('keys'); if ($r -eq 'quit') { return }; $state.Message = $r }
                '^h$' { if ($state.Visible.Count) { $r = Invoke-HubTool $state.Visible[$state.Index] -HelpOnly; if ($r -eq 'quit') { return }; $state.Message = $r } }
                '^s$' { $r = Invoke-HubAction @('setup'); if ($r -eq 'quit') { return }; $state.Message = $r; $all = @(Sort-ByCategory @(Get-InstalledTools | Where-Object { $_.name -ne 'pst' })); & $refresh }
                '^u$' { $r = Invoke-HubAction @('usage'); if ($r -eq 'quit') { return }; $state.Message = $r }
                '^d$' { $r = Invoke-HubAction @('doctor'); if ($r -eq 'quit') { return }; $state.Message = $r }
            }
        }
    }
    finally { Stop-PstScreen }
}

# ── Diagnostic ───────────────────────────────────────────────────────────────

function Invoke-Doctor {
    Show-PstHeader -Tool 'pst' -Subtitle (L 'diagnostic')
    $problems = 0
    $info = Get-InstallInfo
    $bin = Join-Path (Split-Path -Parent $appRoot) 'bin'

    $version = $PSVersionTable.PSVersion
    if ($version -ge [Version]'5.1') { Write-PstStatus ok "PowerShell $version" }
    else { Write-PstStatus err (L 'PowerShell {0} : la version 5.1 ou plus est requise' $version); $problems++ }

    if ($info) {
        $scope = L 'utilisateur courant'
        if ($info.Scope -eq 'AllUsers') { $scope = L 'tous les utilisateurs' }
        Write-PstStatus ok (L 'Version {0} · {1} · {2}' $info.Version $scope $info.Root)
    }
    else { Write-PstStatus info (L 'Exécution depuis le dépôt (non installé) : {0}' $appRoot) }
    Write-PstStatus ok (L 'Langue : {0}' $(if ($script:Pst.Lang -eq 'en') { 'English' } else { 'Français' }))

    $manifest = Get-Manifest
    $tools = @(Get-InstalledTools)
    if ($manifest) { Write-PstStatus ok (L '{0} outil(s) sur {1} disponibles' $tools.Count @($manifest.tools).Count) }
    else { Write-PstStatus err (L 'Manifeste introuvable : réinstallez avec « pst update »'); $problems++ }

    if ($info -and $script:Pst.IsWindows) {
        $entries = @($env:PATH -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') })
        if ($entries -contains $bin.TrimEnd('\')) { Write-PstStatus ok (L 'Dossier des commandes présent dans le PATH') }
        else { Write-PstStatus warn (L 'PATH : {0} est absent de ce terminal (ouvrez-en un nouveau, ou « pst update »)' $bin); $problems++ }
        foreach ($t in $tools) {
            $first = Get-Command -Name $t.name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($first -and (Split-Path -Parent $first.Source).TrimEnd('\') -ine $bin.TrimEnd('\')) {
                Write-PstStatus warn (L '« {0} » est masqué par {1}' $t.name $first.Source)
                $problems++
            }
        }
    }

    if ($script:Pst.Ansi) { Write-PstStatus ok (L 'Terminal : couleurs et affichage temps réel pris en charge') }
    else { Write-PstStatus warn (L 'Terminal sans séquences ANSI : affichage simplifié (essayez Windows Terminal)') }
    if ($script:Pst.IsWindows -and -not $env:WT_SESSION) { Write-PstStatus info (L 'Conseil : Windows Terminal offre le meilleur rendu (winget install Microsoft.WindowsTerminal)') }

    # Intégration au shell : chargement réel de chaque profil (partage réseau, stratégie...)
    if (Test-PstShell) {
        $blocked = @()
        foreach ($file in (Get-PstProfilePaths)) {
            if ((Test-Path -LiteralPath $file) -and (Read-PstProfile $file).Text -match '# >>> ps-tools >>>' -and -not (Test-PstProfileLoadable $file)) { $blocked += $file }
        }
        if ($blocked.Count) {
            foreach ($file in $blocked) {
                if ((Get-PstProfileLocation $file).IsNetwork) { Write-PstStatus warn (L 'Profil bloqué par la stratégie d''exécution (profil sur un partage réseau) : {0}' $file) }
                else { Write-PstStatus warn (L 'Profil bloqué par la stratégie d''exécution : {0}' $file) }
            }
            Write-PstStatus info (L 'Correctif guidé : pst shell on')
            $problems++
        }
        elseif ((Get-PstConfig).shell.remedy -eq 'terminal') { Write-PstStatus ok (L 'Intégration au shell active (profil Windows Terminal « ps-tools »)') }
        else { Write-PstStatus ok (L 'Intégration au shell active') }
    }
    else { Write-PstStatus info (L 'Intégration au shell inactive (pst shell on)') }

    $ai = Get-PstAiSettings
    $provider = Get-PstAiProvider $ai.Provider
    $key = Get-PstAiKey $ai.Provider
    if ($key.Key -or -not $provider.KeyRequired) { Write-PstStatus ok (L 'Assistant IA : {0} · {1}' $provider.Label $ai.Model) }
    else { Write-PstStatus info (L 'Assistant IA non configuré (pst setup)') }

    if (Test-PstAdmin) { Write-PstStatus ok (L 'Session administrateur : toutes les fonctions sont disponibles') }
    else { Write-PstStatus ok (L 'Session utilisateur : tout fonctionne, les cibles système de « clean » sont ignorées') }

    if ($script:Pst.IsWindows) {
        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) { Write-PstStatus ok (L 'Planificateur de tâches disponible (rappels)') }
        else { Write-PstStatus warn (L 'Planificateur de tâches indisponible : « remind » ne pourra pas notifier'); $problems++ }
        $legacy = Join-Path (Join-Path (Join-Path $env:ProgramFiles 'WindowsPowerShell') 'Scripts') 'monitor.cmd'
        if (Test-Path -LiteralPath $legacy) { Write-PstStatus warn (L 'Ancienne version 1 encore présente : relancez l''installation en administrateur pour la retirer'); $problems++ }
    }

    Write-Host ''
    if ($problems -eq 0) { Write-Host ('  ' + (Paint (L 'Tout est en ordre.') 'Ok' -Bold)) }
    else { Write-Host ('  ' + (Paint (L '{0} point(s) à vérifier.' $problems) 'Warn' -Bold)) }
    Write-Host ''
    if ($problems -gt 0) { exit 1 }
}

# ── Mise à jour et désinstallation ───────────────────────────────────────────

function Get-Bootstrap {
    param([string]$Source)
    if ($Source -match '^https?://') {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }
        $client = New-Object System.Net.WebClient
        try { return $client.DownloadString($Source.TrimEnd('/') + '/install.ps1') } finally { $client.Dispose() }
    }
    return [IO.File]::ReadAllText((Join-Path $Source 'install.ps1'))
}

function Invoke-Update {
    $info = Get-InstallInfo
    if ($null -eq $info) {
        Write-PstStatus info (L 'pst s''exécute depuis le dépôt : utilisez « git pull », ou lancez install.ps1.')
        return
    }
    if ($info.Scope -eq 'AllUsers' -and -not (Test-PstAdmin)) {
        Write-PstStatus err (L 'Cette installation est commune à tous les utilisateurs : lancez « pst update » depuis un terminal administrateur.')
        exit 1
    }
    $source = [string]$info.Source
    if ($source -notmatch '^https?://' -and -not (Test-Path -LiteralPath (Join-Path $source 'install.ps1'))) {
        $source = "https://raw.githubusercontent.com/$($script:Pst.Repo)/main"
    }
    try { $bootstrap = Get-Bootstrap $source }
    catch {
        Write-PstStatus err (L 'Téléchargement impossible : {0}' $_.Exception.Message)
        exit 1
    }
    $arguments = @{ Source = $source; Scope = [string]$info.Scope; Yes = $true }
    if ($info.Selection -eq 'custom') { $arguments.Tools = @($info.Tools) }
    $standardRoots = @((Join-Path $env:LOCALAPPDATA 'ps-tools'), (Join-Path $env:ProgramFiles 'ps-tools'))
    if ($standardRoots -notcontains [string]$info.Root) { $arguments.InstallRoot = [string]$info.Root; $arguments.NoPath = $true }
    & ([scriptblock]::Create($bootstrap)) @arguments
}

function Invoke-Remove {
    # Même chemin que la commande dédiée « pst-uninstall ».
    $arguments = @{}
    if ($Yes) { $arguments.Yes = $true }
    if ($Purge) { $arguments.Purge = $true }
    & (Join-Path $PSScriptRoot 'pst-uninstall.ps1') @arguments
}

# ── Intégration au shell ─────────────────────────────────────────────────────

function Invoke-Shell {
    param([string]$Action)
    Show-PstHeader -Tool 'pst' -Subtitle (L 'intégration au shell')
    switch -Regex ($Action) {
        '^(on|enable|install)$' {
            if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $appRoot 'shell') 'PsTools.Shell.ps1'))) { Write-PstStatus err (L 'Fichier d''intégration introuvable : lancez « pst update ».'); exit 1 }
            $remedy = ''
            if ((Get-PstConfig).shell.remedy -eq 'terminal') { $remedy = 'terminal' }
            Write-PstStatus step (L 'Vérification du chargement de votre profil PowerShell')
            $state = Invoke-PstShellActivation -AppRoot $appRoot -Remedy $remedy -Interactive:(-not $Yes)
            Write-Host ''
            switch ($state) {
                'active' { Write-PstStatus info (L 'Ouvrez un nouveau terminal pour en profiter. Aperçu des raccourcis : pst keys') }
                'terminal' { Write-PstStatus info (L 'Dans Windows Terminal, ouvrez un onglet « PowerShell · ps-tools » (menu ˅), ou faites-en le profil par défaut dans les paramètres.') }
                default { exit 1 }
            }
        }
        '^(off|disable|uninstall)$' {
            $changed = @(Disable-PstShell)
            foreach ($file in $changed) { Write-PstStatus ok (L 'Bloc retiré de : {0}' $file) }
            $hadRemedy = [bool]((Get-PstConfig).shell.remedy)
            Undo-PstShellRemedy
            if (-not $changed.Count -and -not $hadRemedy) { Write-PstStatus info (L 'L''intégration n''était pas active.') }
        }
        default {
            if (Test-PstShell) { Write-PstStatus ok (L 'Intégration active  (pst shell off pour la retirer)') }
            else { Write-PstStatus info (L 'Intégration inactive  (pst shell on pour l''activer)') }
            foreach ($file in (Get-PstProfilePaths)) { Write-Host (Paint "      $file" 'Dim') }
            Write-Host ''
            Write-Host ('  ' + (L 'Ce qu''elle apporte :'))
            foreach ($line in @(
                    (L 'Invite claire : dossier, branche Git, durée et échec de la dernière commande'),
                    (L 'Historique : flèches filtrées par ce qui est tapé, suggestions, menu de complétion'),
                    (L 'Raccourcis : Alt+A (IA), Alt+S (sudo), Alt+C (copier), Alt+G (Git)'),
                    (L 'Commandes : ll, la, .., mkcd, touch, which, grep, head, tail, df, open, sudo, reload'),
                    (L 'Favoris : mark, jump (j), marks, unmark  ·  Assistant : fix'))) { Write-Host ('    ' + (Paint $g.Info 'Accent2') + " $line") }
        }
    }
    Write-Host ''
}

function Show-Keys {
    Show-PstHeader -Tool 'pst' -Subtitle (L 'aide-mémoire')
    $sections = @(
        @((L 'Tableau de bord (pst)'), @(
                @("$($g.Up)$($g.Down)  j", (L 'Choisir un outil')), @((L 'Entrée'), (L 'Lancer l''outil (arguments facultatifs)')),
                @('1-9  ←→  Tab', (L 'Changer de catégorie')), @('/', (L 'Filtrer par nom ou description')),
                @('h', (L 'Afficher l''aide complète de l''outil')), @('s  u  k  d', (L 'Réglages, consommation IA, raccourcis, diagnostic')), @('q  Échap', (L 'Quitter le tableau de bord')))),
        @((L 'Raccourcis ps-tools (intégration au shell)'), @(
                @('Alt+A', (L 'Transforme la phrase tapée en commande PowerShell (IA)')),
                @('Alt+S', (L 'Ajoute « sudo » devant la ligne, ou rejoue la dernière commande en admin')),
                @('Alt+C', (L 'Copie la ligne en cours')), @('Alt+G', (L 'État Git du dossier (gst)')))),
        @((L 'Édition de la ligne'), @(
                @((L 'Flèche haut / bas'), (L 'Historique filtré par ce qui est déjà tapé')), @('Ctrl+R', (L 'Recherche dans l''historique')),
                @('Tab', (L 'Menu de complétion')), @((L 'Ctrl+Espace'), (L 'Toutes les complétions possibles')),
                @((L 'Échap'), (L 'Efface la ligne')), @('F2', (L 'Bascule les suggestions en liste (PowerShell 7)')), @('Ctrl+D', (L 'Ferme le terminal si la ligne est vide')))),
        @('Windows Terminal', @(
                @((L 'Ctrl+Maj+T'), (L 'Nouvel onglet')), @((L 'Alt+Maj+D'), (L 'Scinde le volet (même dossier)')), @((L 'Alt+Flèche'), (L 'Change de volet')),
                @((L 'Ctrl+Maj+P'), (L 'Palette de commandes')), @((L 'Ctrl+Maj+F'), (L 'Recherche dans la sortie')), @((L 'Ctrl+Molette'), 'Zoom'))),
        @((L 'Commandes du shell'), @(
                @((L 'mark <nom> / jump <nom>'), (L 'Favoris de dossiers (j en abrégé, jump - : dossier précédent)')), @('fix', (L 'Explique la dernière erreur et propose la correction')),
                @((L 'sudo <commande>'), (L 'Exécute en administrateur')), @('ll, la, .., mkcd, touch, which', (L 'Réflexes Unix')), @('grep, head, tail, df, open', (L 'Réflexes Unix'))))
    )
    foreach ($section in $sections) {
        Write-Host ('  ' + (Paint $section[0].ToUpper() 'Accent' -Bold))
        foreach ($row in $section[1]) { Write-Host ('    ' + (Paint (Format-PstPad $row[0] 32) 'Title' -Bold) + (Paint $row[1] 'Secondary')) }
        Write-Host ''
    }
    if (-not (Test-PstShell)) { Write-PstStatus info (L 'Intégration au shell inactive : « pst shell on » pour activer raccourcis et commandes.'); Write-Host '' }
}

# ── Aiguillage ───────────────────────────────────────────────────────────────

if ($Help -or (Test-PstHelpArg (@($Command) + @($Rest)))) {
    Show-PstHelp -Name 'pst' -Synopsis (L 'Tableau de bord et gestionnaire de la boîte à outils ps-tools.') `
        -Usage @((L 'pst [commande]')) `
        -Options @(
            @('(aucune)', (L 'Tableau de bord plein écran : catégories, outils, lancement')),
            @('setup', (L 'Réglages : langue, apparence, intégration au shell, assistant IA')),
            @('usage', (L 'Consommation de l''assistant IA : jetons, coût, budget')),
            @('list', (L 'Liste les outils installés')),
            @('keys', (L 'Aide-mémoire des raccourcis et commandes')),
            @('shell [on|off]', (L 'Intégration au shell : invite, raccourcis, alias, favoris')),
            @('doctor', (L 'Vérifie l''installation et l''environnement')),
            @('update', (L 'Installe la dernière version (mêmes outils, même périmètre)')),
            @('uninstall [-Yes] [-Purge]', (L 'Désinstalle ps-tools (identique à la commande pst-uninstall)')),
            @('version', (L 'Affiche la version'))
        ) `
        -Examples @('pst', 'pst setup', 'pst usage', 'pst doctor', 'pst update')
    exit 0
}

switch -Regex ($Command) {
    '^(|menu|run|hub)$' {
        if ((Test-PstInteractive) -and $script:Pst.Ansi -and -not $env:PSTOOLS_NO_HUB) { Show-Hub } else { Show-Home }
        break
    }
    '^(list|ls)$' { Show-PstHeader -Tool 'pst' -Subtitle (L 'outils'); Show-ToolList; break }
    '^(doctor|check)$' { Invoke-Doctor; break }
    '^(setup|config|configure|settings)$' { Invoke-PstSetupMenu -AppRoot $appRoot -Section (@($Rest) + '' | Select-Object -First 1); break }
    '^(usage|conso|cost)$' { Show-PstAiUsage; break }
    '^(keys|cheat|raccourcis)$' { Show-Keys; break }
    '^shell$' { Invoke-Shell (@($Rest) + '' | Select-Object -First 1); break }
    '^(update|upgrade)$' { Invoke-Update; break }
    '^(uninstall|remove)$' { Invoke-Remove; break }
    '^(version|-v|--version)$' { Write-Host "ps-tools $($script:Pst.Version)"; break }
    default {
        Write-PstStatus err (L 'Commande inconnue : « {0} » · voir « pst -Help »' $Command)
        exit 1
    }
}
