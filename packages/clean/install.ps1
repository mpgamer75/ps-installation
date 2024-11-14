$scriptContent = @'
function Format-FileSize {
    param([long]$Size)
    if ($Size -gt 1TB) { return "{0:N2} TB" -f ($Size / 1TB) }
    if ($Size -gt 1GB) { return "{0:N2} GB" -f ($Size / 1GB) }
    if ($Size -gt 1MB) { return "{0:N2} MB" -f ($Size / 1MB) }
    if ($Size -gt 1KB) { return "{0:N2} KB" -f ($Size / 1KB) }
    return "$Size B"
}

function Format-Bar {
    param (
        [double]$Percent,
        [int]$Length = 20
    )
    $filled = [math]::Round($Percent * $Length / 100)
    $empty = $Length - $filled
    $bar = "█" * $filled + "░" * $empty
    return $bar
}

function Get-FolderSize {
    param([string]$Path)
    $size = Get-ChildItem $Path -Recurse -ErrorAction SilentlyContinue | 
            Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue
    return $size.Sum
}

function Start-Cleaning {
    # Interface utilisateur
    Clear-Host
    Write-Host "=== NETTOYEUR SYSTÈME ===" -ForegroundColor Cyan
    Write-Host "Cet outil va vous aider à nettoyer votre système" -ForegroundColor Yellow
    Write-Host

    # Sélection de l'emplacement
    $locations = @{
        "1" = @{Name="Bureau"; Path=[Environment]::GetFolderPath("Desktop")}
        "2" = @{Name="Documents"; Path=[Environment]::GetFolderPath("MyDocuments")}
        "3" = @{Name="Téléchargements"; Path=[Environment]::GetFolderPath("UserProfile") + "\Downloads"}
        "4" = @{Name="Images"; Path=[Environment]::GetFolderPath("MyPictures")}
        "5" = @{Name="Vidéos"; Path=[Environment]::GetFolderPath("MyVideos")}
        "6" = @{Name="Musique"; Path=[Environment]::GetFolderPath("MyMusic")}
        "7" = @{Name="AppData"; Path=$env:APPDATA}
        "8" = @{Name="Temp Windows"; Path=$env:TEMP}
    }

    Write-Host "Sélectionnez l'emplacement à nettoyer :" -ForegroundColor Cyan
    foreach ($key in $locations.Keys | Sort-Object) {
        $location = $locations[$key]
        $size = Format-FileSize (Get-FolderSize $location.Path)
        Write-Host "$key. $($location.Name) ($size)" -ForegroundColor Yellow
    }
    Write-Host

    $choice = Read-Host "Votre choix (Q pour quitter)"
    if ($choice -eq "Q") { return }
    if (-not $locations.ContainsKey($choice)) {
        Write-Host "Choix invalide!" -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    $selectedLocation = $locations[$choice]
    Write-Host "`nVous avez sélectionné : $($selectedLocation.Name)" -ForegroundColor Green

    # Options de nettoyage
    $cleanOptions = @(
        "Fichiers temporaires (*.tmp, *.temp)",
        "Fichiers de log (*.log)",
        "Fichiers de sauvegarde (*.bak)",
        "Fichiers cache (*.cache)",
        "Dossiers vides",
        "Fichiers plus vieux que..."
    )

    Write-Host "`nQue souhaitez-vous nettoyer ?" -ForegroundColor Cyan
    for ($i = 0; $i -lt $cleanOptions.Length; $i++) {
        Write-Host "$($i + 1). $($cleanOptions[$i])" -ForegroundColor Yellow
    }

    $cleanChoice = Read-Host "`nVotre choix (plusieurs choix possibles, séparés par des virgules)"
    $choices = $cleanChoice.Split(',') | ForEach-Object { $_.Trim() }

    # Variables pour les statistiques
    $totalFiles = 0
    $totalSize = 0

    # Confirmation avec preview
    Write-Host "`nAnalyse en cours..." -ForegroundColor Cyan
    foreach ($choice in $choices) {
        switch ($choice) {
            "1" { # Fichiers temporaires
                $files = Get-ChildItem -Path $selectedLocation.Path -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Extension -match '\.(tmp|temp)$' }
                $totalFiles += $files.Count
                $totalSize += ($files | Measure-Object -Property Length -Sum).Sum
            }
            "2" { # Fichiers log
                $files = Get-ChildItem -Path $selectedLocation.Path -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Extension -eq '.log' }
                $totalFiles += $files.Count
                $totalSize += ($files | Measure-Object -Property Length -Sum).Sum
            }
            "3" { # Fichiers backup
                $files = Get-ChildItem -Path $selectedLocation.Path -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Extension -eq '.bak' }
                $totalFiles += $files.Count
                $totalSize += ($files | Measure-Object -Property Length -Sum).Sum
            }
            "4" { # Fichiers cache
                $files = Get-ChildItem -Path $selectedLocation.Path -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Extension -eq '.cache' }
                $totalFiles += $files.Count
                $totalSize += ($files | Measure-Object -Property Length -Sum).Sum
            }
            "5" { # Dossiers vides
                $emptyFolders = Get-ChildItem -Path $selectedLocation.Path -Recurse -Directory -ErrorAction SilentlyContinue |
                               Where-Object { (Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0 }
                $totalFiles += $emptyFolders.Count
            }
            "6" { # Fichiers plus vieux que...
                $days = Read-Host "Supprimer les fichiers plus vieux que combien de jours"
                $date = (Get-Date).AddDays(-([int]$days))
                $files = Get-ChildItem -Path $selectedLocation.Path -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -lt $date }
                $totalFiles += $files.Count
                $totalSize += ($files | Measure-Object -Property Length -Sum).Sum
            }
        }
    }

    Write-Host "`nRésumé du nettoyage prévu :" -ForegroundColor Cyan
    Write-Host "Nombre de fichiers à supprimer : $totalFiles" -ForegroundColor Yellow
    Write-Host "Espace total à libérer : $(Format-FileSize $totalSize)" -ForegroundColor Yellow

    $confirm = Read-Host "`nVoulez-vous procéder au nettoyage ? (O/N)"
    if ($confirm -ne "O") {
        Write-Host "`nOpération annulée" -ForegroundColor Red
        return
    }

    # Processus de nettoyage
    Write-Host "`nNettoyage en cours..." -ForegroundColor Cyan
    $progress = 0
    foreach ($choice in $choices) {
        switch ($choice) {
            "1" { # Fichiers temporaires
                Get-ChildItem -Path $selectedLocation.Path -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '\.(tmp|temp)$' } |
                Remove-Item -Force -ErrorAction SilentlyContinue
                $progress += 20
                Write-Progress -Activity "Nettoyage en cours" -Status "Suppression des fichiers temporaires" -PercentComplete $progress
            }
            "2" { # Fichiers log
                Get-ChildItem -Path $selectedLocation.Path -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.log' } |
                Remove-Item -Force -ErrorAction SilentlyContinue
                $progress += 20
                Write-Progress -Activity "Nettoyage en cours" -Status "Suppression des fichiers log" -PercentComplete $progress
            }
            "3" { # Fichiers backup
                Get-ChildItem -Path $selectedLocation.Path -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.bak' } |
                Remove-Item -Force -ErrorAction SilentlyContinue
                $progress += 20
                Write-Progress -Activity "Nettoyage en cours" -Status "Suppression des fichiers backup" -PercentComplete $progress
            }
            "4" { # Fichiers cache
                Get-ChildItem -Path $selectedLocation.Path -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.cache' } |
                Remove-Item -Force -ErrorAction SilentlyContinue
                $progress += 20
                Write-Progress -Activity "Nettoyage en cours" -Status "Suppression des fichiers cache" -PercentComplete $progress
            }
            "5" { # Dossiers vides
                Get-ChildItem -Path $selectedLocation.Path -Recurse -Directory -ErrorAction SilentlyContinue |
                Where-Object { (Get-ChildItem -Path $_.FullName -Recurse -File).Count -eq 0 } |
                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
                $progress += 20
                Write-Progress -Activity "Nettoyage en cours" -Status "Suppression des dossiers vides" -PercentComplete $progress
            }
            "6" { # Fichiers plus vieux que...
                $date = (Get-Date).AddDays(-([int]$days))
                Get-ChildItem -Path $selectedLocation.Path -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $date } |
                Remove-Item -Force -ErrorAction SilentlyContinue
                $progress += 20
                Write-Progress -Activity "Nettoyage en cours" -Status "Suppression des vieux fichiers" -PercentComplete $progress
            }
        }
    }

    Write-Progress -Activity "Nettoyage en cours" -Status "Terminé" -Completed
    Write-Host "`nNettoyage terminé !" -ForegroundColor Green
    
    # Afficher l'espace gagné
    $newSize = Get-FolderSize $selectedLocation.Path
    $spaceSaved = Format-FileSize ($totalSize - $newSize)
    Write-Host "Espace libéré : $spaceSaved" -ForegroundColor Green

    Write-Host "`nAppuyez sur une touche pour continuer..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# Boucle principale
do {
    Start-Cleaning
    Write-Host "`nVoulez-vous effectuer un autre nettoyage ? (O/N)" -ForegroundColor Cyan
    $continue = Read-Host
} while ($continue -eq "O")
'@

function Install-CleanPackage {
    try {
        # Créer le dossier de destination s'il n'existe pas
        $installPath = "C:\Program Files\WindowsPowerShell\Scripts"
        if (-not (Test-Path $installPath)) {
            New-Item -ItemType Directory -Path $installPath -Force | Out-Null
        }

        # Installe le script
        $scriptFile = Join-Path $installPath "clean.ps1"
        Set-Content -Path $scriptFile -Value $scriptContent

        # Créer le fichier .cmd
        $cmdContent = @"
@echo off
powershell -ExecutionPolicy Bypass -File "$scriptFile" %*
"@
        $cmdFile = Join-Path $installPath "clean.cmd"
        Set-Content -Path $cmdFile -Value $cmdContent

        # MAJ du PATH
        $currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
        if ($currentPath -notlike "*$installPath*") {
            [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$installPath", "Machine")
        }

        Write-Host "Le paquet clean a été installé avec succès!" -ForegroundColor Green
        Write-Host "Tapez 'clean' dans PowerShell pour l'utiliser." -ForegroundColor Yellow
        return $true
    }
    catch {
        Write-Error "Erreur lors de l'installation de clean: $_"
        return $false
    }
}

# Exécute l'installation
Install-CleanPackage