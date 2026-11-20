<#
.SYNOPSIS
    pst — gestionnaire ps-tools : liste des outils, diagnostic, mise à jour, désinstallation.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command,
    [switch]$Yes,
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
    Write-Host ('  ' + (Paint 'pst doctor      ' 'Ok') + (Paint '  vérifie l''installation' 'Dim'))
    Write-Host ('  ' + (Paint 'pst update      ' 'Ok') + (Paint '  installe la dernière version' 'Dim'))
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
    $setup = Join-Path $appRoot 'setup.ps1'
    $info = Get-InstallInfo
    if ($null -eq $info -or -not (Test-Path -LiteralPath $setup)) {
        Write-PstStatus info 'pst s''exécute depuis le dépôt : rien à désinstaller ici (voir uninstall.ps1).'
        return
    }
    $arguments = @{ Uninstall = $true; Deferred = $true; Source = [string]$info.Source }
    if ($Yes) { $arguments.Yes = $true }
    & $setup @arguments
}

if ($Help -or (Test-PstHelpArg (@($Command) + @($Rest)))) {
    Show-PstHelp -Name 'pst' -Synopsis 'Gestionnaire de la boîte à outils ps-tools.' `
        -Usage @('pst [commande]') `
        -Options @(
            @('list', 'Liste les outils installés'),
            @('doctor', 'Vérifie l''installation et l''environnement'),
            @('update', 'Installe la dernière version (mêmes outils, même périmètre)'),
            @('uninstall [-Yes]', 'Désinstalle ps-tools'),
            @('version', 'Affiche la version')
        ) `
        -Examples @('pst', 'pst doctor', 'pst update')
    exit 0
}

switch -Regex ($Command) {
    '^$' { Show-Home; break }
    '^(list|ls)$' { Show-PstHeader -Tool 'pst' -Subtitle 'outils'; Show-ToolList; break }
    '^(doctor|check)$' { Invoke-Doctor; break }
    '^(update|upgrade)$' { Invoke-Update; break }
    '^(uninstall|remove)$' { Invoke-Remove; break }
    '^(version|-v|--version)$' { Write-Host "ps-tools $($script:Pst.Version)"; break }
    default {
        Write-PstStatus err "Commande inconnue : « $Command » $($g.Dot) voir « pst -Help »"
        exit 1
    }
}
