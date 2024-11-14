if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Ce script nécessite des droits administrateur!"
    exit
}

function Uninstall-Package {
    param([string]$PackageName)
    
    Write-Host "`n=== DÉSINSTALLATION: $PackageName ===" -ForegroundColor Cyan
    try {
        # Supprime les fichiers du paquet
        $scriptPath = "C:\Program Files\WindowsPowerShell\Scripts\$PackageName.ps1"
        $cmdPath = "C:\Program Files\WindowsPowerShell\Scripts\$PackageName.cmd"
        
        if (Test-Path $scriptPath) { Remove-Item $scriptPath -Force }
        if (Test-Path $cmdPath) { Remove-Item $cmdPath -Force }

        # Pour remind, supprime aussi les données
        if ($PackageName -eq "remind") {
            $reminderDataPath = "$env:USERPROFILE\AppData\Local\RemindSystem"
            if (Test-Path $reminderDataPath) {
                Remove-Item $reminderDataPath -Recurse -Force
            }
        }

        Write-Host "Paquet $PackageName désinstallé avec succès!" -ForegroundColor Green
    }
    catch {
        Write-Host "Erreur lors de la désinstallation: $_" -ForegroundColor Red
    }
}

function Show-UninstallMenu {
    while ($true) {
        Clear-Host
        Write-Host "=== DÉSINSTALLATION DES PAQUETS ===" -ForegroundColor Cyan
        Write-Host "1. monitor"
        Write-Host "2. clean"
        Write-Host "3. ping-mon"
        Write-Host "4. remind"
        Write-Host "5. Tout désinstaller"
        Write-Host "Q. Quitter"
        
        $choice = Read-Host "`nVotre choix"
        
        switch ($choice) {
            "1" { Uninstall-Package "monitor" }
            "2" { Uninstall-Package "clean" }
            "3" { Uninstall-Package "ping-mon" }
            "4" { Uninstall-Package "remind" }
            "5" { 
                @("monitor", "clean", "ping-mon", "remind") | ForEach-Object {
                    Uninstall-Package $_
                }
            }
            "Q" { return }
        }
        
        if ($choice -ne "Q") {
            Write-Host "`nAppuyez sur une touche pour continuer..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
    }
}

Show-UninstallMenu