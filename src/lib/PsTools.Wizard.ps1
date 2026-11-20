# ─────────────────────────────────────────────────────────────────────────────
#  ps-tools — assistant de configuration (installation et « pst setup »)
#  Chargée après PsTools.ps1 et PsTools.AI.ps1.
# ─────────────────────────────────────────────────────────────────────────────

function Get-PstEnvironmentReport {
    # État de la machine, affiché en ouverture de l'assistant.
    $report = @{ Os = 'Windows'; Shell = "PowerShell $($PSVersionTable.PSVersion)"; Admin = (Test-PstAdmin); Terminal = 'Console Windows'; Profiles = @() }
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
    $rights = 'utilisateur standard'
    if ($Report.Admin) { $rights = 'administrateur' }
    $lines = @(
        ((Paint (Format-PstPad 'Système' 12) 'Accent') + $Report.Os),
        ((Paint (Format-PstPad 'Shell' 12) 'Accent') + $Report.Shell),
        ((Paint (Format-PstPad 'Session' 12) 'Accent') + $rights),
        ((Paint (Format-PstPad 'Terminal' 12) 'Accent') + $Report.Terminal)
    )
    foreach ($p in $Report.Profiles) {
        $where = 'local'
        if ($p.IsNetwork) { $where = "partage réseau $($p.Server)" }
        $state = Paint "$($g.Ok) chargeable" 'Ok'
        if (-not $p.Loadable) { $state = Paint "$($g.Warn) chargement bloqué" 'Warn' }
        $name = 'Profil 5.1'
        if ($p.Path -notmatch 'WindowsPowerShell') { $name = 'Profil 7' }
        $lines += (Paint (Format-PstPad $name 12) 'Accent') + $where + '  ' + $state
    }
    Format-PstBox -Title 'Votre environnement' -Lines $lines | Write-PstLine
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
        $list += @{ Id = 'trust'; Label = "Faire confiance au partage $server (recommandé)"; Hint = 'zone Intranet locale, pour votre compte uniquement'; Server = $server }
    }
    $list += @{ Id = 'bypass'; Label = 'Autoriser les scripts non signés pour votre compte'; Hint = 'stratégie Bypass, portée CurrentUser' }
    if (Test-PstWindowsTerminal) {
        $list += @{ Id = 'terminal'; Label = 'Utiliser un profil Windows Terminal « ps-tools »'; Hint = 'ne touche ni au partage ni à la stratégie' }
    }
    $list += @{ Id = 'none'; Label = 'Ne pas activer l''intégration'; Hint = 'les commandes restent disponibles' }
    return $list
}

function Show-PstBlockedProfileHelp {
    param($Blocked)
    $first = $Blocked | Select-Object -First 1
    $location = Get-PstProfileLocation $first
    $lines = @()
    if ($location.IsNetwork) {
        $lines += "Votre profil PowerShell se trouve sur un partage réseau :"
        $lines += Paint (Limit-PstText $first 76) 'Title'
        $lines += ''
        $lines += 'Windows considère les scripts de ce partage comme venant d''Internet : la'
        $lines += 'stratégie d''exécution exige alors une signature numérique, et le profil est'
        $lines += 'refusé à chaque ouverture du terminal (« n''est pas signé numériquement »).'
    }
    else {
        $lines += 'La stratégie d''exécution de PowerShell empêche de charger votre profil :'
        $lines += Paint (Limit-PstText $first 76) 'Title'
    }
    Format-PstBox -Title 'Profil PowerShell bloqué' -Lines $lines -Color 'Warn' | Write-PstLine
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
            Write-PstStatus ok "Partage $($Remedy.Server) classé en zone Intranet locale (votre compte)"
        }
        'bypass' {
            if (-not $config.shell.previousPolicy) {
                try { $config.shell.previousPolicy = [string](Get-ExecutionPolicy -Scope CurrentUser) } catch { $config.shell.previousPolicy = 'Undefined' }
            }
            Set-PstUserPolicy 'Bypass'
            Write-PstStatus ok 'Stratégie d''exécution de votre compte réglée sur Bypass'
        }
    }
    $config.shell.remedy = $Remedy.Id
    Save-PstConfig $config
}

function Undo-PstShellRemedy {
    # Annule les changements de sécurité faits pour l'intégration au shell.
    $config = Get-PstConfig
    if ($config.shell.trustedHost) {
        try { Revoke-PstShareTrust $config.shell.trustedHost; Write-PstStatus ok "Partage $($config.shell.trustedHost) retiré de la zone Intranet" } catch { $null = $_ }
    }
    if ($config.shell.previousPolicy) {
        try { Set-PstUserPolicy $config.shell.previousPolicy; Write-PstStatus ok "Stratégie d'exécution rétablie ($($config.shell.previousPolicy))" } catch { $null = $_ }
    }
    if (Remove-PstTerminalProfile) { Write-PstStatus ok 'Profil Windows Terminal « ps-tools » retiré' }
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
        Write-PstStatus ok 'Profil Windows Terminal « PowerShell · ps-tools » ajouté'
        return 'terminal'
    }

    $result = Enable-PstShell -AppRoot $AppRoot
    foreach ($file in $result.Written) { Write-PstStatus ok "Profil mis à jour : $file" }
    if ($result.Blocked.Count -eq 0) { return 'active' }

    $tried = @()
    if ($Remedy -and $Remedy -ne 'none') {
        $choice = @(Get-PstShellRemedies $result.Blocked | Where-Object { $_.Id -eq $Remedy }) | Select-Object -First 1
        if ($choice) {
            Invoke-PstShellRemedy $choice
            $tried += $Remedy
            $result = Enable-PstShell -AppRoot $AppRoot
            foreach ($file in $result.Written) { Write-PstStatus ok "Profil mis à jour : $file" }
            if ($result.Blocked.Count -eq 0) { return 'active' }
            Write-PstStatus warn 'Le profil reste bloqué malgré ce réglage (sans doute imposé par une stratégie de groupe).'
        }
    }

    while ($Interactive -and (Test-PstInteractive)) {
        Write-Host ''
        Show-PstBlockedProfileHelp $result.Blocked
        $options = @(Get-PstShellRemedies $result.Blocked | Where-Object { $tried -notcontains $_.Id })
        $pick = Read-PstChoice -Title 'Comment voulez-vous continuer ?' -Items @($options | ForEach-Object { $_.Label }) -Hints @($options | ForEach-Object { $_.Hint })
        Write-Host ''
        if ($pick -lt 0 -or $options[$pick].Id -eq 'none') { break }
        $option = $options[$pick]
        if ($option.Id -eq 'terminal') { return (Invoke-PstShellActivation -AppRoot $AppRoot -Remedy 'terminal') }
        try { Invoke-PstShellRemedy $option } catch { Write-PstStatus err "Réglage impossible : $($_.Exception.Message)" }
        $tried += $option.Id
        $result = Enable-PstShell -AppRoot $AppRoot
        foreach ($file in $result.Written) { Write-PstStatus ok "Profil mis à jour : $file" }
        if ($result.Blocked.Count -eq 0) { return 'active' }
        Write-PstStatus warn 'Le profil reste bloqué malgré ce réglage (sans doute imposé par une stratégie de groupe).'
    }

    foreach ($file in $result.Blocked) { Write-PstStatus warn "Profil non modifié (chargement bloqué) : $file" }
    Write-PstStatus info 'Aucune erreur ne s''affichera au démarrage. Pour réessayer : pst shell on'
    return 'blocked'
}

# ── Étapes ───────────────────────────────────────────────────────────────────

function Read-PstThemeChoice {
    $g = $script:Pst.Glyph
    $names = @($script:PstThemes.Keys)
    $labels = @(); $hints = @()
    foreach ($n in $names) {
        $t = $script:PstThemes[$n]
        $labels += $t.Label
        $swatch = ''
        if ($script:Pst.Ansi) {
            foreach ($role in 'Accent', 'Accent2', 'Ok', 'Warn', 'Err') { $swatch += Paint ($g.Full * 2) $t[$role] }
            $swatch += '  ' + (Paint $t.Hint $t.Dim)
        }
        else { $swatch = $t.Hint }
        $hints += $swatch
    }
    $current = [Math]::Max(0, [array]::IndexOf($names, $script:Pst.ThemeName))
    $pick = Read-PstChoice -Title 'Quel thème de couleurs ?' -Items $labels -Hints $hints -Default $current
    if ($pick -lt 0) { return $null }
    return $names[$pick]
}

function Read-PstShellChoice {
    # Retourne @{ Enabled; Prompt; Keys; Aliases; Remedy } ou $null (retour).
    param($Report)
    $config = Get-PstConfig
    $pick = Read-PstChoice -Title 'Activer l''intégration au shell ?' -Items @('Oui, l''activer', 'Non, pas maintenant') -Hints @('recommandé', 'activable plus tard : pst shell on')
    if ($pick -lt 0) { return $null }
    if ($pick -eq 1) { return @{ Enabled = $false } }
    Write-Host ''
    $items = @('Invite enrichie : dossier, branche Git, durée, erreurs', 'Raccourcis : Alt+A (IA), Alt+S (sudo), Alt+C, Alt+G', 'Commandes façon Unix : ll, grep, touch, sudo, which...')
    $selected = @([bool]$config.shell.prompt, [bool]$config.shell.keys, [bool]$config.shell.aliases)
    $parts = Read-PstMultiChoice -Title 'Que voulez-vous activer ? (favoris « jump » et « fix » toujours inclus)' -Items $items -Selected $selected
    if ($null -eq $parts) { return $null }
    $choice = @{ Enabled = $true; Prompt = ($parts -contains 0); Keys = ($parts -contains 1); Aliases = ($parts -contains 2); Remedy = '' }

    $blocked = @($Report.Profiles | Where-Object { -not $_.Loadable } | ForEach-Object { $_.Path })
    if ($blocked.Count) {
        Write-Host ''
        Show-PstBlockedProfileHelp $blocked
        $options = @(Get-PstShellRemedies $blocked)
        $r = Read-PstChoice -Title 'Comment charger l''intégration ?' -Items @($options | ForEach-Object { $_.Label }) -Hints @($options | ForEach-Object { $_.Hint })
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
    if ($Choice -isnot [hashtable]) { return (Paint 'à configurer plus tard (pst setup)' 'Dim') }
    $p = Get-PstAiProvider $Choice.Provider
    $text = "$($p.Label) $($script:Pst.Glyph.Dot) $($Choice.Model)"
    if ($Choice.Budget -gt 0) { $text += " $($script:Pst.Glyph.Dot) budget $(Format-PstMoney $Choice.Budget)/mois" }
    return $text
}

function Format-PstShellSummary {
    param($Choice)
    if (-not $Choice -or -not $Choice.Enabled) { return (Paint 'non activée' 'Dim') }
    $parts = @()
    if ($Choice.Prompt) { $parts += 'invite' }
    if ($Choice.Keys) { $parts += 'raccourcis' }
    if ($Choice.Aliases) { $parts += 'commandes Unix' }
    $parts += 'favoris'
    $text = 'activée : ' + ($parts -join ', ')
    switch ($Choice.Remedy) {
        'trust' { $text += ' (partage réseau approuvé)' }
        'bypass' { $text += ' (stratégie Bypass)' }
        'terminal' { $text += ' (profil Windows Terminal)' }
    }
    return $text
}

# ── Assistant d'installation ─────────────────────────────────────────────────

function Invoke-PstInstallWizard {
    # Recueille tous les choix, étape par étape, avec retour arrière (Échap) et
    # récapitulatif. N'installe rien : retourne l'état, ou $null si annulé.
    param($Manifest, [bool]$IsAdmin, [hashtable]$Roots, [string]$ScopeDefault = 'CurrentUser')
    $g = $script:Pst.Glyph
    $state = @{ Scope = $ScopeDefault; Tools = $null; Theme = $script:Pst.ThemeName; Shell = $null; Ai = $null; Report = $null }
    $steps = @('Bienvenue')
    if ($IsAdmin) { $steps += 'Portée' }
    $steps += @('Outils', 'Apparence', 'Shell', 'IA', 'Résumé')
    $optional = @($Manifest.tools | Where-Object { -not $_.required })

    $i = 0
    while ($i -lt $steps.Count) {
        $name = $steps[$i]
        $back = $false
        switch ($name) {
            'Bienvenue' {
                Show-PstWizardFrame -Steps $steps -Current $i -Title "Bienvenue dans ps-tools $($Manifest.version)" -Text 'Cet assistant installe les commandes, puis configure l''apparence, l''intégration au shell et l''assistant IA. Tout se modifie ensuite avec « pst setup ». Échap revient à l''étape précédente.'
                Get-PstBanner | Select-Object -Skip 1 | Write-PstLine
                Write-Host ''
                if (-not $state.Report) { $state.Report = Show-PstSpinner 'Analyse de votre environnement' { Get-PstEnvironmentReport } }
                Show-PstEnvironment $state.Report
                Write-Host ''
                $pick = Read-PstChoice -Title 'Prêt ?' -Items @('Commencer', 'Quitter')
                if ($pick -ne 0) { return $null }
            }
            'Portée' {
                Show-PstWizardFrame -Steps $steps -Current $i -Title 'Pour qui installer ?' -Text 'Votre session a les droits administrateur : ps-tools peut être installé pour tous les utilisateurs de ce PC. Une installation pour vous seul reste le choix le plus simple.'
                $pick = Read-PstChoice -Items @('Pour moi uniquement', 'Pour tous les utilisateurs') -Hints @("recommandé $($g.Dot) %LOCALAPPDATA%\ps-tools", '%ProgramFiles%\ps-tools') -Default ([int]($state.Scope -eq 'AllUsers'))
                if ($pick -lt 0) { $back = $true } elseif ($pick -eq 1) { $state.Scope = 'AllUsers' } else { $state.Scope = 'CurrentUser' }
            }
            'Outils' {
                Show-PstWizardFrame -Steps $steps -Current $i -Title 'Quels outils installer ?' -Text 'Tous sont cochés. Espace pour décocher, A pour tout inverser. « pst » et « pst-uninstall » sont toujours installés.'
                $width = 0
                foreach ($t in $optional) { $width = [Math]::Max($width, $t.name.Length) }
                $items = @($optional | ForEach-Object { '{0}  {1}' -f $_.name.PadRight($width), $_.description })
                $selected = New-Object 'bool[]' $optional.Count
                for ($k = 0; $k -lt $optional.Count; $k++) { $selected[$k] = ($null -eq $state.Tools) -or ($state.Tools -contains $optional[$k].name) }
                $picked = Read-PstMultiChoice -Items $items -Selected $selected
                if ($null -eq $picked) { $back = $true }
                else { $state.Tools = @($picked | ForEach-Object { $optional[$_].name }) }
            }
            'Apparence' {
                Show-PstWizardFrame -Steps $steps -Current $i -Title 'Apparence' -Text 'Choisissez une palette. « Clair » est conçue pour les terminaux à fond blanc.'
                $theme = Read-PstThemeChoice
                if (-not $theme) { $back = $true } else { $state.Theme = $theme; Set-PstTheme $theme }
            }
            'Shell' {
                Show-PstWizardFrame -Steps $steps -Current $i -Title 'Intégration au shell' -Text 'Ajoute une ligne à votre profil PowerShell pour charger une invite claire, des raccourcis (dont Alt+A : phrase vers commande), des commandes façon Unix, des favoris de dossiers et « fix ». Réversible avec « pst shell off ».'
                $choice = Read-PstShellChoice $state.Report
                if ($null -eq $choice) { $back = $true } else { $state.Shell = $choice }
            }
            'IA' {
                $choice = Invoke-PstAiSetup -Steps $steps -StepIndex $i -Caption 'assistant d''installation'
                if ($choice -eq 'back') { $back = $true } else { $state.Ai = $choice }
            }
            'Résumé' {
                $root = $Roots[$state.Scope]
                $toolCount = @($state.Tools).Count
                if ($null -eq $state.Tools) { $toolCount = $optional.Count }
                Show-PstWizardFrame -Steps $steps -Current $i -Title 'Récapitulatif' -Text 'Vérifiez vos choix. Rien n''a encore été modifié sur votre machine.'
                $lines = @(
                    ((Paint (Format-PstPad 'Dossier' 12) 'Accent') + $root),
                    ((Paint (Format-PstPad 'Outils' 12) 'Accent') + "$toolCount sur $($optional.Count)"),
                    ((Paint (Format-PstPad 'Thème' 12) 'Accent') + $script:PstThemes[$state.Theme].Label),
                    ((Paint (Format-PstPad 'Shell' 12) 'Accent') + (Format-PstShellSummary $state.Shell)),
                    ((Paint (Format-PstPad 'IA' 12) 'Accent') + (Format-PstAiSummary $state.Ai))
                )
                Format-PstBox -Lines $lines | Write-PstLine
                Write-Host ''
                $pick = Read-PstChoice -Title 'Lancer l''installation ?' -Items @('Installer', 'Modifier une étape', 'Annuler')
                if ($pick -eq 0) { return $state }
                if ($pick -eq 2) { return $null }
                if ($pick -lt 0) { $back = $true }
                else {
                    Write-Host ''
                    $editable = @($steps[1..($steps.Count - 2)])
                    $target = Read-PstChoice -Title 'Quelle étape ?' -Items $editable
                    if ($target -ge 0) { $i = $target + 1; continue }
                }
            }
        }
        if ($back) { $i = [Math]::Max(0, $i - 1) } else { $i++ }
    }
    return $state
}

function Invoke-PstApplyConfig {
    # Applique thème, intégration au shell et assistant IA (après la copie des fichiers).
    param([hashtable]$State, [string]$AppRoot)
    $config = Get-PstConfig
    $config.theme = $State.Theme
    Save-PstConfig $config
    Write-PstStatus ok "Thème « $($script:PstThemes[$State.Theme].Label) »"

    $shell = 'off'
    if ($State.Shell -and $State.Shell.Enabled) {
        Save-PstShellChoice $State.Shell
        $shell = Invoke-PstShellActivation -AppRoot $AppRoot -Remedy $State.Shell.Remedy -Interactive
    }
    if ($State.Ai -is [hashtable]) {
        Save-PstAiSetup $State.Ai
        Write-PstStatus ok "Assistant IA : $(Format-PstAiSummary $State.Ai)"
    }
    return $shell
}

# ── « pst setup » : centre de configuration ──────────────────────────────────

function Invoke-PstSetupMenu {
    param([string]$AppRoot, [string]$Section)
    $g = $script:Pst.Glyph
    if (-not (Test-PstInteractive)) {
        Write-PstStatus err 'La configuration demande un terminal interactif.'
        Write-PstStatus info 'Sans terminal : variables ANTHROPIC_API_KEY, OPENAI_API_KEY... et PSTOOLS_THEME.'
        return
    }
    while ($true) {
        $config = Get-PstConfig
        $ai = Get-PstAiSettings
        $aiKey = Get-PstAiKey $ai.Provider
        $aiText = "$((Get-PstAiProvider $ai.Provider).Label) $($g.Dot) $($ai.Model)"
        if (-not $aiKey.Key -and (Get-PstAiProvider $ai.Provider).KeyRequired) { $aiText = Paint 'non configuré' 'Warn' }
        $shellText = Paint 'inactive' 'Dim'
        if (Test-PstShell) { $shellText = 'active' }
        if ($config.shell.remedy -eq 'terminal') { $shellText = 'active (profil Windows Terminal)' }

        $pick = 0
        switch ($Section) {
            'theme' { $pick = 0 } 'shell' { $pick = 1 } 'ai' { $pick = 2 } 'all' { $pick = 4 }
            default {
                Show-PstWizardFrame -Title 'Configuration' -Text 'Choisissez ce que vous voulez régler. Chaque changement est enregistré immédiatement.' -Caption 'configuration'
                $pick = Read-PstChoice -Items @('Apparence', 'Intégration au shell', 'Assistant IA', 'Tester l''assistant IA', 'Tout reconfigurer', 'Quitter') `
                    -Hints @($script:PstThemes[$script:Pst.ThemeName].Label, $shellText, $aiText, 'petite requête de test', 'assistant complet', '')
            }
        }
        if ($pick -lt 0 -or $pick -eq 5) { return }
        $sequence = @($pick)
        if ($pick -eq 4) { $sequence = @(0, 1, 2) }
        foreach ($s in $sequence) {
            switch ($s) {
                0 {
                    Show-PstWizardFrame -Title 'Apparence' -Text 'La palette s''applique à tous les outils et à l''invite du shell.' -Caption 'configuration'
                    $theme = Read-PstThemeChoice
                    if ($theme) {
                        $config = Get-PstConfig; $config.theme = $theme; Save-PstConfig $config; Set-PstTheme $theme
                        Write-Host ''; Write-PstStatus ok "Thème « $($script:PstThemes[$theme].Label) » enregistré (l'invite change dans les nouveaux terminaux)."
                    }
                }
                1 {
                    Show-PstWizardFrame -Title 'Intégration au shell' -Text 'Invite, raccourcis, commandes façon Unix, favoris et « fix ».' -Caption 'configuration'
                    $report = Show-PstSpinner 'Vérification du profil PowerShell' { Get-PstEnvironmentReport }
                    $choice = Read-PstShellChoice $report
                    if ($choice) {
                        Write-Host ''
                        if ($choice.Enabled) {
                            Save-PstShellChoice $choice
                            $null = Invoke-PstShellActivation -AppRoot $AppRoot -Remedy $choice.Remedy -Interactive
                            Write-PstStatus info 'Effet dans les nouveaux terminaux.'
                        }
                        else {
                            foreach ($file in @(Disable-PstShell)) { Write-PstStatus ok "Bloc retiré de : $file" }
                            Undo-PstShellRemedy
                            Write-PstStatus ok 'Intégration au shell désactivée.'
                        }
                    }
                }
                2 {
                    $choice = Invoke-PstAiSetup -Caption 'configuration'
                    if ($choice -is [hashtable]) {
                        Save-PstAiSetup $choice
                        Write-Host ''
                        Write-PstStatus ok "Assistant IA : $(Format-PstAiSummary $choice)"
                        if ((Read-PstConfirm 'Envoyer une question de test (coût inférieur à un centime) ?' -DefaultYes)) { $null = Test-PstAiSetup }
                    }
                }
                3 {
                    Show-PstWizardFrame -Title 'Test de l''assistant IA' -Caption 'configuration'
                    $null = Test-PstAiSetup
                }
            }
        }
        if ($Section) { Write-Host ''; return }
        Wait-PstKey
    }
}
