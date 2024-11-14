# Script d'installation spécifique pour ping-mon
$scriptContent = @'
function Format-Bar {
    param (
        [double]$Value,
        [double]$Max = 100,
        [int]$Length = 20
    )
    $percent = [Math]::Min(($Value / $Max) * 100, 100)
    $filled = [math]::Round($percent * $Length / 100)
    $empty = $Length - $filled
    $bar = "█" * $filled + "░" * $empty
    return $bar
}

function Show-PingMonitor {
    Clear-Host
    Write-Host "=== MONITEUR DE PING ===" -ForegroundColor Cyan
    Write-Host "Surveillez la latence de vos connexions" -ForegroundColor Yellow

    # Liste des hôtes par défaut
    $defaultHosts = @(
        [PSCustomObject]@{Name="Google DNS"; Address="8.8.8.8"},
        [PSCustomObject]@{Name="Cloudflare"; Address="1.1.1.1"},
        [PSCustomObject]@{Name="Google.com"; Address="google.com"},
        [PSCustomObject]@{Name="Gateway"; Address=(Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } | Select-Object -First 1).NextHop}
    )

    # Afficher les hôtes par défaut
    Write-Host "`nHôtes disponibles:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $defaultHosts.Count; $i++) {
        Write-Host "$($i + 1). $($defaultHosts[$i].Name) ($($defaultHosts[$i].Address))"
    }

    Write-Host "`nOptions:" -ForegroundColor Yellow
    Write-Host "A. Ajouter un hôte personnalisé"
    Write-Host "Q. Quitter"

    $choice = Read-Host "`nChoisissez un hôte à surveiller (1-$($defaultHosts.Count), A, Q)"

    $target = $null
    $customName = ""

    if ($choice -eq "Q") {
        return
    }
    elseif ($choice -eq "A") {
        $customName = Read-Host "Nom de l'hôte"
        $target = Read-Host "Adresse IP ou nom de domaine"
    }
    elseif ($choice -match '^\d+$' -and [int]$choice -le $defaultHosts.Count) {
        $selected = $defaultHosts[[int]$choice - 1]
        $target = $selected.Address
        $customName = $selected.Name
    }
    else {
        Write-Host "Choix invalide!" -ForegroundColor Red
        Start-Sleep -Seconds 2
        Show-PingMonitor
        return
    }

    # Initialisation des statistiques
    $stats = @{
        Min = [double]::MaxValue
        Max = 0
        Total = 0
        Count = 0
        Lost = 0
        History = @()
    }

    Clear-Host
    while ($true) {
        $timestamp = Get-Date
        try {
            $result = Test-Connection -ComputerName $target -Count 1 -ErrorAction Stop
            $latency = $result.ResponseTime
            
            # Mise à jour des statistiques
            $stats.Total += $latency
            $stats.Count++
            $stats.Min = [Math]::Min($stats.Min, $latency)
            $stats.Max = [Math]::Max($stats.Max, $latency)
            $stats.History += $latency
            if ($stats.History.Count -gt 10) {
                $stats.History = $stats.History[-10..-1]
            }

            # Affichage des résultats
            [Console]::SetCursorPosition(0, 0)
            Write-Host "=== MONITEUR DE PING ===" -ForegroundColor Cyan
            Write-Host "Surveillance de $customName ($target)" -ForegroundColor Yellow
            Write-Host "CTRL+C pour quitter`n" -ForegroundColor DarkGray
            
            # Affichage du dernier ping
            $color = if ($latency -lt 50) { "Green" } elseif ($latency -lt 100) { "Yellow" } else { "Red" }
            Write-Host "Dernier ping: " -NoNewline
            Write-Host "$latency ms" -ForegroundColor $color

            # Affichage des statistiques
            Write-Host "`nStatistiques:"
            Write-Host "Minimum: $($stats.Min) ms"
            Write-Host "Maximum: $($stats.Max) ms"
            Write-Host "Moyenne: $([Math]::Round($stats.Total / $stats.Count, 2)) ms"
            Write-Host "Paquets perdus: $($stats.Lost)"
            
            # Affichage de l'historique
            Write-Host "`nHistorique (10 derniers pings):"
            foreach ($ping in $stats.History) {
                $barColor = if ($ping -lt 50) { "Green" } elseif ($ping -lt 100) { "Yellow" } else { "Red" }
                Write-Host ("[{0,4:N0}ms] " -f $ping) -NoNewline
                Write-Host (Format-Bar -Value $ping -Max 200) -ForegroundColor $barColor
            }

            Start-Sleep -Seconds 1
        }
        catch {
            $stats.Lost++
            Write-Host "Échec du ping vers $target" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}

# Point d'entrée
try {
    Show-PingMonitor
}
catch {
    Write-Host "`nMoniteur arrêté." -ForegroundColor Yellow
}
'@

function Install-PingMonPackage {
    try {
        
        $installPath = "C:\Program Files\WindowsPowerShell\Scripts"
        if (-not (Test-Path $installPath)) {
            New-Item -ItemType Directory -Path $installPath -Force | Out-Null
        }

        
        $scriptFile = Join-Path $installPath "ping-mon.ps1"
        Set-Content -Path $scriptFile -Value $scriptContent

        # Créer le fichier .cmd
        $cmdContent = @"
@echo off
powershell -ExecutionPolicy Bypass -File "$scriptFile" %*
"@
        $cmdFile = Join-Path $installPath "ping-mon.cmd"
        Set-Content -Path $cmdFile -Value $cmdContent

        
        $currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
        if ($currentPath -notlike "*$installPath*") {
            [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$installPath", "Machine")
        }

        Write-Host "Le paquet ping-mon a été installé avec succès!" -ForegroundColor Green
        Write-Host "Tapez 'ping-mon' dans PowerShell pour l'utiliser." -ForegroundColor Yellow
        return $true
    }
    catch {
        Write-Error "Erreur lors de l'installation de ping-mon: $_"
        return $false
    }
}

# Exécuter l'installation
Install-PingMonPackage