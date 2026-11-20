# ─────────────────────────────────────────────────────────────────────────────
#  ps-tools — assistant de configuration (installation et « pst setup »)
#  Chargée après PsTools.ps1 et PsTools.AI.ps1.
# ─────────────────────────────────────────────────────────────────────────────

Import-PstStrings 'PsTools.Wizard'

function Get-PstEnvironmentReport {
    # État de la machine, affiché en ouverture de l'assistant.
    $report = @{ Os = 'Windows'; Shell = "PowerShell $($PSVersionTable.PSVersion)"; Admin = (Test-PstAdmin); Terminal = (L 'Console Windows'); Profiles = @() }
    if (-not $script:Pst.IsWindows) { $report.Os = [string][Environment]::OSVersion.Platform }
    else { try { $report.Os = ((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption -replace 'Microsoft ', '') } catch { $null = $_ } }
    if ($env:WT_SESSION) { $report.Terminal = 'Windows Terminal' } elseif ($env:TERM_PROGRAM) { $report.Terminal = $env:TERM_PROGRAM }
    foreach ($file in (Get-PstProfilePaths)) {
        if (-not (Get-PstShellExecutable $file)) { continue }
        $location = Get-PstProfileLocation $file
        $report.Profiles += @{ Path = $file; IsNetwork = $location.IsNetwork; Server = $location.Server; Loadable = (Test-PstProfileLoadable $file) }
    }
    return $report
}

function Show-PstEnvironment {
    param($Report)
    $g = $script:Pst.Glyph
    $rights = L 'utilisateur standard'
    if ($Report.Admin) { $rights = L 'administrateur' }
    $lines = @(
        ((Paint (Format-PstPad (L 'Système') 12) 'Accent') + $Report.Os),
        ((Paint (Format-PstPad 'Shell' 12) 'Accent') + $Report.Shell),
        ((Paint (Format-PstPad 'Session' 12) 'Accent') + $rights),
        ((Paint (Format-PstPad 'Terminal' 12) 'Accent') + $Report.Terminal)
    )
    foreach ($p in $Report.Profiles) {
        $where = L 'local'
        if ($p.IsNetwork) { $where = L 'partage réseau {0}' $p.Server }
        $state = Paint "$($g.Ok) $(L 'chargeable')" 'Ok'
        if (-not $p.Loadable) { $state = Paint "$($g.Warn) $(L 'chargement bloqué')" 'Warn' }
        $name = L 'Profil 5.1'
        if ($p.Path -notmatch 'WindowsPowerShell') { $name = L 'Profil 7' }
        $lines += (Paint (Format-PstPad $name 12) 'Accent') + $where + '  ' + $state
    }
    Format-PstBox -Title (L 'Votre environnement') -Lines $lines | Write-PstLine
}

# ── Intégration au shell : activation et profil bloqué ───────────────────────

function Get-PstShellRemedies {
    # Solutions possibles quand le profil ne peut pas se charger.
    param($Blocked)
    $server = $null
    foreach ($file in $Blocked) {
        $location = Get-PstProfileLocation $file
        if ($location.IsNetwork) { $server = $location.Server; break }
    }
    $list = @()
    if ($server) {
        $list += @{ Id = 'trust'; Label = (L 'Faire confiance au partage {0} (recommandé)' $server); Hint = (L 'zone Intranet locale, pour votre compte uniquement'); Server = $server }
    }
    $list += @{ Id = 'bypass'; Label = (L 'Autoriser les scripts non signés pour votre compte'); Hint = (L 'stratégie Bypass, portée CurrentUser') }
    if (Test-PstWindowsTerminal) {
        $list += @{ Id = 'terminal'; Label = (L 'Utiliser un profil Windows Terminal « ps-tools »'); Hint = (L 'ne touche ni au partage ni à la stratégie') }
    }
    $list += @{ Id = 'none'; Label = (L 'Ne pas activer l''intégration'); Hint = (L 'les commandes restent disponibles') }
    return $list
}

function Show-PstBlockedProfileHelp {
    param($Blocked)
    $first = $Blocked | Select-Object -First 1
    $location = Get-PstProfileLocation $first
    $lines = @()
    if ($location.IsNetwork) {
        $lines += L 'Votre profil PowerShell se trouve sur un partage réseau :'
        $lines += Paint (Limit-PstText $first 76) 'Title'
        $lines += ''
        $lines += L 'Windows considère les scripts de ce partage comme venant d''Internet : la'
        $lines += L 'stratégie d''exécution exige alors une signature numérique, et le profil est'
        $lines += L 'refusé à chaque ouverture du terminal (« n''est pas signé numériquement »).'
    }
    else {
        $lines += L 'La stratégie d''exécution de PowerShell empêche de charger votre profil :'
        $lines += Paint (Limit-PstText $first 76) 'Title'
    }
    Format-PstBox -Title (L 'Profil PowerShell bloqué') -Lines $lines -Color 'Warn' | Write-PstLine
    Write-Host ''
}

function Invoke-PstShellRemedy {
    # Applique une solution et enregistre ce qui a été changé (pour pouvoir l'annuler).
    param([hashtable]$Remedy)
    $config = Get-PstConfig
    switch ($Remedy.Id) {
        'trust' {
            Grant-PstShareTrust $Remedy.Server
            $config.shell.trustedHost = $Remedy.Server
            Write-PstStatus ok (L 'Partage {0} classé en zone Intranet locale (votre compte)' $Remedy.Server)
        }
        'bypass' {
            if (-not $config.shell.previousPolicy) {
                try { $config.shell.previousPolicy = [string](Get-ExecutionPolicy -Scope CurrentUser) } catch { $config.shell.previousPolicy = 'Undefined' }
            }
            Set-PstUserPolicy 'Bypass'
            Write-PstStatus ok (L 'Stratégie d''exécution de votre compte réglée sur Bypass')
        }
    }
    $config.shell.remedy = $Remedy.Id
    Save-PstConfig $config
}

function Undo-PstShellRemedy {
    # Annule les changements de sécurité faits pour l'intégration au shell.
    $config = Get-PstConfig
    if ($config.shell.trustedHost) {
        try { Revoke-PstShareTrust $config.shell.trustedHost; Write-PstStatus ok (L 'Partage {0} retiré de la zone Intranet' $config.shell.trustedHost) } catch { $null = $_ }
    }
    if ($config.shell.previousPolicy) {
        try { Set-PstUserPolicy $config.shell.previousPolicy; Write-PstStatus ok (L 'Stratégie d''exécution rétablie ({0})' $config.shell.previousPolicy) } catch { $null = $_ }
    }
    if (Remove-PstTerminalProfile) { Write-PstStatus ok (L 'Profil Windows Terminal « ps-tools » retiré') }
    $config.shell.trustedHost = ''; $config.shell.previousPolicy = ''; $config.shell.remedy = ''
    Save-PstConfig $config
}

function Invoke-PstShellActivation {
    # Active l'intégration au shell sans jamais laisser un profil qui échoue au démarrage.
    #   -Remedy  : solution déjà choisie (assistant d'installation)
    #   -Interactive : propose les solutions si le profil est bloqué
    # Retourne 'active', 'terminal' ou 'blocked'.
    param([string]$AppRoot, [string]$Remedy, [switch]$Interactive)
    $shellScript = Join-Path (Join-Path $AppRoot 'shell') 'PsTools.Shell.ps1'
    if ($Remedy -eq 'terminal') {
        $null = Set-PstTerminalProfile $shellScript
        $config = Get-PstConfig; $config.shell.remedy = 'terminal'; Save-PstConfig $config
        Write-PstStatus ok (L 'Profil Windows Terminal « PowerShell · ps-tools » ajouté')
        return 'terminal'
    }

    $result = Enable-PstShell -AppRoot $AppRoot
    foreach ($file in $result.Written) { Write-PstStatus ok (L 'Profil mis à jour : {0}' $file) }
    if ($result.Blocked.Count -eq 0) { return 'active' }

    $tried = @()
    if ($Remedy -and $Remedy -ne 'none') {
        $choice = @(Get-PstShellRemedies $result.Blocked | Where-Object { $_.Id -eq $Remedy }) | Select-Object -First 1
        if ($choice) {
            Invoke-PstShellRemedy $choice
            $tried += $Remedy
            $result = Enable-PstShell -AppRoot $AppRoot
            foreach ($file in $result.Written) { Write-PstStatus ok (L 'Profil mis à jour : {0}' $file) }
            if ($result.Blocked.Count -eq 0) { return 'active' }
            Write-PstStatus warn (L 'Le profil reste bloqué malgré ce réglage (sans doute imposé par une stratégie de groupe).')
        }
    }

    while ($Interactive -and (Test-PstInteractive)) {
        Write-Host ''
        Show-PstBlockedProfileHelp $result.Blocked
        $options = @(Get-PstShellRemedies $result.Blocked | Where-Object { $tried -notcontains $_.Id })
        $pick = Read-PstChoice -Title (L 'Comment voulez-vous continuer ?') -Items @($options | ForEach-Object { $_.Label }) -Hints @($options | ForEach-Object { $_.Hint })
        Write-Host ''
        if ($pick -lt 0 -or $options[$pick].Id -eq 'none') { break }
        $option = $options[$pick]
        if ($option.Id -eq 'terminal') { return (Invoke-PstShellActivation -AppRoot $AppRoot -Remedy 'terminal') }
        try { Invoke-PstShellRemedy $option } catch { Write-PstStatus err (L 'Réglage impossible : {0}' $_.Exception.Message) }
        $tried += $option.Id
        $result = Enable-PstShell -AppRoot $AppRoot
        foreach ($file in $result.Written) { Write-PstStatus ok (L 'Profil mis à jour : {0}' $file) }
        if ($result.Blocked.Count -eq 0) { return 'active' }
        Write-PstStatus warn (L 'Le profil reste bloqué malgré ce réglage (sans doute imposé par une stratégie de groupe).')
    }

    foreach ($file in $result.Blocked) { Write-PstStatus warn (L 'Profil non modifié (chargement bloqué) : {0}' $file) }
    Write-PstStatus info (L 'Aucune erreur ne s''affichera au démarrage. Pour réessayer : pst shell on')
    return 'blocked'
}

# ── Étapes ───────────────────────────────────────────────────────────────────

function Read-PstThemeChoice {
    $g = $script:Pst.Glyph
    $names = @($script:PstThemes.Keys)
    $labels = @(); $hints = @()
    foreach ($n in $names) {
        $t = $script:PstThemes[$n]
        $text = Get-PstThemeText $n
        $labels += $text.Label
        $swatch = ''
        if ($script:Pst.Ansi) {
            foreach ($role in 'Accent', 'Accent2', 'Ok', 'Warn', 'Err') { $swatch += Paint ($g.Full * 2) $t[$role] }
            $swatch += '  ' + (Paint $text.Hint $t.Dim)
        }
        else { $swatch = $text.Hint }
        $hints += $swatch
    }
    $current = [Math]::Max(0, [array]::IndexOf($names, $script:Pst.ThemeName))
    $pick = Read-PstChoice -Title (L 'Quel thème de couleurs ?') -Items $labels -Hints $hints -Default $current
    if ($pick -lt 0) { return $null }
    return $names[$pick]
}

function Read-PstShellChoice {
    # Retourne @{ Enabled; Prompt; Keys; Aliases; Remedy } ou $null (retour).
    param($Report)
    $config = Get-PstConfig
    $pick = Read-PstChoice -Title (L 'Activer l''intégration au shell ?') -Items @((L 'Oui, l''activer'), (L 'Non, pas maintenant')) -Hints @((L 'recommandé'), (L 'activable plus tard : pst shell on'))
    if ($pick -lt 0) { return $null }
    if ($pick -eq 1) { return @{ Enabled = $false } }
    Write-Host ''
    $items = @((L 'Invite enrichie : dossier, branche Git, durée, erreurs'), (L 'Raccourcis : Alt+A (IA), Alt+S (sudo), Alt+C, Alt+G'), (L 'Commandes façon Unix : ll, grep, touch, sudo, which...'))
    $selected = @([bool]$config.shell.prompt, [bool]$config.shell.keys, [bool]$config.shell.aliases)
    $parts = Read-PstMultiChoice -Title (L 'Que voulez-vous activer ? (favoris « jump » et « fix » toujours inclus)') -Items $items -Selected $selected
    if ($null -eq $parts) { return $null }
    $choice = @{ Enabled = $true; Prompt = ($parts -contains 0); Keys = ($parts -contains 1); Aliases = ($parts -contains 2); Remedy = '' }

    $blocked = @($Report.Profiles | Where-Object { -not $_.Loadable } | ForEach-Object { $_.Path })
    if ($blocked.Count) {
        Write-Host ''
        Show-PstBlockedProfileHelp $blocked
        $options = @(Get-PstShellRemedies $blocked)
        $r = Read-PstChoice -Title (L 'Comment charger l''intégration ?') -Items @($options | ForEach-Object { $_.Label }) -Hints @($options | ForEach-Object { $_.Hint })
        if ($r -lt 0) { return $null }
        $choice.Remedy = $options[$r].Id
        if ($choice.Remedy -eq 'none') { $choice.Enabled = $false }
    }
    return $choice
}

function Save-PstShellChoice {
    param([hashtable]$Choice)
    $config = Get-PstConfig
    $config.shell.prompt = [bool]$Choice.Prompt
    $config.shell.keys = [bool]$Choice.Keys
    $config.shell.aliases = [bool]$Choice.Aliases
    Save-PstConfig $config
}

function Format-PstAiSummary {
    param($Choice)
    if ($Choice -isnot [hashtable]) { return (Paint (L 'à configurer plus tard (pst setup)') 'Dim') }
    $p = Get-PstAiProvider $Choice.Provider
    $text = "$($p.Label) $($script:Pst.Glyph.Dot) $($Choice.Model)"
    if ($Choice.Budget -gt 0) { $text += " $($script:Pst.Glyph.Dot) " + (L 'budget {0}/mois' (Format-PstMoney $Choice.Budget)) }
    return $text
}

function Format-PstShellSummary {
    param($Choice)
    if (-not $Choice -or -not $Choice.Enabled) { return (Paint (L 'non activée') 'Dim') }
    $parts = @()
    if ($Choice.Prompt) { $parts += L 'invite' }
    if ($Choice.Keys) { $parts += L 'raccourcis' }
    if ($Choice.Aliases) { $parts += L 'commandes Unix' }
    $parts += L 'favoris'
    $text = L 'activée : {0}' ($parts -join ', ')
    switch ($Choice.Remedy) {
        'trust' { $text += L ' (partage réseau approuvé)' }
        'bypass' { $text += L ' (stratégie Bypass)' }
        'terminal' { $text += L ' (profil Windows Terminal)' }
    }
    return $text
}

# ── Langue ───────────────────────────────────────────────────────────────────
# L'écran de choix est toujours bilingue : la langue n'est pas encore choisie.

function Get-PstLanguageName {
    param([string]$Lang)
    if ($Lang -eq 'en') { return 'English' }
    return 'Français'
}

function Read-PstLanguageChoice {
    # Retourne 'fr', 'en' ou $null (Échap).
    $codes = @('fr', 'en')
    $current = [Math]::Max(0, [array]::IndexOf($codes, [string]$script:Pst.Lang))
    $pick = Read-PstChoice -Items @((Get-PstLanguageName 'fr'), (Get-PstLanguageName 'en')) -Default $current
    if ($pick -lt 0) { return $null }
    return $codes[$pick]
}

function Switch-PstLanguage {
    # Change la langue de la session et recharge les dictionnaires : depuis les fichiers
    # (-Names), ou par -Loader quand ils ne sont pas sur le disque (amorce lancée depuis le web).
    param([string]$Lang, [string[]]$Names = @('PsTools', 'PsTools.AI', 'PsTools.Wizard'), [scriptblock]$Loader)
    if ($Lang -ne $script:Pst.Lang) { Set-PstLanguage $Lang }
    if ($Loader) { & $Loader }
    else { foreach ($n in $Names) { Import-PstStrings $n } }
}

function Get-PstToolDescription {
    # Description d'un outil du manifeste, en anglais quand elle existe (description_en).
    param($Tool)
    if ($script:Pst.Lang -eq 'en' -and $Tool.description_en) { return [string]$Tool.description_en }
    return [string]$Tool.description
}

# ── Assistant d'installation ─────────────────────────────────────────────────

function Get-PstWizardStepLabel {
    # Nom affiché d'une étape (l'identifiant, lui, reste en français).
    param([string]$Id)
    switch ($Id) {
        'Langue' { return 'Langue / Language' }
        'Bienvenue' { return (L 'Bienvenue') }
        'Portée' { return (L 'Portée') }
        'Outils' { return (L 'Outils') }
        'Apparence' { return (L 'Apparence') }
        'Shell' { return (L 'Shell') }
        'IA' { return (L 'IA') }
        'Résumé' { return (L 'Résumé') }
    }
    return $Id
}

function Invoke-PstInstallWizard {
    # Recueille tous les choix, étape par étape, avec retour arrière (Échap) et
    # récapitulatif. N'installe rien : retourne l'état, ou $null si annulé.
    #   -OnLanguage : recharge les dictionnaires après le choix de la langue (setup.ps1).
    param($Manifest, [bool]$IsAdmin, [hashtable]$Roots, [string]$ScopeDefault = 'CurrentUser', [scriptblock]$OnLanguage)
    $g = $script:Pst.Glyph
    $state = @{ Language = $script:Pst.Lang; Scope = $ScopeDefault; Tools = $null; Theme = $script:Pst.ThemeName; Shell = $null; Ai = $null; Report = $null }
    $steps = @('Langue', 'Bienvenue')
    if ($IsAdmin) { $steps += 'Portée' }
    $steps += @('Outils', 'Apparence', 'Shell', 'IA', 'Résumé')
    $optional = @($Manifest.tools | Where-Object { -not $_.required })

    $i = 0
    while ($i -lt $steps.Count) {
        $name = $steps[$i]
        # Recalculé à chaque étape : la langue peut avoir changé.
        $labels = @($steps | ForEach-Object { Get-PstWizardStepLabel $_ })
        $caption = L 'assistant d''installation'
        $back = $false
        $jump = $null
        switch ($name) {
            'Langue' {
                Show-PstWizardFrame -Steps $labels -Current $i -Caption $caption -Title 'Langue / Language' -Text 'Choisissez la langue de ps-tools. · Choose the ps-tools language.'
                $lang = Read-PstLanguageChoice
                if (-not $lang) { return $null }
                Switch-PstLanguage $lang -Loader $OnLanguage
                $state.Language = $lang
            }
            'Bienvenue' {
                Show-PstWizardFrame -Steps $labels -Current $i -Caption $caption -Title (L 'Bienvenue dans ps-tools {0}' $Manifest.version) -Text (L 'Cet assistant installe les commandes, puis configure l''apparence, l''intégration au shell et l''assistant IA. Tout se modifie ensuite avec « pst setup ». Échap revient à l''étape précédente.')
                Get-PstBanner | Select-Object -Skip 1 | Write-PstLine
                Write-Host ''
                if (-not $state.Report) { $state.Report = Show-PstSpinner (L 'Analyse de votre environnement') { Get-PstEnvironmentReport } }
                Show-PstEnvironment $state.Report
                Write-Host ''
                $pick = Read-PstChoice -Title (L 'Prêt ?') -Items @((L 'Commencer'), (L 'Quitter'))
                if ($pick -lt 0) { $back = $true }
                elseif ($pick -ne 0) { return $null }
            }
            'Portée' {
                Show-PstWizardFrame -Steps $labels -Current $i -Caption $caption -Title (L 'Pour qui installer ?') -Text (L 'Votre session a les droits administrateur : ps-tools peut être installé pour tous les utilisateurs de ce PC. Une installation pour vous seul reste le choix le plus simple.')
                $pick = Read-PstChoice -Items @((L 'Pour moi uniquement'), (L 'Pour tous les utilisateurs')) -Hints @("$(L 'recommandé') $($g.Dot) %LOCALAPPDATA%\ps-tools", '%ProgramFiles%\ps-tools') -Default ([int]($state.Scope -eq 'AllUsers'))
                if ($pick -lt 0) { $back = $true } elseif ($pick -eq 1) { $state.Scope = 'AllUsers' } else { $state.Scope = 'CurrentUser' }
            }
            'Outils' {
                Show-PstWizardFrame -Steps $labels -Current $i -Caption $caption -Title (L 'Quels outils installer ?') -Text (L 'Tous sont cochés. Espace pour décocher, A pour tout inverser. « pst » et « pst-uninstall » sont toujours installés.')
                $width = 0
                foreach ($t in $optional) { $width = [Math]::Max($width, $t.name.Length) }
                $items = @($optional | ForEach-Object { '{0}  {1}' -f $_.name.PadRight($width), (Get-PstToolDescription $_) })
                $selected = New-Object 'bool[]' $optional.Count
                for ($k = 0; $k -lt $optional.Count; $k++) { $selected[$k] = ($null -eq $state.Tools) -or ($state.Tools -contains $optional[$k].name) }
                $picked = Read-PstMultiChoice -Items $items -Selected $selected
                if ($null -eq $picked) { $back = $true }
                else { $state.Tools = @($picked | ForEach-Object { $optional[$_].name }) }
            }
            'Apparence' {
                Show-PstWizardFrame -Steps $labels -Current $i -Caption $caption -Title (L 'Apparence') -Text (L 'Choisissez une palette. « Clair » est conçue pour les terminaux à fond blanc.')
                $theme = Read-PstThemeChoice
                if (-not $theme) { $back = $true } else { $state.Theme = $theme; Set-PstTheme $theme }
            }
            'Shell' {
                Show-PstWizardFrame -Steps $labels -Current $i -Caption $caption -Title (L 'Intégration au shell') -Text (L 'Ajoute une ligne à votre profil PowerShell pour charger une invite claire, des raccourcis (dont Alt+A : phrase vers commande), des commandes façon Unix, des favoris de dossiers et « fix ». Réversible avec « pst shell off ».')
                $choice = Read-PstShellChoice $state.Report
                if ($null -eq $choice) { $back = $true } else { $state.Shell = $choice }
            }
            'IA' {
                $choice = Invoke-PstAiSetup -Steps $labels -StepIndex $i -Caption $caption
                if ($choice -eq 'back') { $back = $true } else { $state.Ai = $choice }
            }
            'Résumé' {
                $root = $Roots[$state.Scope]
                $toolCount = @($state.Tools).Count
                if ($null -eq $state.Tools) { $toolCount = $optional.Count }
                Show-PstWizardFrame -Steps $labels -Current $i -Caption $caption -Title (L 'Récapitulatif') -Text (L 'Vérifiez vos choix. Rien n''a encore été modifié sur votre machine.')
                $lines = @(
                    ((Paint (Format-PstPad (L 'Langue') 12) 'Accent') + (Get-PstLanguageName $state.Language)),
                    ((Paint (Format-PstPad (L 'Dossier') 12) 'Accent') + $root),
                    ((Paint (Format-PstPad (L 'Outils') 12) 'Accent') + (L '{0} sur {1}' $toolCount $optional.Count)),
                    ((Paint (Format-PstPad (L 'Thème') 12) 'Accent') + (Get-PstThemeText $state.Theme).Label),
                    ((Paint (Format-PstPad (L 'Shell') 12) 'Accent') + (Format-PstShellSummary $state.Shell)),
                    ((Paint (Format-PstPad (L 'IA') 12) 'Accent') + (Format-PstAiSummary $state.Ai))
                )
                Format-PstBox -Lines $lines | Write-PstLine
                Write-Host ''
                $pick = Read-PstChoice -Title (L 'Lancer l''installation ?') -Items @((L 'Installer'), (L 'Modifier une étape'), (L 'Annuler'))
                if ($pick -eq 0) { return $state }
                if ($pick -eq 2) { return $null }
                if ($pick -lt 0) { $back = $true }
                else {
                    Write-Host ''
                    # Toutes les étapes sauf l'accueil et le récapitulatif.
                    $editable = @(for ($k = 0; $k -lt $steps.Count; $k++) { if ($steps[$k] -ne 'Bienvenue' -and $steps[$k] -ne 'Résumé') { $k } })
                    $target = Read-PstChoice -Title (L 'Quelle étape ?') -Items @($editable | ForEach-Object { $labels[$_] })
                    if ($target -ge 0) { $jump = $editable[$target] }
                }
            }
        }
        if ($null -ne $jump) { $i = $jump }
        elseif ($back) { $i = [Math]::Max(0, $i - 1) }
        else { $i++ }
    }
    return $state
}

function Invoke-PstApplyConfig {
    # Applique langue, thème, intégration au shell et assistant IA (après la copie des fichiers).
    param([hashtable]$State, [string]$AppRoot)
    $config = Get-PstConfig
    $config.theme = $State.Theme
    if ($State.Language) { $config.language = [string]$State.Language }
    Save-PstConfig $config
    if ($State.Language) { Write-PstStatus ok (L 'Langue : {0}' (Get-PstLanguageName $State.Language)) }
    Write-PstStatus ok (L 'Thème « {0} »' (Get-PstThemeText $State.Theme).Label)

    $shell = 'off'
    if ($State.Shell -and $State.Shell.Enabled) {
        Save-PstShellChoice $State.Shell
        $shell = Invoke-PstShellActivation -AppRoot $AppRoot -Remedy $State.Shell.Remedy -Interactive
    }
    if ($State.Ai -is [hashtable]) {
        Save-PstAiSetup $State.Ai
        Write-PstStatus ok (L 'Assistant IA : {0}' (Format-PstAiSummary $State.Ai))
    }
    return $shell
}

# ── « pst setup » : centre de configuration ──────────────────────────────────

function Invoke-PstSetupMenu {
    param([string]$AppRoot, [string]$Section)
    $g = $script:Pst.Glyph
    if (-not (Test-PstInteractive)) {
        Write-PstStatus err (L 'La configuration demande un terminal interactif.')
        Write-PstStatus info (L 'Sans terminal : variables ANTHROPIC_API_KEY, OPENAI_API_KEY... et PSTOOLS_THEME.')
        return
    }
    while ($true) {
        $config = Get-PstConfig
        $ai = Get-PstAiSettings
        $aiKey = Get-PstAiKey $ai.Provider
        $aiText = "$((Get-PstAiProvider $ai.Provider).Label) $($g.Dot) $($ai.Model)"
        if (-not $aiKey.Key -and (Get-PstAiProvider $ai.Provider).KeyRequired) { $aiText = Paint (L 'non configuré') 'Warn' }
        $shellText = Paint (L 'inactive') 'Dim'
        if (Test-PstShell) { $shellText = L 'active' }
        if ($config.shell.remedy -eq 'terminal') { $shellText = L 'active (profil Windows Terminal)' }
        $caption = L 'configuration'

        # 0 apparence, 1 shell, 2 IA, 3 test de l'IA, 4 langue, 5 tout, 6 quitter
        $pick = 0
        switch ($Section) {
            'theme' { $pick = 0 } 'shell' { $pick = 1 } 'ai' { $pick = 2 } 'all' { $pick = 5 }
            { $_ -in 'lang', 'language', 'langue' } { $pick = 4 }
            default {
                Show-PstWizardFrame -Title (L 'Configuration') -Text (L 'Choisissez ce que vous voulez régler. Chaque changement est enregistré immédiatement.') -Caption $caption
                $pick = Read-PstChoice -Items @((L 'Apparence'), (L 'Intégration au shell'), (L 'Assistant IA'), (L 'Tester l''assistant IA'), 'Langue / Language', (L 'Tout reconfigurer'), (L 'Quitter')) `
                    -Hints @((Get-PstThemeText $script:Pst.ThemeName).Label, $shellText, $aiText, (L 'petite requête de test'), (Get-PstLanguageName $script:Pst.Lang), (L 'assistant complet'), '')
            }
        }
        if ($pick -lt 0 -or $pick -eq 6) { return }
        $sequence = @($pick)
        if ($pick -eq 5) { $sequence = @(4, 0, 1, 2) }
        foreach ($s in $sequence) {
            # La langue a pu changer à l'étape précédente.
            $caption = L 'configuration'
            switch ($s) {
                0 {
                    Show-PstWizardFrame -Title (L 'Apparence') -Text (L 'La palette s''applique à tous les outils et à l''invite du shell.') -Caption $caption
                    $theme = Read-PstThemeChoice
                    if ($theme) {
                        $config = Get-PstConfig; $config.theme = $theme; Save-PstConfig $config; Set-PstTheme $theme
                        Write-Host ''; Write-PstStatus ok (L 'Thème « {0} » enregistré (l''invite change dans les nouveaux terminaux).' (Get-PstThemeText $theme).Label)
                    }
                }
                1 {
                    Show-PstWizardFrame -Title (L 'Intégration au shell') -Text (L 'Invite, raccourcis, commandes façon Unix, favoris et « fix ».') -Caption $caption
                    $report = Show-PstSpinner (L 'Vérification du profil PowerShell') { Get-PstEnvironmentReport }
                    $choice = Read-PstShellChoice $report
                    if ($choice) {
                        Write-Host ''
                        if ($choice.Enabled) {
                            Save-PstShellChoice $choice
                            $null = Invoke-PstShellActivation -AppRoot $AppRoot -Remedy $choice.Remedy -Interactive
                            Write-PstStatus info (L 'Effet dans les nouveaux terminaux.')
                        }
                        else {
                            foreach ($file in @(Disable-PstShell)) { Write-PstStatus ok (L 'Bloc retiré de : {0}' $file) }
                            Undo-PstShellRemedy
                            Write-PstStatus ok (L 'Intégration au shell désactivée.')
                        }
                    }
                }
                2 {
                    $choice = Invoke-PstAiSetup -Caption $caption
                    if ($choice -is [hashtable]) {
                        Save-PstAiSetup $choice
                        Write-Host ''
                        Write-PstStatus ok (L 'Assistant IA : {0}' (Format-PstAiSummary $choice))
                        if ((Read-PstConfirm (L 'Envoyer une question de test (coût inférieur à un centime) ?') -DefaultYes)) { $null = Test-PstAiSetup }
                    }
                }
                3 {
                    Show-PstWizardFrame -Title (L 'Test de l''assistant IA') -Caption $caption
                    $null = Test-PstAiSetup
                }
                4 {
                    Show-PstWizardFrame -Title 'Langue / Language' -Text 'Choisissez la langue de ps-tools. · Choose the ps-tools language.' -Caption $caption
                    $lang = Read-PstLanguageChoice
                    if ($lang) {
                        $config = Get-PstConfig; $config.language = $lang; Save-PstConfig $config
                        Switch-PstLanguage $lang -Names @('PsTools', 'PsTools.AI', 'PsTools.Wizard', 'pst')
                        Write-Host ''; Write-PstStatus ok (L 'Langue enregistrée : {0}.' (Get-PstLanguageName $lang))
                        if ($env:PSTOOLS_LANG -and $env:PSTOOLS_LANG -ne $lang) { Write-PstStatus warn (L 'La variable PSTOOLS_LANG ({0}) reste prioritaire.' $env:PSTOOLS_LANG) }
                    }
                }
            }
        }
        if ($Section) { Write-Host ''; return }
        Wait-PstKey
    }
}
