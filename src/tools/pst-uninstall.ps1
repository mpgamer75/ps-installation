<#
.SYNOPSIS
    pst-uninstall — désinstalle complètement ps-tools.
.DESCRIPTION
    Retire tout ce que l'installation a posé : commandes, entrée du PATH,
    intégration au shell (bloc du profil PowerShell) et rappels planifiés.
    Une installation pour l'utilisateur courant se retire sans droits
    administrateur ; une installation « tous les utilisateurs » propose l'élévation.
    Les données personnelles (rappels, favoris, clé de l'assistant) sont
    conservées, sauf avec -Purge.
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$Purge,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

$appRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path (Join-Path $appRoot 'lib') 'PsTools.ps1')
Import-PstStrings 'pst-uninstall'

if ($Help -or (Test-PstHelpArg $Rest)) {
    Show-PstHelp -Name 'pst-uninstall' -Synopsis (L 'Désinstalle ps-tools de cette machine.') `
        -Usage @('pst-uninstall [-Yes] [-Purge]') `
        -Options @(
            @('-Yes', (L 'Ne pose aucune question (les données sont conservées, sauf avec -Purge)')),
            @('-Purge', (L 'Supprime aussi vos données : rappels, favoris, clé et réglages de « ask »'))
        ) `
        -Examples @('pst-uninstall', 'pst-uninstall -Yes', 'pst-uninstall -Yes -Purge') `
        -Notes @(
            (L 'Retiré : commandes, entrée du PATH, intégration au shell, rappels planifiés.'),
            (L 'Équivalent : pst uninstall. Sans ps-tools sous la main :'),
            '  irm https://raw.githubusercontent.com/mpgamer75/ps-installation/main/uninstall.ps1 | iex'
        )
    exit 0
}

$setup = Join-Path $appRoot 'setup.ps1'
$infoFile = Join-Path $appRoot 'install.json'
if (-not (Test-Path -LiteralPath $infoFile) -or -not (Test-Path -LiteralPath $setup)) {
    Write-PstStatus info (L 'Cette copie s''exécute depuis le dépôt : rien n''est installé ici.')
    Write-PstStatus info (L 'Pour retirer une installation existante : .\uninstall.ps1')
    exit 0
}

$info = $null
try { $info = Get-Content -LiteralPath $infoFile -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Write-PstStatus err (L 'Fichier d''installation illisible : {0}' $infoFile); exit 1 }

# -Deferred : les fichiers en cours d'exécution sont supprimés par un processus
# détaché, juste après la fin de cette commande.
$arguments = @{ Uninstall = $true; Deferred = $true; Source = [string]$info.Source }
if ($Yes) { $arguments.Yes = $true }
if ($Purge) { $arguments.PurgeData = $true }

# Installation dans un dossier personnalisé (-InstallRoot) : on le désigne explicitement.
$standardRoots = @()
if ($env:LOCALAPPDATA) { $standardRoots += Join-Path $env:LOCALAPPDATA 'ps-tools' }
if ($env:ProgramFiles) { $standardRoots += Join-Path $env:ProgramFiles 'ps-tools' }
if ($standardRoots -notcontains [string]$info.Root) { $arguments.InstallRoot = [string]$info.Root }

& $setup @arguments
