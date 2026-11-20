# ─────────────────────────────────────────────────────────────────────────────
#  ps-tools — moteur d'installation / désinstallation
#  Appelé par install.ps1 (amorce) ou par « pst-uninstall ».
# ─────────────────────────────────────────────────────────────────────────────
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'CurrentUser', 'AllUsers')][string]$Scope = 'Auto',
    [string[]]$Tools,
    [string]$Source,
    [string]$InstallRoot,
    [switch]$NoPath,
    [switch]$Yes,
    [switch]$Uninstall,
    [switch]$PurgeData,
    [switch]$Deferred,
    [switch]$Shell,
    [switch]$NoShell
)

$ErrorActionPreference = 'Stop'
# Lancé comme fichier (pst-uninstall), ce script a sa propre portée : il charge alors la
# bibliothèque lui-même. Lancé par l'amorce install.ps1, elle est déjà en place.
if (-not $script:Pst) { . (Join-Path (Join-Path $PSScriptRoot 'lib') 'PsTools.ps1') }
# Dictionnaires : dossier lib/ voisin (dépôt src/ ou app/ installé). Chargé en mémoire par
# l'amorce, $PSScriptRoot est vide : ils sont alors lus depuis la source (Import-SetupStrings).
$localLib = $null
if ($PSScriptRoot) { $localLib = Join-Path $PSScriptRoot 'lib' }
if ($localLib -and (Test-Path -LiteralPath (Join-Path $localLib 'PsTools.ps1'))) { $script:Pst.LibDir = $localLib }
else { $script:Pst.LibDir = '' }
$g = $script:Pst.Glyph
$isWindowsHost = $script:Pst.IsWindows
$isAdmin = Test-PstAdmin
$defaultSource = "https://raw.githubusercontent.com/$($script:Pst.Repo)/main"
if (-not $Source) { $Source = $defaultSource }
$sourceIsUrl = ($Source -match '^https?://')
$utf8Bom = New-Object System.Text.UTF8Encoding $true

# ── Emplacements ─────────────────────────────────────────────────────────────

function Get-ScopeRoot {
    param([string]$Name)
    if ($Name -eq 'AllUsers') { return (Join-Path $env:ProgramFiles 'ps-tools') }
    return (Join-Path $env:LOCALAPPDATA 'ps-tools')
}

function Get-InstallInfo {
    param([string]$Root)
    $file = Join-Path (Join-Path $Root 'app') 'install.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    try { return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ── Lecture des fichiers source (dépôt local ou GitHub) ──────────────────────

function Get-SourceText {
    param([string]$RelativePath)
    if ($sourceIsUrl) {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { $null = $_ }
        $client = New-Object System.Net.WebClient
        $client.Encoding = [System.Text.Encoding]::UTF8
        try { $text = $client.DownloadString("$($Source.TrimEnd('/'))/$RelativePath") }
        finally { $client.Dispose() }
    }
    else {
        $file = $Source
        foreach ($part in ($RelativePath -split '/')) { $file = Join-Path $file $part }
        $text = [IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
    }
    return $text.TrimStart([char]0xFEFF)
}

function Import-SetupStrings {
    # (Re)charge les dictionnaires de l'installation : depuis les fichiers quand ils sont
    # sur le disque, sinon depuis la source. Appelée au départ et après le choix de la langue.
    foreach ($name in 'PsTools', 'setup', 'PsTools.AI', 'PsTools.Wizard') {
        if ($script:Pst.LibDir) { Import-PstStrings $name; continue }
        if ($script:Pst.Lang -eq 'fr' -or $script:PstStringSets.ContainsKey($name)) { continue }
        try { Import-PstStrings $name -Text (Get-SourceText "src/i18n/en/$name.psd1") } catch { $null = $_ }   # dictionnaire absent : textes français
    }
}

function Write-ScriptFile {
    # UTF-8 avec BOM : indispensable pour que Windows PowerShell 5.1 lise les accents.
    param([string]$File, [string]$Text)
    $dir = Split-Path -Parent $File
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($File, $Text, $utf8Bom)
}

# ── Variable PATH (registre, sans dénaturer les entrées %VAR%) ───────────────

function Get-PathKey {
    param([string]$Target, [switch]$Writable)
    if ($Target -eq 'Machine') {
        return [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment', [bool]$Writable)
    }
    return [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', [bool]$Writable)
}

function Update-PathEntry {
    # Ajoute ou retire un dossier du PATH persistant. Retourne $true si modifié.
    param([string]$Dir, [ValidateSet('User', 'Machine')][string]$Target, [switch]$Remove)
    $key = Get-PathKey -Target $Target -Writable
    if ($null -eq $key) { return $false }
    try {
        $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $wanted = $Dir.TrimEnd('\')
        $entries = @($current -split ';' | Where-Object { $_ -and $_.Trim() })
        $kept = @($entries | Where-Object { $_.Trim().TrimEnd('\') -ine $wanted })
        $present = ($kept.Count -ne $entries.Count)
        if ($Remove) {
            if (-not $present) { return $false }
            $new = $kept -join ';'
        }
        else {
            if ($present) { return $false }
            $new = (@($entries) + $wanted) -join ';'
        }
        $key.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        return $true
    }
    finally { $key.Close() }
}

function Set-HomeVariable {
    # PSTOOLS_HOME sert de repère ; l'écrire via .NET notifie aussi Windows
    # du changement d'environnement (les nouveaux terminaux voient le PATH).
    param([string]$Value, [ValidateSet('User', 'Machine')][string]$Target)
    try { [Environment]::SetEnvironmentVariable('PSTOOLS_HOME', $Value, $Target) } catch { $null = $_ }
}

# ── Version 1 (ancienne installation) ────────────────────────────────────────

function Get-LegacyFiles {
    if (-not $isWindowsHost) { return @() }
    $dir = Join-Path (Join-Path $env:ProgramFiles 'WindowsPowerShell') 'Scripts'
    $found = @()
    foreach ($name in 'monitor', 'clean', 'ping-mon', 'remind') {
        foreach ($ext in 'ps1', 'cmd') {
            $file = Join-Path $dir "$name.$ext"
            if (Test-Path -LiteralPath $file) { $found += $file }
        }
    }
    return $found
}

function Remove-Legacy {
    $legacy = @(Get-LegacyFiles)
    if ($legacy.Count -gt 0) {
        if ($isAdmin) {
            foreach ($f in $legacy) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
            Write-PstStatus ok (L 'Ancienne version 1 supprimée ({0} fichiers)' $legacy.Count)
        }
        else {
            Write-PstStatus warn (L 'Une ancienne version 1 est installée pour tout le PC et reste prioritaire.')
            Write-PstStatus info (L 'Pour la retirer : relancez cette installation une fois depuis un terminal administrateur.')
        }
    }
    if ($env:USERPROFILE) {
        $oldCache = Join-Path $env:USERPROFILE '.ps-tools'
        if (Test-Path -LiteralPath $oldCache) { Remove-Item -LiteralPath $oldCache -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ── Élévation ────────────────────────────────────────────────────────────────

function Start-ElevatedSetup {
    param([string]$ExtraArguments)
    if ($sourceIsUrl) {
        $command = "`$env:PSTOOLS_SOURCE='$Source'; & ([scriptblock]::Create((New-Object Net.WebClient).DownloadString('$($Source.TrimEnd('/'))/install.ps1'))) $ExtraArguments"
    }
    else { $command = "& '$(Join-Path $Source 'install.ps1')' $ExtraArguments" }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', "`"$command`"") | Out-Null
        Write-PstStatus ok (L 'Suite dans la fenêtre administrateur qui vient de s''ouvrir.')
        return $true
    }
    catch {
        Write-PstStatus warn (L 'Élévation annulée : {0}' $_.Exception.Message)
        return $false
    }
}

# ═════════════════════════════════════════════════════════════════════════════
#  DÉSINSTALLATION
# ═════════════════════════════════════════════════════════════════════════════

function Remove-Installation {
    param([string]$Root, [string]$Target)
    $bin = Join-Path $Root 'bin'
    $app = Join-Path $Root 'app'
    if ($isWindowsHost -and $Target) {
        if (Update-PathEntry -Dir $bin -Target $Target -Remove) { Write-PstStatus ok (L 'PATH nettoyé ({0})' $Target) }
        Set-HomeVariable -Value $null -Target $Target
    }
    if ($Deferred -and $isWindowsHost) {
        # Lancé par « pst-uninstall » : les fichiers en cours d'exécution sont
        # supprimés par un processus détaché, une fois ce terminal rendu.
        # Le dernier « rd » (sans /s) ne retire le dossier racine que s'il est vide.
        $cmd = '/c ping -n 3 127.0.0.1 >nul & rd /s /q "{0}" & rd /s /q "{1}" & rd "{2}"' -f $bin, $app, $Root
        Start-Process -FilePath 'cmd.exe' -ArgumentList $cmd -WindowStyle Hidden | Out-Null
    }
    else {
        foreach ($dir in $bin, $app) {
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if ((Test-Path -LiteralPath $Root) -and @(Get-ChildItem -LiteralPath $Root -Force).Count -eq 0) { Remove-Item -LiteralPath $Root -Force -ErrorAction SilentlyContinue }
    }
    Write-PstStatus ok (L 'Fichiers supprimés : {0}' $Root)
}

function Invoke-Uninstall {
    Show-PstBanner -Tagline (L 'Désinstallation')

    $found = @()
    if ($InstallRoot) { $found += @{ Root = $InstallRoot; Target = $null; NeedsAdmin = $false; Label = (L 'emplacement personnalisé') } }
    elseif ($isWindowsHost) {
        $userRoot = Get-ScopeRoot 'CurrentUser'
        $machineRoot = Get-ScopeRoot 'AllUsers'
        if (Test-Path -LiteralPath (Join-Path $userRoot 'app')) { $found += @{ Root = $userRoot; Target = 'User'; NeedsAdmin = $false; Label = (L 'utilisateur courant') } }
        if (Test-Path -LiteralPath (Join-Path $machineRoot 'app')) { $found += @{ Root = $machineRoot; Target = 'Machine'; NeedsAdmin = $true; Label = (L 'tous les utilisateurs') } }
    }
    $legacy = @(Get-LegacyFiles)

    if ($found.Count -eq 0 -and $legacy.Count -eq 0) {
        Write-PstStatus info (L 'ps-tools n''est pas installé sur ce poste.')
        Write-Host ''
        return
    }

    foreach ($f in $found) { Write-PstStatus info (L 'Installation détectée ({0}) : {1}' $f.Label $f.Root) }
    if ($legacy.Count) { Write-PstStatus info (L 'Ancienne version 1 détectée ({0} fichiers)' $legacy.Count) }
    Write-Host ''
    if (-not $Yes -and -not (Read-PstConfirm (L 'Désinstaller ps-tools ?') -DefaultYes)) {
        Write-PstStatus info (L 'Annulé.')
        Write-Host ''
        return
    }

    $blocked = $false
    foreach ($f in $found) {
        if ($f.NeedsAdmin -and -not $isAdmin) { $blocked = $true; continue }
        Remove-Installation -Root $f.Root -Target $f.Target
    }
    if ($legacy.Count) {
        if ($isAdmin) { Remove-Legacy } else { $blocked = $true }
    }

    # Intégration au shell : bloc du profil, profil Windows Terminal, réglages de sécurité
    if (-not $InstallRoot) {
        foreach ($file in @(Disable-PstShell)) { Write-PstStatus ok (L 'Profil nettoyé : {0}' $file) }
        if ($isWindowsHost) { Undo-PstShellRemedy }
    }

    # Rappels planifiés et données personnelles (pas pour un emplacement personnalisé :
    # il ne doit pas toucher aux rappels de l'installation principale)
    if ($isWindowsHost -and -not $InstallRoot) {
        try {
            $tasks = @(Get-ScheduledTask -TaskName 'PsTools_Reminder_*' -ErrorAction Stop)
            foreach ($t in $tasks) { Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
            if ($tasks.Count) { Write-PstStatus ok (L '{0} rappel(s) planifié(s) annulé(s)' $tasks.Count) }
        }
        catch { $null = $_ }
    }
    $dataDir = $null
    if ($InstallRoot) { $dataDir = $null }
    elseif ($env:PSTOOLS_DATA) { $dataDir = $env:PSTOOLS_DATA }
    elseif ($isWindowsHost) { $dataDir = Join-Path (Get-ScopeRoot 'CurrentUser') 'data' }
    if ($dataDir -and (Test-Path -LiteralPath $dataDir)) {
        $purge = [bool]$PurgeData
        if (-not $purge -and -not $Yes) { $purge = Read-PstConfirm (L 'Supprimer aussi vos données (rappels, favoris, clés d''API, réglages, historique de consommation) ?') }
        if ($purge) {
            Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
            $parent = Split-Path -Parent $dataDir
            if ((Test-Path -LiteralPath $parent) -and @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) { Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue }
            Write-PstStatus ok (L 'Données personnelles supprimées')
        }
        else { Write-PstStatus info (L 'Données conservées : {0}' $dataDir) }
    }

    Write-Host ''
    if ($blocked) {
        Write-PstStatus warn (L 'L''installation commune à tous les utilisateurs demande les droits administrateur.')
        if (-not $Yes -and (Test-PstInteractive) -and (Read-PstConfirm (L 'Ouvrir une fenêtre administrateur pour terminer ?') -DefaultYes)) {
            $null = Start-ElevatedSetup -ExtraArguments '-Uninstall -Yes'
        }
        else { Write-PstStatus info (L 'Relancez la désinstallation depuis un terminal administrateur pour la retirer.') }
    }
    else {
        Format-PstBox -Title (L 'ps-tools est désinstallé') -Lines @((L 'Ouvrez un nouveau terminal pour actualiser le PATH.'), (Paint (L 'Merci de l''avoir utilisé !') 'Dim')) -Width 62 -Color 'Ok' | Write-PstLine
    }
    Write-Host ''
}

# ═════════════════════════════════════════════════════════════════════════════
#  INSTALLATION
# ═════════════════════════════════════════════════════════════════════════════

function Resolve-Scope {
    # Choisit le périmètre selon les droits disponibles. $null = abandon.
    if ($InstallRoot) { return 'CurrentUser' }
    $canAsk = (Test-PstInteractive) -and -not $Yes

    if ($Scope -eq 'Auto') {
        if (-not $isAdmin -or -not $canAsk) { return 'CurrentUser' }
        $choice = Read-PstChoice -Title (L 'Session administrateur détectée : pour qui installer ?') -Items @(
            (L 'Pour moi uniquement (recommandé)'), (L 'Pour tous les utilisateurs de ce PC')
        )
        Write-Host ''
        if ($choice -lt 0) { return $null }
        if ($choice -eq 1) { return 'AllUsers' }
        return 'CurrentUser'
    }

    if ($Scope -eq 'AllUsers' -and -not $isAdmin) {
        Write-PstStatus warn (L 'Installer pour tous les utilisateurs demande les droits administrateur.')
        if (-not $canAsk) {
            Write-PstStatus info (L 'Installation pour l''utilisateur courant à la place.')
            return 'CurrentUser'
        }
        $choice = Read-PstChoice -Title (L 'Comment continuer ?') -Items @(
            (L 'Relancer en administrateur (invite UAC)'), (L 'Installer pour moi uniquement, sans droits admin'), (L 'Annuler')
        )
        Write-Host ''
        if ($choice -eq 1) { return 'CurrentUser' }
        if ($choice -eq 0) { $null = Start-ElevatedSetup -ExtraArguments '-Scope AllUsers' }
        return $null
    }
    return $Scope
}

function Invoke-Install {
    if (-not $isWindowsHost -and -not $InstallRoot) {
        Show-PstBanner
        Write-PstStatus err (L 'ps-tools s''installe sur Windows. (Hors Windows : -InstallRoot <dossier> pour un essai.)')
        throw (L 'Plateforme non prise en charge')
    }

    # 1. Manifeste
    try { $manifest = Get-SourceText 'manifest.json' | ConvertFrom-Json }
    catch {
        Show-PstBanner
        Write-PstStatus err (L 'Impossible de lire le manifeste depuis {0} : {1}' $Source $_.Exception.Message)
        Write-PstStatus info (L 'Vérifiez votre connexion (ou un proxy d''entreprise) puis réessayez.')
        throw
    }
    $available = @($manifest.tools)
    $selected = $available

    # Assistant complet en session interactive ; installation directe avec -Yes, -Tools ou -InstallRoot.
    $wizard = $null
    $useWizard = (Test-PstInteractive) -and -not $Yes -and -not $InstallRoot -and -not $Tools -and $isWindowsHost -and -not $env:PSTOOLS_NO_WIZARD
    if ($useWizard) {
        $scopeDefault = 'CurrentUser'
        if ($Scope -eq 'AllUsers') { $scopeDefault = 'AllUsers' }
        $wizard = Invoke-PstInstallWizard -Manifest $manifest -IsAdmin $isAdmin -ScopeDefault $scopeDefault -Roots @{ CurrentUser = (Get-ScopeRoot 'CurrentUser'); AllUsers = (Get-ScopeRoot 'AllUsers') } -OnLanguage { Import-SetupStrings }
        if (-not $wizard) {
            Write-Host ''
            Write-PstStatus info (L 'Installation annulée : rien n''a été modifié.')
            Write-Host ''
            return
        }
        $resolved = $wizard.Scope
        if ($resolved -eq 'AllUsers' -and -not $isAdmin) { $resolved = 'CurrentUser' }
        $selected = @($available | Where-Object { $_.required -or $wizard.Tools -contains $_.name })
        Show-PstWizardFrame -Title (L 'Installation en cours') -Caption (L 'assistant d''installation')
    }
    else {
        Show-PstBanner
        $resolved = Resolve-Scope
        if (-not $resolved) { Write-PstStatus info (L 'Installation interrompue.'); Write-Host ''; return }
        if ($Tools) {
            $wanted = @($Tools | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() })
            $unknown = @($wanted | Where-Object { @($available | ForEach-Object { $_.name }) -notcontains $_ })
            if ($unknown.Count) { throw (L 'Outil(s) inconnu(s) : {0}. Disponibles : {1}' ($unknown -join ', ') (@($available | ForEach-Object { $_.name }) -join ', ')) }
            $selected = @($available | Where-Object { $_.required -or $wanted -contains $_.name })
        }
        Write-PstStatus step (L 'Source : {0}' $Source)
    }
    $target = 'User'
    if ($resolved -eq 'AllUsers') { $target = 'Machine' }
    if ($InstallRoot) { $root = $InstallRoot } else { $root = Get-ScopeRoot $resolved }
    $app = Join-Path $root 'app'
    $bin = Join-Path $root 'bin'

    $previous = Get-InstallInfo $root
    $label = L 'utilisateur courant, sans droits administrateur'
    if ($resolved -eq 'AllUsers') { $label = L 'tous les utilisateurs' }
    if ($InstallRoot) { $label = L 'emplacement personnalisé' }
    if ($previous -and $previous.Version) { Write-PstStatus step (L 'Mise à jour {0} {1} {2} ({3})' $previous.Version $g.Pointer $manifest.version $label) }
    else { Write-PstStatus step (L 'Installation de la version {0} ({1})' $manifest.version $label) }
    Write-PstStatus step (L 'Dossier : {0}' $root)
    Write-Host ''

    # 2. Fichiers
    try {
        foreach ($dir in $app, $bin) { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } }
        foreach ($c in @($manifest.core)) {
            $destination = $app
            foreach ($part in ($c.destination -split '/')) { $destination = Join-Path $destination $part }
            Write-ScriptFile -File $destination -Text (Get-SourceText $c.source)
        }
        [IO.File]::WriteAllText((Join-Path $app 'manifest.json'), (Get-SourceText 'manifest.json'), (New-Object System.Text.UTF8Encoding $false))
        # Dictionnaires anglais : toujours installés, pour pouvoir changer de langue à tout moment.
        $dictionaries = @('PsTools', 'PsTools.AI', 'PsTools.Wizard', 'setup') + @($selected | ForEach-Object { $_.name })
        foreach ($name in $dictionaries) {
            $text = $null
            try { $text = Get-SourceText "src/i18n/en/$name.psd1" } catch { $text = $null }
            if ($text) { Write-ScriptFile -File (Join-Path (Join-Path (Join-Path $app 'i18n') 'en') "$name.psd1") -Text $text }
        }
        Write-PstStatus ok (L 'Bibliothèque commune')

        $nameWidth = 0
        foreach ($t in $selected) { $nameWidth = [Math]::Max($nameWidth, $t.name.Length) }
        foreach ($t in $selected) {
            Write-ScriptFile -File (Join-Path (Join-Path $app 'tools') "$($t.name).ps1") -Text (Get-SourceText "src/tools/$($t.name).ps1")
            # Lanceur .cmd : fonctionne depuis cmd et PowerShell, quelle que soit la stratégie d'exécution.
            $shim = "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\app\tools\$($t.name).ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
            [IO.File]::WriteAllText((Join-Path $bin "$($t.name).cmd"), $shim, [System.Text.Encoding]::ASCII)
            Write-PstStatus ok ((Paint $t.name.PadRight($nameWidth) 'Title' -Bold) + (Paint "  $(Get-PstToolDescription $t)" 'Dim'))
        }

        # Retire les outils qui ne font plus partie de la sélection
        $keep = @($selected | ForEach-Object { $_.name })
        foreach ($old in @(Get-ChildItem -LiteralPath $bin -Filter '*.cmd' -ErrorAction SilentlyContinue)) {
            if ($keep -notcontains $old.BaseName) {
                Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath (Join-Path (Join-Path $app 'tools') "$($old.BaseName).ps1") -Force -ErrorAction SilentlyContinue
            }
        }

        $info = [ordered]@{
            Version = [string]$manifest.version; Scope = $resolved; Root = $root; Source = $Source
            InstalledAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Tools = $keep
            Selection = $(if ($Tools -or ($wizard -and $selected.Count -lt $available.Count)) { 'custom' } else { 'all' })
        }
        [IO.File]::WriteAllText((Join-Path $app 'install.json'), ($info | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
    }
    catch [UnauthorizedAccessException] {
        Write-PstStatus err (L 'Écriture refusée dans {0}.' $root)
        Write-PstStatus info (L 'Relancez sans -Scope AllUsers pour une installation sans droits administrateur.')
        throw
    }
    Write-Host ''

    # 3. PATH
    $pathReady = $false
    if ($NoPath -or -not $isWindowsHost) { Write-PstStatus info (L 'PATH non modifié {0} lanceurs dans {1}' $g.Dot $bin) }
    else {
        try {
            if (Update-PathEntry -Dir $bin -Target $target) { Write-PstStatus ok (L 'Commandes ajoutées au PATH ({0})' $target) }
            else { Write-PstStatus ok (L 'PATH déjà configuré ({0})' $target) }
            Set-HomeVariable -Value $root -Target $target
            if (@($env:PATH -split ';') -notcontains $bin) { $env:PATH = "$env:PATH;$bin" }
            $pathReady = $true
        }
        catch { Write-PstStatus warn (L 'PATH non modifié : {0} {1} ajoutez {2} manuellement.' $_.Exception.Message $g.Dot $bin) }
    }

    # 4. Ancienne version et conflits de priorité
    Remove-Legacy
    if ($isWindowsHost -and -not $InstallRoot -and $resolved -eq 'CurrentUser') {
        $machineRoot = Get-ScopeRoot 'AllUsers'
        if (Test-Path -LiteralPath (Join-Path $machineRoot 'app')) {
            Write-PstStatus warn (L 'Une installation « tous les utilisateurs » existe aussi ({0}) et reste prioritaire dans le PATH.' $machineRoot)
        }
    }

    # 5. Configuration : thème, intégration au shell, assistant IA
    $shellActive = $false
    if ($wizard) {
        Write-Host ''
        $shellState = Invoke-PstApplyConfig -State $wizard -AppRoot $app
        $shellActive = ($shellState -eq 'active' -or $shellState -eq 'terminal')
    }
    elseif (-not $InstallRoot -and -not $NoShell) {
        # Intégration au shell : modifie le profil de l'utilisateur, uniquement avec son accord.
        $shellActive = Test-PstShell
        $wanted = [bool]$Shell
        $interactive = (-not $Yes) -and (Test-PstInteractive)
        if (-not $shellActive -and -not $wanted -and $interactive) {
            Write-Host ''
            Write-Host (L '  L''intégration au shell ajoute une invite claire (dossier, branche Git, durée), un historique')
            Write-Host (L '  plus malin, des raccourcis (Alt+A : IA) et des commandes façon Unix (ll, grep, sudo, jump...).')
            $wanted = Read-PstConfirm (L 'L''activer ? (une ligne ajoutée à votre profil PowerShell, réversible avec « pst shell off »)') -DefaultYes
        }
        if ($shellActive -or $wanted) {
            Write-Host ''
            $remedy = ''
            if ((Get-PstConfig).shell.remedy -eq 'terminal') { $remedy = 'terminal' }
            try {
                # Le profil n'est modifié que s'il peut réellement se charger : jamais d'erreur au démarrage.
                $shellState = Invoke-PstShellActivation -AppRoot $app -Remedy $remedy -Interactive:$interactive
                $shellActive = ($shellState -ne 'blocked')
            }
            catch { Write-PstStatus warn (L 'Profil non modifié : {0}' $_.Exception.Message) }
        }
    }

    # 6. Bilan
    Write-Host ''
    $names = @($selected | Where-Object { $_.name -notlike 'pst*' } | ForEach-Object { $_.name })
    $half = [int][Math]::Ceiling($names.Count / 2)
    $summary = @(((Paint (Format-PstPad (L 'Commandes') 11) 'Accent' -Bold) + (@($names | Select-Object -First $half) -join '  ')))
    if ($names.Count -gt $half) { $summary += ('           ' + (@($names | Select-Object -Skip $half) -join '  ')) }
    $summary += @(
        ((Paint (Format-PstPad (L 'Gestion') 11) 'Accent' -Bold) + 'pst' + (Paint (L '  (menu, diagnostic, mise à jour)') 'Dim')),
        ((Paint (Format-PstPad (L 'Réglages') 11) 'Accent' -Bold) + 'pst setup' + (Paint (L '  (apparence, shell, assistant IA)') 'Dim')),
        ((Paint (Format-PstPad (L 'Retrait') 11) 'Accent' -Bold) + 'pst-uninstall'),
        ((Paint (Format-PstPad (L 'Aide') 11) 'Accent' -Bold) + (L '<commande> -Help') + (Paint (L '  ·  pst keys pour les raccourcis') 'Dim'))
    )
    if (-not $shellActive -and -not $InstallRoot) { $summary += ((Paint (Format-PstPad (L 'Shell') 11) 'Accent' -Bold) + 'pst shell on' + (Paint (L '  (invite, raccourcis, alias)') 'Dim')) }
    if ($pathReady) { $summary += ''; $summary += Paint (L 'Disponible tout de suite ici, et dans tout nouveau terminal.') 'Dim' }
    Format-PstBox -Title (L 'ps-tools {0} est installé' $manifest.version) -Lines $summary -Color 'Ok' | Write-PstLine
    Write-Host ''
    $first = (Paint 'pst' 'Ok' -Bold) + (Paint (L '   ou   ') 'Dim') + (Paint 'sysinfo' 'Ok' -Bold)
    if ($wizard -and $wizard.Ai -is [hashtable]) { $first += (Paint (L '   ou   ') 'Dim') + (Paint (L 'ask "bonjour"') 'Ok' -Bold) }
    Write-Host ((L '  Pour commencer :  ') + $first)
    if ($shellActive) { Write-Host (Paint (L '  Ouvrez un nouveau terminal pour profiter de l''intégration au shell.') 'Dim') }
    Write-Host ''
}

# Bibliothèques de l'assistant (IA, configuration) : depuis le dossier voisin quand il
# existe (dépôt ou installation), sinon depuis la source (amorce lancée depuis le web).
foreach ($library in 'PsTools.AI.ps1', 'PsTools.Wizard.ps1') {
    $local = $null
    if ($PSScriptRoot) { $local = Join-Path (Join-Path $PSScriptRoot 'lib') $library }
    if ($local -and (Test-Path -LiteralPath $local)) { . $local }
    else { . ([scriptblock]::Create((Get-SourceText "src/lib/$library"))) }
}
Import-SetupStrings

if ($Uninstall) { Invoke-Uninstall } else { Invoke-Install }
