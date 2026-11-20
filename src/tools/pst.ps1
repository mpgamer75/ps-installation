<#
.SYNOPSIS
    pst — gestionnaire ps-tools : liste des outils, diagnostic, mise à jour, désinstallation.
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
$g = $script:Pst.Glyph

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

function Show-ToolList {
    $tools = @(Get-InstalledTools)
    $nameWidth = 0
    foreach ($t in $tools) { $nameWidth = [Math]::Max($nameWidth, $t.name.Length) }
    foreach ($category in @($tools | ForEach-Object { $_.category } | Select-Object -Unique)) {
        Write-Host ('  ' + (Paint $category.ToUpper() 'Accent' -Bold))
        foreach ($t in @($tools | Where-Object { $_.category -eq $category })) {
            $tag = ''
            if ($t.admin -eq 'optionnel') { $tag = Paint "  $($g.Dot) plus complet en admin" 'Warn' }
            Write-Host ('    ' + (Paint $t.name.PadRight($nameWidth) 'Title' -Bold) + '  ' + (Paint $t.description 'Dim') + $tag)
        }
        Write-Host ''
    }
}

function Show-Home {
    Show-PstBanner
    Show-ToolList
    Write-Host ('  ' + (Paint '<commande> -Help' 'Ok') + (Paint '  aide détaillée d''un outil' 'Dim'))
    Write-Host ('  ' + (Paint 'pst menu        ' 'Ok') + (Paint '  lance un outil au clavier' 'Dim'))
    Write-Host ('  ' + (Paint 'pst keys        ' 'Ok') + (Paint '  aide-mémoire des raccourcis' 'Dim'))
    Write-Host ('  ' + (Paint 'pst shell on    ' 'Ok') + (Paint '  invite, raccourcis et commandes façon Unix' 'Dim'))
    Write-Host ('  ' + (Paint 'pst doctor      ' 'Ok') + (Paint '  vérifie l''installation' 'Dim'))
    Write-Host ('  ' + (Paint 'pst update      ' 'Ok') + (Paint '  installe la dernière version' 'Dim'))
    Write-Host ('  ' + (Paint 'pst-uninstall   ' 'Ok') + (Paint '  désinstalle ps-tools' 'Dim'))
    Write-Host ''
}

function Invoke-Doctor {
    Show-PstHeader -Tool 'pst' -Subtitle 'diagnostic'
    $problems = 0
    $info = Get-InstallInfo
    $bin = Join-Path (Split-Path -Parent $appRoot) 'bin'

    # PowerShell
    $version = $PSVersionTable.PSVersion
    if ($version -ge [Version]'5.1') { Write-PstStatus ok "PowerShell $version" }
    else { Write-PstStatus err "PowerShell $version : la version 5.1 ou plus est requise"; $problems++ }

    # Installation
    if ($info) {
        $scope = 'utilisateur courant'
        if ($info.Scope -eq 'AllUsers') { $scope = 'tous les utilisateurs' }
        Write-PstStatus ok "Version $($info.Version) $($g.Dot) $scope $($g.Dot) $($info.Root)"
    }
    else { Write-PstStatus info "Exécution depuis le dépôt (non installé) : $appRoot" }

    # Fichiers
    $manifest = Get-Manifest
    $tools = @(Get-InstalledTools)
    if ($manifest) { Write-PstStatus ok "$($tools.Count) outil(s) sur $(@($manifest.tools).Count) disponibles" }
    else { Write-PstStatus err 'Manifeste introuvable : réinstallez avec « pst update »'; $problems++ }

    # PATH et conflits de noms
    if ($info -and $script:Pst.IsWindows) {
        $entries = @($env:PATH -split ';' | ForEach-Object { $_.Trim().TrimEnd('\') })
        if ($entries -contains $bin.TrimEnd('\')) { Write-PstStatus ok 'Dossier des commandes présent dans le PATH' }
        else { Write-PstStatus warn "PATH : $bin est absent de ce terminal (ouvrez-en un nouveau, ou « pst update »)"; $problems++ }
        foreach ($t in $tools) {
            $first = Get-Command -Name $t.name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($first -and (Split-Path -Parent $first.Source).TrimEnd('\') -ine $bin.TrimEnd('\')) {
                Write-PstStatus warn "« $($t.name) » est masqué par $($first.Source)"
                $problems++
            }
        }
    }

    # Terminal
    if ($script:Pst.Ansi) { Write-PstStatus ok 'Terminal : couleurs et affichage temps réel pris en charge' }
    else { Write-PstStatus warn 'Terminal sans séquences ANSI : affichage simplifié (essayez Windows Terminal)' }
    if ($script:Pst.IsWindows -and -not $env:WT_SESSION) { Write-PstStatus info 'Conseil : Windows Terminal offre le meilleur rendu (winget install Microsoft.WindowsTerminal)' }

    # Intégration au shell et assistant
    if (Test-PstShell) {
        $policy = Get-PstEffectivePolicy
        if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') { Write-PstStatus warn "Intégration au shell installée mais bloquée par la stratégie d'exécution ($policy) : « pst shell on » propose le correctif"; $problems++ }
        else { Write-PstStatus ok 'Intégration au shell active' }
    }
    else { Write-PstStatus info 'Intégration au shell inactive (pst shell on)' }
    if ($env:ANTHROPIC_API_KEY -or (Test-Path -LiteralPath (Join-Path (Get-PstDataDir) 'ask.json'))) { Write-PstStatus ok 'Assistant « ask » configuré' }
    else { Write-PstStatus info 'Assistant « ask » non configuré (ask -Setup)' }

    # Droits
    if (Test-PstAdmin) { Write-PstStatus ok 'Session administrateur : toutes les fonctions sont disponibles' }
    else { Write-PstStatus ok 'Session utilisateur : tout fonctionne, les cibles système de « clean » sont ignorées' }

    # Planificateur de tâches (remind)
    if ($script:Pst.IsWindows) {
        if (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue) { Write-PstStatus ok 'Planificateur de tâches disponible (rappels)' }
        else { Write-PstStatus warn 'Planificateur de tâches indisponible : « remind » ne pourra pas notifier'; $problems++ }
        $legacy = Join-Path (Join-Path (Join-Path $env:ProgramFiles 'WindowsPowerShell') 'Scripts') 'monitor.cmd'
        if (Test-Path -LiteralPath $legacy) { Write-PstStatus warn 'Ancienne version 1 encore présente : relancez l''installation en administrateur pour la retirer'; $problems++ }
    }

    Write-Host ''
    if ($problems -eq 0) { Write-Host ('  ' + (Paint 'Tout est en ordre.' 'Ok' -Bold)) }
    else { Write-Host ('  ' + (Paint "$problems point(s) à vérifier." 'Warn' -Bold)) }
    Write-Host ''
    if ($problems -gt 0) { exit 1 }
}

function Get-Bootstrap {
    # Retourne le texte de install.ps1 depuis la source d'installation.
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
        Write-PstStatus info 'pst s''exécute depuis le dépôt : utilisez « git pull », ou lancez install.ps1.'
        return
    }
    if ($info.Scope -eq 'AllUsers' -and -not (Test-PstAdmin)) {
        Write-PstStatus err 'Cette installation est commune à tous les utilisateurs : lancez « pst update » depuis un terminal administrateur.'
        exit 1
    }
    $source = [string]$info.Source
    if ($source -notmatch '^https?://' -and -not (Test-Path -LiteralPath (Join-Path $source 'install.ps1'))) {
        $source = "https://raw.githubusercontent.com/$($script:Pst.Repo)/main"
    }
    try { $bootstrap = Get-Bootstrap $source }
    catch {
        Write-PstStatus err "Téléchargement impossible : $($_.Exception.Message)"
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

function Invoke-Shell {
    param([string]$Action)
    $info = Get-InstallInfo
    Show-PstHeader -Tool 'pst' -Subtitle 'intégration au shell'
    switch -Regex ($Action) {
        '^(on|enable|install)$' {
            if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $appRoot 'shell') 'PsTools.Shell.ps1'))) { Write-PstStatus err 'Fichier d''intégration introuvable : lancez « pst update ».'; exit 1 }
            foreach ($file in (Enable-PstShell -AppRoot $appRoot)) { Write-PstStatus ok "Profil mis à jour : $file" }
            $policy = Get-PstEffectivePolicy
            if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
                Write-Host ''
                Write-PstStatus warn "La stratégie d'exécution actuelle ($policy) empêche PowerShell de charger votre profil."
                $command = 'Set-ExecutionPolicy RemoteSigned -Scope CurrentUser'
                if ((Test-PstInteractive) -and -not $Yes -and (Read-PstConfirm "Autoriser les scripts locaux pour votre compte ($command) ?" -DefaultYes)) {
                    try { Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -ErrorAction Stop; Write-PstStatus ok 'Stratégie réglée sur RemoteSigned pour votre compte (aucun droit administrateur requis).' }
                    catch { Write-PstStatus err "Modification impossible : $($_.Exception.Message)" }
                }
                else { Write-PstStatus info "À lancer vous-même pour l'activer : $command" }
            }
            Write-Host ''
            Write-PstStatus info 'Ouvrez un nouveau terminal pour en profiter. Aperçu des raccourcis : pst keys'
        }
        '^(off|disable|uninstall)$' {
            $changed = @(Disable-PstShell)
            if ($changed.Count) { foreach ($file in $changed) { Write-PstStatus ok "Bloc retiré de : $file" } }
            else { Write-PstStatus info 'L''intégration n''était pas active.' }
        }
        default {
            if (Test-PstShell) { Write-PstStatus ok 'Intégration active  (pst shell off pour la retirer)' }
            else { Write-PstStatus info 'Intégration inactive  (pst shell on pour l''activer)' }
            foreach ($file in (Get-PstProfilePaths)) { Write-Host (Paint "      $file" 'Dim') }
            Write-Host ''
            Write-Host '  Ce qu''elle apporte :'
            foreach ($line in @(
                    'Invite claire : dossier, branche Git, durée et échec de la dernière commande',
                    'Historique : flèches filtrées par ce qui est tapé, suggestions, menu de complétion',
                    'Raccourcis : Alt+A (IA), Alt+S (sudo), Alt+C (copier), Alt+G (Git)',
                    'Commandes : ll, la, .., mkcd, touch, which, grep, head, tail, df, open, sudo, reload',
                    'Favoris : mark, jump (j), marks, unmark  ·  Assistant : fix')) { Write-Host ('    ' + (Paint $g.Info 'Accent2') + " $line") }
        }
    }
    Write-Host ''
    $null = $info
}

function Show-Keys {
    Show-PstHeader -Tool 'pst' -Subtitle 'aide-mémoire'
    $sections = [ordered]@{
        'Raccourcis ps-tools (intégration au shell)' = @(
            @('Alt+A', 'Transforme la phrase tapée en commande PowerShell (IA)'),
            @('Alt+S', 'Ajoute « sudo » devant la ligne, ou rejoue la dernière commande en admin'),
            @('Alt+C', 'Copie la ligne en cours'), @('Alt+G', 'État Git du dossier (gst)'))
        'Édition de la ligne' = @(
            @('Flèche haut / bas', 'Historique filtré par ce qui est déjà tapé'), @('Ctrl+R', 'Recherche dans l''historique'),
            @('Tab', 'Menu de complétion'), @('Ctrl+Espace', 'Toutes les complétions possibles'),
            @('Ctrl+Flèche', 'Saute de mot en mot'), @('Ctrl+Retour arr.', 'Efface le mot précédent'),
            @('Échap', 'Efface la ligne'), @('F2', 'Bascule les suggestions en liste (PowerShell 7)'), @('Ctrl+D', 'Ferme le terminal si la ligne est vide'))
        'Windows Terminal' = @(
            @('Ctrl+Maj+T', 'Nouvel onglet'), @('Alt+Maj+D', 'Scinde le volet (même dossier)'), @('Alt+Flèche', 'Change de volet'),
            @('Ctrl+Maj+P', 'Palette de commandes'), @('Ctrl+Maj+F', 'Recherche dans la sortie'), @('Ctrl+Molette', 'Zoom'))
        'Commandes du shell' = @(
            @('mark <nom> / jump <nom>', 'Favoris de dossiers (j en abrégé, jump - : dossier précédent)'), @('fix', 'Explique la dernière erreur et propose la correction'),
            @('sudo <commande>', 'Exécute en administrateur'), @('ll, la, .., mkcd, touch, which', 'Réflexes Unix'), @('grep, head, tail, df, open', 'Réflexes Unix'))
    }
    foreach ($title in $sections.Keys) {
        Write-Host ('  ' + (Paint $title.ToUpper() 'Accent' -Bold))
        foreach ($row in $sections[$title]) { Write-Host ('    ' + (Paint (Format-PstPad $row[0] 32) 'Title' -Bold) + (Paint $row[1] 'Dim')) }
        Write-Host ''
    }
    if (-not (Test-PstShell)) { Write-PstStatus info 'Intégration au shell inactive : « pst shell on » pour activer raccourcis et commandes.'; Write-Host '' }
}

function Show-Menu {
    # Lanceur : choisir un outil au clavier.
    $tools = @(Get-InstalledTools | Where-Object { $_.name -notlike 'pst*' })
    if (-not (Test-PstInteractive)) { Show-Home; return }
    Show-PstBanner
    $nameWidth = 0
    foreach ($t in $tools) { $nameWidth = [Math]::Max($nameWidth, $t.name.Length) }
    $labels = @($tools | ForEach-Object { '{0}  {1}' -f $_.name.PadRight($nameWidth), $_.description })
    $pick = Read-PstChoice -Title 'Quel outil lancer ?' -Items $labels
    if ($pick -lt 0) { return }
    Write-Host ''
    $tool = $tools[$pick]
    $needsArgument = @('ask', 'watch', 'logtail', 'dev') -contains $tool.name
    if ($needsArgument) { & (Join-Path $PSScriptRoot "$($tool.name).ps1") -Help }
    else { & (Join-Path $PSScriptRoot "$($tool.name).ps1") }
}

if ($Help -or (Test-PstHelpArg (@($Command) + @($Rest)))) {
    Show-PstHelp -Name 'pst' -Synopsis 'Gestionnaire de la boîte à outils ps-tools.' `
        -Usage @('pst [commande]') `
        -Options @(
            @('list', 'Liste les outils installés'),
            @('menu', 'Lanceur : choisir un outil au clavier'),
            @('keys', 'Aide-mémoire des raccourcis et commandes'),
            @('shell [on|off]', 'Intégration au shell : invite, raccourcis, alias, favoris'),
            @('doctor', 'Vérifie l''installation et l''environnement'),
            @('update', 'Installe la dernière version (mêmes outils, même périmètre)'),
            @('uninstall [-Yes] [-Purge]', 'Désinstalle ps-tools (identique à la commande pst-uninstall)'),
            @('version', 'Affiche la version')
        ) `
        -Examples @('pst', 'pst doctor', 'pst update')
    exit 0
}

switch -Regex ($Command) {
    '^$' { Show-Home; break }
    '^(list|ls)$' { Show-PstHeader -Tool 'pst' -Subtitle 'outils'; Show-ToolList; break }
    '^(doctor|check)$' { Invoke-Doctor; break }
    '^(menu|run)$' { Show-Menu; break }
    '^(keys|cheat|raccourcis)$' { Show-Keys; break }
    '^shell$' { Invoke-Shell (@($Rest) + '' | Select-Object -First 1); break }
    '^(update|upgrade)$' { Invoke-Update; break }
    '^(uninstall|remove)$' { Invoke-Remove; break }
    '^(version|-v|--version)$' { Write-Host "ps-tools $($script:Pst.Version)"; break }
    default {
        Write-PstStatus err "Commande inconnue : « $Command » $($g.Dot) voir « pst -Help »"
        exit 1
    }
}
