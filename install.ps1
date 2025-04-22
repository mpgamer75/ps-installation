# Vérification des privilèges administrateur
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Ce script nécessite des droits administrateur!"
    Write-Warning "Veuillez relancer PowerShell en tant qu'administrateur."
    exit
}

# Configuration
$CONFIG = @{
    RepoUrl = "https://raw.githubusercontent.com/mpgamer75/ps-installation/main"
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

# Télécharge les fichiers des paquets
function Get-PackageFiles {
    Write-Host "Téléchargement des paquets..." -ForegroundColor Cyan
    $baseUrl = $CONFIG.RepoUrl + "/packages"
    
    @("monitor", "clean", "ping-mon", "remind") | ForEach-Object {
        $packageName = $_
        $packagePath = Join-Path $CONFIG.PackagesPath $packageName
        
        Write-Host "Téléchargement de $packageName..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $packagePath -Force | Out-Null
        
        try {
            $installUrl = "$baseUrl/$packageName/install.ps1"
            $manifestUrl = "$baseUrl/$packageName/manifest.json"
            
            Invoke-WebRequest -Uri $installUrl -OutFile (Join-Path $packagePath "install.ps1")
            Invoke-WebRequest -Uri $manifestUrl -OutFile (Join-Path $packagePath "manifest.json")
            
            Write-Host "✓ $packageName téléchargé" -ForegroundColor Green
        }
        catch {
            Write-Host "✗ Erreur lors du téléchargement de $packageName" -ForegroundColor Red
            Write-Log $_.Exception.Message -Level ERROR
        }
    }
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
        $scriptPath = Join-Path $CONFIG.PackagesPath "$PackageName\install.ps1"
        if (Test-Path $scriptPath) {
            & $scriptPath
            Write-Host "`nInstallation terminée!" -ForegroundColor Green
        } else {
            Write-Log "Script introuvable: $scriptPath" -Level ERROR
            Write-Host "`nTéléchargement du paquet nécessaire. Veuillez sélectionner l'option 1 du menu principal." -ForegroundColor Yellow
        }
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
        Write-Host "1. Télécharger/Mettre à jour les paquets"
        Write-Host "2. Voir les paquets disponibles"
        Write-Host "3. Installer un paquet"
        Write-Host "Q. Quitter"
        
        $choice = Read-Host "`nVotre choix"
        
        switch ($choice) {
            "1" { 
                Get-PackageFiles 
                Write-Host "`nAppuyez sur une touche pour continuer..."
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
            "2" {
                Get-AvailablePackages
                Write-Host "`nAppuyez sur une touche pour continuer..."
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            }
            "3" {
                Get-AvailablePackages
                Write-Host "`nQuel paquet souhaitez-vous installer ?"
                $package = Read-Host "Nom du paquet"
                
                # Vérification si le paquet existe dans la liste des paquets disponibles
                if (@("monitor", "clean", "ping-mon", "remind") -contains $package) {
                    Install-Package $package
                }
                else {
                    Write-Host "`nNom du paquet non valide!" -ForegroundColor Red
                }
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
