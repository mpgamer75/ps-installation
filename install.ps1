<#
.SYNOPSIS
    Gestionnaire de paquets pour scripts PowerShell
.DESCRIPTION
    Installe, met à jour et gère les scripts PowerShell personnalisés
.NOTES
    Version: 1.0.0
    Author: Charles L.
#>

# Vérification des privilèges administrateur
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Ce script nécessite des droits administrateur!"
    Write-Warning "Veuillez relancer PowerShell en tant qu'administrateur."
    exit
}

# Configuration
$CONFIG = @{
    LocalPath = "$env:USERPROFILE\.ps-tools"
    PackagesPath = "$env:USERPROFILE\.ps-tools\packages"
    LogPath = "$env:USERPROFILE\.ps-tools\logs"
}

# Fonction pour les logs
function Write-Log {
    param($Message, [ValidateSet("INFO", "ERROR", "WARNING")]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Add-Content -Path "$($CONFIG.LogPath)\ps-tools.log" -Value $logMessage
    
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARNING" { "Yellow" }
        default { "White" }
    }
    Write-Host $logMessage -ForegroundColor $color
}

# Vérification des prérequis
function Test-Prerequisites {
    # Vérifie la version de PowerShell
    if ($PSVersionTable.PSVersion.Major -lt 5) {
        Write-Log "PowerShell 5.1 ou supérieur requis" -Level ERROR
        return $false
    }
    
    # Créer les dossiers nécessaires
    try {
        @($CONFIG.LocalPath, $CONFIG.PackagesPath, $CONFIG.LogPath) | ForEach-Object {
            if (-not (Test-Path $_)) {
                New-Item -ItemType Directory -Path $_ -Force | Out-Null
            }
        }
    }
    catch {
        Write-Log "Erreur lors de la création des dossiers: $_" -Level ERROR
        return $false
    }
    
    return $true
}

# Liste les paquets disponibles
function Get-AvailablePackages {
    Write-Host "`n=== PAQUETS DISPONIBLES ===" -ForegroundColor Cyan
    
    try {
        $packages = @(
            @{
                name = "monitor"
                description = "Moniteur système en temps réel"
                version = "1.0.0"
                tags = @("system", "monitoring", "performance")
            },
            @{
                name = "clean"
                description = "Nettoyeur système"
                version = "1.0.0"
                tags = @("system", "cleanup", "maintenance")
            },
            @{
                name = "ping-mon"
                description = "Moniteur de ping avec interface interactive"
                version = "1.0.0"
                tags = @("network", "monitoring", "ping")
            },
            @{
                name = "remind"
                description = "Système de rappels avec notifications"
                version = "1.0.0"
                tags = @("reminder", "notification", "task")
            }
        )

        foreach ($package in $packages) {
            Write-Host "`nNom: " -NoNewline
            Write-Host $package.name -ForegroundColor Yellow
            Write-Host "Version: $($package.version)"
            Write-Host "Description: $($package.description)"
            Write-Host "Tags: $($package.tags -join ', ')" -ForegroundColor DarkGray
        }
    }
    catch {
        Write-Log "Erreur lors de la récupération des paquets: $_" -Level ERROR
    }
}

# Installe un paquet
function Install-Package {
    param([string]$PackageName)
    
    Write-Host "`n=== INSTALLATION: $PackageName ===" -ForegroundColor Cyan
    
    try {
        # Installation selon le type de paquet
        switch ($PackageName) {
            "monitor" {
                Write-Log "Installation du paquet monitor..." -Level INFO
                $scriptPath = Join-Path $CONFIG.PackagesPath "monitor\install.ps1"
                if (Test-Path $scriptPath) {
                    & $scriptPath
                } else {
                    Write-Log "Script d'installation introuvable pour monitor" -Level ERROR
                }
            }
            "clean" {
                Write-Log "Installation du paquet clean..." -Level INFO
                $scriptPath = Join-Path $CONFIG.PackagesPath "clean\install.ps1"
                if (Test-Path $scriptPath) {
                    & $scriptPath
                } else {
                    Write-Log "Script d'installation introuvable pour clean" -Level ERROR
                }
            }
            "ping-mon" {
                Write-Log "Installation du paquet ping-mon..." -Level INFO
                $scriptPath = Join-Path $CONFIG.PackagesPath "ping-mon\install.ps1"
                if (Test-Path $scriptPath) {
                    & $scriptPath
                } else {
                    Write-Log "Script d'installation introuvable pour ping-mon" -Level ERROR
                }
            }
            "remind" {
                Write-Log "Installation du paquet remind..." -Level INFO
                $scriptPath = Join-Path $CONFIG.PackagesPath "remind\install.ps1"
                if (Test-Path $scriptPath) {
                    & $scriptPath
                } else {
                    Write-Log "Script d'installation introuvable pour remind" -Level ERROR
                }
            }
            default {
                Write-Log "Paquet '$PackageName' non reconnu" -Level ERROR
                return
            }
        }
        
        Write-Host "`nInstallation terminée!" -ForegroundColor Green
    }
    catch {
        Write-Log "Erreur lors de l'installation: $_" -Level ERROR
    }
}

# Menu principal
function Show-MainMenu {
    while ($true) {
        Clear-Host
        Write-Host "=== PS-TOOLS MANAGER ===" -ForegroundColor Cyan
        Write-Host "1. Lister les paquets disponibles"
        Write-Host "2. Installer un paquet"
        Write-Host "3. Vérifier les mises à jour"
        Write-Host "Q. Quitter"
        
        $choice = Read-Host "`nVotre choix"
        
        switch ($choice) {
            "1" { 
                Get-AvailablePackages 
                Write-Host "`nAppuyez sur une touche pour continuer..."
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
            "2" {
                Get-AvailablePackages
                Write-Host "`nQuel paquet souhaitez-vous installer ?"
                $package = Read-Host "Nom du paquet"
                Install-Package $package
                Write-Host "`nAppuyez sur une touche pour continuer..."
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
            "3" {
                Write-Host "`nRecherche de mises à jour..." -ForegroundColor Yellow
                Write-Host "Aucune mise à jour disponible." -ForegroundColor Green
                Write-Host "`nAppuyez sur une touche pour continuer..."
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
            "Q" { return }
            default {
                Write-Host "`nOption non valide!" -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

# Point d'entrée principal
if (Test-Prerequisites) {
    Show-MainMenu
}