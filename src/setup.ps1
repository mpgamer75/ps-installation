# ─────────────────────────────────────────────────────────────────────────────
#  ps-tools — moteur d'installation / désinstallation
#  Appelé par install.ps1 (amorce) ou par « pst update / pst uninstall ».
#  Suppose que la bibliothèque PsTools.ps1 est déjà chargée.
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
            Write-PstStatus ok "Ancienne version 1 supprimée ($($legacy.Count) fichiers)"
        }
        else {
            Write-PstStatus warn 'Une ancienne version 1 est installée pour tout le PC et reste prioritaire.'
            Write-PstStatus info 'Pour la retirer : relancez cette installation une fois depuis un terminal administrateur.'
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
        Write-PstStatus ok 'Suite dans la fenêtre administrateur qui vient de s''ouvrir.'
        return $true
    }
    catch {
        Write-PstStatus warn "Élévation annulée : $($_.Exception.Message)"
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
        if (Update-PathEntry -Dir $bin -Target $Target -Remove) { Write-PstStatus ok "PATH nettoyé ($Target)" }
        Set-HomeVariable -Value $null -Target $Target
    }
    if ($Deferred -and $isWindowsHost) {
        # Lancé par « pst uninstall » : les fichiers en cours d'exécution sont
        # supprimés par un processus détaché, une fois ce terminal rendu.
        $cmd = '/c ping -n 3 127.0.0.1 >nul & rd /s /q "{0}" & rd /s /q "{1}"' -f $bin, $app
        Start-Process -FilePath 'cmd.exe' -ArgumentList $cmd -WindowStyle Hidden | Out-Null
    }
    else {
        foreach ($dir in $bin, $app) {
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if ((Test-Path -LiteralPath $Root) -and @(Get-ChildItem -LiteralPath $Root -Force).Count -eq 0) { Remove-Item -LiteralPath $Root -Force -ErrorAction SilentlyContinue }
    }
    Write-PstStatus ok "Fichiers supprimés : $Root"
}

function Invoke-Uninstall {
    Show-PstBanner -Tagline 'Désinstallation'

    $found = @()
    if ($InstallRoot) { $found += @{ Root = $InstallRoot; Target = $null; NeedsAdmin = $false; Label = 'emplacement personnalisé' } }
    elseif ($isWindowsHost) {
        $userRoot = Get-ScopeRoot 'CurrentUser'
        $machineRoot = Get-ScopeRoot 'AllUsers'
        if (Test-Path -LiteralPath (Join-Path $userRoot 'app')) { $found += @{ Root = $userRoot; Target = 'User'; NeedsAdmin = $false; Label = 'utilisateur courant' } }
        if (Test-Path -LiteralPath (Join-Path $machineRoot 'app')) { $found += @{ Root = $machineRoot; Target = 'Machine'; NeedsAdmin = $true; Label = 'tous les utilisateurs' } }
    }
    $legacy = @(Get-LegacyFiles)

    if ($found.Count -eq 0 -and $legacy.Count -eq 0) {
        Write-PstStatus info 'ps-tools n''est pas installé sur ce poste.'
        Write-Host ''
        return
    }

    foreach ($f in $found) { Write-PstStatus info "Installation détectée ($($f.Label)) : $($f.Root)" }
    if ($legacy.Count) { Write-PstStatus info "Ancienne version 1 détectée ($($legacy.Count) fichiers)" }
    Write-Host ''
    if (-not $Yes -and -not (Read-PstConfirm 'Désinstaller ps-tools ?' -DefaultYes)) {
        Write-PstStatus info 'Annulé.'
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

    # Bloc de chargement dans le profil PowerShell
    if (-not $InstallRoot) {
        foreach ($file in @(Disable-PstShell)) { Write-PstStatus ok "Profil nettoyé : $file" }
    }

    # Rappels planifiés et données personnelles (pas pour un emplacement personnalisé :
    # il ne doit pas toucher aux rappels de l'installation principale)
    if ($isWindowsHost -and -not $InstallRoot) {
        try {
            $tasks = @(Get-ScheduledTask -TaskName 'PsTools_Reminder_*' -ErrorAction Stop)
            foreach ($t in $tasks) { Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
            if ($tasks.Count) { Write-PstStatus ok "$($tasks.Count) rappel(s) planifié(s) annulé(s)" }
        }
        catch { $null = $_ }
    }
    $dataDir = $null
    if ($InstallRoot) { $dataDir = $null }
    elseif ($env:PSTOOLS_DATA) { $dataDir = $env:PSTOOLS_DATA }
    elseif ($isWindowsHost) { $dataDir = Join-Path (Get-ScopeRoot 'CurrentUser') 'data' }
    if ($dataDir -and (Test-Path -LiteralPath $dataDir)) {
        $purge = [bool]$PurgeData
        if (-not $purge -and -not $Yes) { $purge = Read-PstConfirm 'Supprimer aussi vos données (rappels enregistrés) ?' }
        if ($purge) {
            Remove-Item -LiteralPath $dataDir -Recurse -Force -ErrorAction SilentlyContinue
            $parent = Split-Path -Parent $dataDir
            if ((Test-Path -LiteralPath $parent) -and @(Get-ChildItem -LiteralPath $parent -Force).Count -eq 0) { Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue }
            Write-PstStatus ok 'Données personnelles supprimées'
        }
        else { Write-PstStatus info "Données conservées : $dataDir" }
    }

    Write-Host ''
    if ($blocked) {
        Write-PstStatus warn 'L''installation commune à tous les utilisateurs demande les droits administrateur.'
        if (-not $Yes -and (Test-PstInteractive) -and (Read-PstConfirm 'Ouvrir une fenêtre administrateur pour terminer ?' -DefaultYes)) {
            $null = Start-ElevatedSetup -ExtraArguments '-Uninstall -Yes'
        }
        else { Write-PstStatus info 'Relancez la désinstallation depuis un terminal administrateur pour la retirer.' }
    }
    else {
        Format-PstBox -Title 'ps-tools est désinstallé' -Lines @('Ouvrez un nouveau terminal pour actualiser le PATH.', (Paint 'Merci de l''avoir utilisé !' 'Dim')) -Width 62 -Color 'Ok' | Write-PstLine
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
        $choice = Read-PstChoice -Title 'Session administrateur détectée : pour qui installer ?' -Items @(
            'Pour moi uniquement (recommandé)', 'Pour tous les utilisateurs de ce PC'
        )
        Write-Host ''
        if ($choice -lt 0) { return $null }
        if ($choice -eq 1) { return 'AllUsers' }
        return 'CurrentUser'
    }

    if ($Scope -eq 'AllUsers' -and -not $isAdmin) {
        Write-PstStatus warn 'Installer pour tous les utilisateurs demande les droits administrateur.'
        if (-not $canAsk) {
            Write-PstStatus info 'Installation pour l''utilisateur courant à la place.'
            return 'CurrentUser'
        }
        $choice = Read-PstChoice -Title 'Comment continuer ?' -Items @(
            'Relancer en administrateur (invite UAC)', 'Installer pour moi uniquement, sans droits admin', 'Annuler'
        )
        Write-Host ''
        if ($choice -eq 1) { return 'CurrentUser' }
        if ($choice -eq 0) { $null = Start-ElevatedSetup -ExtraArguments '-Scope AllUsers' }
        return $null
    }
    return $Scope
}

function Invoke-Install {
    Show-PstBanner
    if (-not $isWindowsHost -and -not $InstallRoot) {
        Write-PstStatus err 'ps-tools s''installe sur Windows. (Hors Windows : -InstallRoot <dossier> pour un essai.)'
        throw 'Plateforme non prise en charge'
    }

    $resolved = Resolve-Scope
    if (-not $resolved) { Write-PstStatus info 'Installation interrompue.'; Write-Host ''; return }
    $target = 'User'
    if ($resolved -eq 'AllUsers') { $target = 'Machine' }
    if ($InstallRoot) { $root = $InstallRoot } else { $root = Get-ScopeRoot $resolved }
    $app = Join-Path $root 'app'
    $bin = Join-Path $root 'bin'

    # 1. Manifeste
    Write-PstStatus step "Source : $Source"
    try { $manifest = Get-SourceText 'manifest.json' | ConvertFrom-Json }
    catch {
        Write-PstStatus err "Impossible de lire le manifeste : $($_.Exception.Message)"
        Write-PstStatus info 'Vérifiez votre connexion (ou un proxy d''entreprise) puis réessayez.'
        throw
    }

    $available = @($manifest.tools)
    $selected = $available
    if ($Tools) {
        $wanted = @($Tools | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() })
        $unknown = @($wanted | Where-Object { @($available | ForEach-Object { $_.name }) -notcontains $_ })
        if ($unknown.Count) { throw "Outil(s) inconnu(s) : $($unknown -join ', '). Disponibles : $(@($available | ForEach-Object { $_.name }) -join ', ')" }
        $selected = @($available | Where-Object { $_.required -or $wanted -contains $_.name })
    }

    $previous = Get-InstallInfo $root
    $label = 'utilisateur courant, sans droits administrateur'
    if ($resolved -eq 'AllUsers') { $label = 'tous les utilisateurs' }
    if ($InstallRoot) { $label = 'emplacement personnalisé' }
    if ($previous -and $previous.Version) { Write-PstStatus step "Mise à jour $($previous.Version) $($g.Pointer) $($manifest.version) ($label)" }
    else { Write-PstStatus step "Installation de la version $($manifest.version) ($label)" }
    Write-PstStatus step "Dossier : $root"
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
        Write-PstStatus ok 'Bibliothèque commune'

        $nameWidth = 0
        foreach ($t in $selected) { $nameWidth = [Math]::Max($nameWidth, $t.name.Length) }
        foreach ($t in $selected) {
            Write-ScriptFile -File (Join-Path (Join-Path $app 'tools') "$($t.name).ps1") -Text (Get-SourceText "src/tools/$($t.name).ps1")
            # Lanceur .cmd : fonctionne depuis cmd et PowerShell, quelle que soit la stratégie d'exécution.
            $shim = "@echo off`r`npowershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\app\tools\$($t.name).ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n"
            [IO.File]::WriteAllText((Join-Path $bin "$($t.name).cmd"), $shim, [System.Text.Encoding]::ASCII)
            Write-PstStatus ok ((Paint $t.name.PadRight($nameWidth) 'Title' -Bold) + (Paint "  $($t.description)" 'Dim'))
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
            Selection = $(if ($Tools) { 'custom' } else { 'all' })
        }
        [IO.File]::WriteAllText((Join-Path $app 'install.json'), ($info | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
    }
    catch [UnauthorizedAccessException] {
        Write-PstStatus err "Écriture refusée dans $root."
        Write-PstStatus info 'Relancez sans -Scope AllUsers pour une installation sans droits administrateur.'
        throw
    }
    Write-Host ''

    # 3. PATH
    $pathReady = $false
    if ($NoPath -or -not $isWindowsHost) { Write-PstStatus info "PATH non modifié $($g.Dot) lanceurs dans $bin" }
    else {
        try {
            if (Update-PathEntry -Dir $bin -Target $target) { Write-PstStatus ok "Commandes ajoutées au PATH ($target)" }
            else { Write-PstStatus ok "PATH déjà configuré ($target)" }
            Set-HomeVariable -Value $root -Target $target
            if (@($env:PATH -split ';') -notcontains $bin) { $env:PATH = "$env:PATH;$bin" }
            $pathReady = $true
        }
        catch { Write-PstStatus warn "PATH non modifié : $($_.Exception.Message) $($g.Dot) ajoutez $bin manuellement." }
    }

    # 4. Ancienne version et conflits de priorité
    Remove-Legacy
    if ($isWindowsHost -and -not $InstallRoot -and $resolved -eq 'CurrentUser') {
        $machineRoot = Get-ScopeRoot 'AllUsers'
        if (Test-Path -LiteralPath (Join-Path $machineRoot 'app')) {
            Write-PstStatus warn "Une installation « tous les utilisateurs » existe aussi ($machineRoot) et reste prioritaire dans le PATH."
        }
    }

    # 5. Intégration au shell (modifie le profil de l'utilisateur : uniquement avec son accord)
    $shellActive = $false
    if (-not $InstallRoot -and -not $NoShell) {
        $shellActive = Test-PstShell
        $wanted = [bool]$Shell
        if (-not $shellActive -and -not $wanted -and -not $Yes -and (Test-PstInteractive)) {
            Write-Host ''
            Write-Host '  L''intégration au shell ajoute une invite claire (dossier, branche Git, durée), un historique'
            Write-Host '  plus malin, des raccourcis (Alt+A : IA) et des commandes façon Unix (ll, grep, sudo, jump...).'
            $wanted = Read-PstConfirm 'L''activer ? (une ligne ajoutée à votre profil PowerShell, réversible avec « pst shell off »)' -DefaultYes
        }
        if ($shellActive -or $wanted) {
            try {
                $null = Enable-PstShell -AppRoot $app
                $shellActive = $true
                Write-PstStatus ok 'Intégration au shell active (nouveaux terminaux)'
                $policy = Get-PstEffectivePolicy
                if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
                    Write-PstStatus warn "La stratégie d'exécution ($policy) empêche le chargement du profil : lancez « pst shell on » pour le correctif."
                }
            }
            catch { Write-PstStatus warn "Profil non modifié : $($_.Exception.Message)" }
        }
    }

    # 6. Bilan
    Write-Host ''
    $names = @($selected | Where-Object { $_.name -ne 'pst' } | ForEach-Object { $_.name })
    $half = [int][Math]::Ceiling($names.Count / 2)
    $summary = @(((Paint 'Commandes  ' 'Accent' -Bold) + (@($names | Select-Object -First $half) -join '  ')))
    if ($names.Count -gt $half) { $summary += ('           ' + (@($names | Select-Object -Skip $half) -join '  ')) }
    $summary += @(
        ((Paint 'Gestion    ' 'Accent' -Bold) + 'pst' + (Paint '  (menu, diagnostic, mise à jour, désinstallation)' 'Dim')),
        ((Paint 'Aide       ' 'Accent' -Bold) + '<commande> -Help' + (Paint '  ·  pst keys pour les raccourcis' 'Dim'))
    )
    if (-not $shellActive -and -not $InstallRoot) { $summary += ((Paint 'Shell      ' 'Accent' -Bold) + 'pst shell on' + (Paint '  (invite, raccourcis, alias)' 'Dim')) }
    if ($pathReady) { $summary += ''; $summary += Paint 'Disponible tout de suite ici, et dans tout nouveau terminal.' 'Dim' }
    Format-PstBox -Title "ps-tools $($manifest.version) est installé" -Lines $summary -Color 'Ok' | Write-PstLine
    Write-Host ''
    Write-Host ('  Pour commencer :  ' + (Paint 'pst' 'Ok' -Bold) + (Paint '   ou   ' 'Dim') + (Paint 'sysinfo' 'Ok' -Bold))
    Write-Host ''
}

if ($Uninstall) { Invoke-Uninstall } else { Invoke-Install }
